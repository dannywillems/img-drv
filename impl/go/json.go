package imgdrv

import (
	"fmt"
	"sort"
	"strconv"
	"strings"
)

// A JSON value, and the canonical serialization __structuredAttrs uses.
//
// FINDING, and the sharpest one in the Go implementation. This is the first
// RECURSIVE type in the signature: everything else is a product of primitives
// and lists of them, which is what docs/theory.md section 1 restricts the
// signature to. A JSON value is an inductive datatype, a fixed point of a
// polynomial functor, and it is a SEVEN-CASE SUM.
//
// Go has neither sum types nor `any` we are willing to use (AGENTS rule 4
// forbids `any` in the signature), so the only honest encoding is a struct
// with an explicit discriminant and one field per case, plus a constructor per
// case. That is precisely the degradation AGENTS.md predicts, and here it
// costs a 7-field struct and 7 constructors where Rust and OCaml each write a
// 7-case variant and Python writes a recursive type alias.
//
// The cost is not expressiveness: everything is representable, the JSON round
// trips, and the bytes match. The cost is that JSONValue{} is a valid value of
// an invalid shape, so `Kind` and the fields can disagree and only a runtime
// check notices. A variant makes that unrepresentable.

// JSONKind is the discriminant of a JSONValue.
type JSONKind uint8

// The seven cases of a JSON value.
const (
	JSONNull JSONKind = iota
	JSONBool
	JSONInt
	JSONFloat
	JSONString
	JSONArray
	JSONObject
)

// JSONValue is one JSON value.
//
// Exactly one field is meaningful, selected by Kind. Prefer the constructors
// below to building one literally.
type JSONValue struct {
	Kind   JSONKind
	Bool   bool
	Int    int64
	Float  float64
	Str    string
	Array  []JSONValue
	Object map[string]JSONValue
}

// Null is the JSON null.
func Null() JSONValue { return JSONValue{Kind: JSONNull} }

// Bool wraps a boolean.
func Bool(b bool) JSONValue { return JSONValue{Kind: JSONBool, Bool: b} }

// Int wraps a 64-bit integer, which is what Nix integers are.
func Int(i int64) JSONValue { return JSONValue{Kind: JSONInt, Int: i} }

// Float wraps a double.
func Float(f float64) JSONValue { return JSONValue{Kind: JSONFloat, Float: f} }

// Str wraps a string.
func Str(s string) JSONValue { return JSONValue{Kind: JSONString, Str: s} }

// Array wraps a list. Order is significant.
func Array(items ...JSONValue) JSONValue {
	return JSONValue{Kind: JSONArray, Array: items}
}

// Object wraps a map. Keys are sorted at serialization time.
func Object(fields map[string]JSONValue) JSONValue {
	return JSONValue{Kind: JSONObject, Object: fields}
}

// Strings is the common case: an array of strings.
func Strings(items ...string) JSONValue {
	out := make([]JSONValue, 0, len(items))
	for _, s := range items {
		out = append(out, Str(s))
	}
	return Array(out...)
}

// IsString reports whether this value is a JSON string.
//
// Needed because the flat env encoding can only carry strings, so a Build
// without StructuredAttrs has to refuse anything else.
func (v JSONValue) IsString() bool { return v.Kind == JSONString }

// JSON is the canonical serialization: sorted keys, compact separators, and
// non-ASCII emitted raw rather than \uXXXX escaped.
//
// All three hold on 456 of 456 structured derivations in a real closure.
func (v JSONValue) JSON() string {
	var b strings.Builder
	v.write(&b)
	return b.String()
}

func (v JSONValue) write(b *strings.Builder) {
	switch v.Kind {
	case JSONNull:
		b.WriteString("null")
	case JSONBool:
		if v.Bool {
			b.WriteString("true")
		} else {
			b.WriteString("false")
		}
	case JSONInt:
		b.WriteString(strconv.FormatInt(v.Int, 10))
	case JSONFloat:
		if v.Float == float64(int64(v.Float)) {
			fmt.Fprintf(b, "%.1f", v.Float)
		} else {
			b.WriteString(strconv.FormatFloat(v.Float, 'g', -1, 64))
		}
	case JSONString:
		escapeJSON(v.Str, b)
	case JSONArray:
		b.WriteByte('[')
		for i, item := range v.Array {
			if i > 0 {
				b.WriteByte(',')
			}
			item.write(b)
		}
		b.WriteByte(']')
	case JSONObject:
		b.WriteByte('{')
		keys := make([]string, 0, len(v.Object))
		for k := range v.Object {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		for i, k := range keys {
			if i > 0 {
				b.WriteByte(',')
			}
			escapeJSON(k, b)
			b.WriteByte(':')
			v.Object[k].write(b)
		}
		b.WriteByte('}')
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
