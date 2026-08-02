package imgdrv

import (
	"fmt"
	"sort"
	"strconv"
	"strings"
)

// A JSON value, and the canonical serialization __structuredAttrs uses.
//
// FINDING, and it is the correction rather than the original claim. This is the
// first RECURSIVE type in the signature: everything else is a product of
// primitives and lists of them, which is what docs/theory.md section 1
// restricts the signature to. A JSON value is an inductive datatype, a fixed
// point of a polynomial functor, and it is a SEVEN-CASE SUM.
//
// Go has no sum types, and this file originally encoded one as a struct with a
// discriminant and one field per case. That was the WORSE of Go's two options,
// and it took writing a 21-case sum (impl/go/nix/ast.go) to notice: at that
// width the discriminant struct is untenable, so the AST used a SEALED
// INTERFACE, and the sealed interface turns out to be strictly better here too.
//
// What changed, concretely. `JSONValue{}` used to be a representable value of
// an INVALID shape: Kind said one thing, the payload fields said another, and
// only a runtime convention kept them in step. With a sealed interface that
// combination cannot be written down. See
// docs/decisions/2026-08-02-go-json-sealed-interface.md and
// docs/abstractions.md entry 12.
//
// What did NOT change is the part worth stating: Go still cannot check that a
// type switch over these seven is exhaustive. That is the irreducible gap from
// a variant, and it is why every switch below ends in a panicking default.

// JSONValue is one JSON value.
//
// Sealed: only this package can implement it, because isJSON is unexported.
type JSONValue interface {
	isJSON()
}

// JSONNull is the JSON null.
type JSONNull struct{}

// JSONBool is a boolean.
type JSONBool struct{ Value bool }

// JSONInt is a 64-bit integer, which is what a Nix integer is.
type JSONInt struct{ Value int64 }

// JSONFloat is a double.
type JSONFloat struct{ Value float64 }

// JSONString is a string.
type JSONString struct{ Value string }

// JSONArray is a list. Order is significant.
type JSONArray struct{ Items []JSONValue }

// JSONObject is a map. Keys are sorted at serialization time.
type JSONObject struct{ Fields map[string]JSONValue }

func (JSONNull) isJSON()   {}
func (JSONBool) isJSON()   {}
func (JSONInt) isJSON()    {}
func (JSONFloat) isJSON()  {}
func (JSONString) isJSON() {}
func (JSONArray) isJSON()  {}
func (JSONObject) isJSON() {}

// Null is the JSON null.
func Null() JSONValue { return JSONNull{} }

// Bool wraps a boolean.
func Bool(b bool) JSONValue { return JSONBool{Value: b} }

// Int wraps a 64-bit integer, which is what Nix integers are.
func Int(i int64) JSONValue { return JSONInt{Value: i} }

// Float wraps a double.
func Float(f float64) JSONValue { return JSONFloat{Value: f} }

// Str wraps a string.
func Str(s string) JSONValue { return JSONString{Value: s} }

// Array wraps a list. Order is significant.
func Array(items ...JSONValue) JSONValue { return JSONArray{Items: items} }

// Object wraps a map. Keys are sorted at serialization time.
func Object(fields map[string]JSONValue) JSONValue {
	return JSONObject{Fields: fields}
}

// Strings is the common case: an array of strings.
func Strings(items ...string) JSONValue {
	out := make([]JSONValue, 0, len(items))
	for _, s := range items {
		out = append(out, Str(s))
	}
	return Array(out...)
}

// AsString returns the string a value carries, and whether it was one.
//
// Needed because the flat env encoding can only carry strings, so a Build
// without StructuredAttrs has to refuse anything else. Returning the value
// alongside the answer is what the discriminant encoding could not do without
// a second field access that might not be the meaningful one.
func AsString(v JSONValue) (string, bool) {
	s, ok := v.(JSONString)
	return s.Value, ok
}

// JSON is the canonical serialization: sorted keys, compact separators, and
// non-ASCII emitted raw rather than \uXXXX escaped.
//
// All three hold on 456 of 456 structured derivations in a real closure.
func JSON(v JSONValue) string {
	var b strings.Builder
	writeJSON(&b, v)
	return b.String()
}

// writeJSON is the type switch a variant would make exhaustive.
//
// Go does not check that every case is present, so the default panics rather
// than silently writing nothing. A missing case would produce a syntactically
// valid but WRONG JSON document, and therefore a wrong store path, which is the
// failure mode docs/spec/store-paths.md calls right shape, wrong identity.
func writeJSON(b *strings.Builder, v JSONValue) {
	switch v := v.(type) {
	case JSONNull:
		b.WriteString("null")
	case JSONBool:
		if v.Value {
			b.WriteString("true")
		} else {
			b.WriteString("false")
		}
	case JSONInt:
		b.WriteString(strconv.FormatInt(v.Value, 10))
	case JSONFloat:
		if v.Value == float64(int64(v.Value)) {
			fmt.Fprintf(b, "%.1f", v.Value)
		} else {
			b.WriteString(strconv.FormatFloat(v.Value, 'g', -1, 64))
		}
	case JSONString:
		escapeJSON(v.Value, b)
	case JSONArray:
		b.WriteByte('[')
		for i, item := range v.Items {
			if i > 0 {
				b.WriteByte(',')
			}
			writeJSON(b, item)
		}
		b.WriteByte(']')
	case JSONObject:
		b.WriteByte('{')
		keys := make([]string, 0, len(v.Fields))
		for k := range v.Fields {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		for i, k := range keys {
			if i > 0 {
				b.WriteByte(',')
			}
			escapeJSON(k, b)
			b.WriteByte(':')
			writeJSON(b, v.Fields[k])
		}
		b.WriteByte('}')
	default:
		panic(fmt.Sprintf("unknown JSON value %T", v))
	}
}

// escapeJSON writes a JSON string literal.
//
// The five shorthand escapes plus \b and \f, \u00XX for the remaining control
// characters, and every other character RAW including non-ASCII. Escaping
// non-ASCII would produce different bytes and therefore a different store path.
func escapeJSON(s string, b *strings.Builder) {
	b.WriteByte('"')
	for _, r := range s {
		switch r {
		case '"':
			b.WriteString(`\"`)
		case '\\':
			b.WriteString(`\\`)
		case '\n':
			b.WriteString(`\n`)
		case '\r':
			b.WriteString(`\r`)
		case '\t':
			b.WriteString(`\t`)
		case '\b':
			b.WriteString(`\b`)
		case '\f':
			b.WriteString(`\f`)
		default:
			if r < 0x20 {
				fmt.Fprintf(b, `\u%04x`, r)
			} else {
				b.WriteRune(r)
			}
		}
	}
	b.WriteByte('"')
}
