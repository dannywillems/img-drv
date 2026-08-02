package nix

import (
	"fmt"
	"sort"
	"strconv"
	"strings"
)

// Print an AST the way nix-instantiate --parse does.
//
// This exists to be DIFFERENTIALLY TESTED. Nix re-prints the tree it parsed,
// fully parenthesised and partly desugared, so matching its output byte for
// byte over real files proves our tree has the same SHAPE as Nix's, which is
// far stronger than "it parsed".
//
// Not to be confused with emit.go, which writes .nix source a human reads and
// Nix evaluates. This one writes Nix's debug form.
//
// The desugarings are Nix's, not ours: a * b prints as (__mul a b), a - b as
// (__sub a b) while a + b keeps its +, unary minus as (__sub 0 a), an
// interpolated string as a + chain, and a constant dynamic attribute ${"c"}
// folds to a plain c.
//
// Everything about ORDER and QUOTING was established by probing the pinned Nix,
// never from memory; docs/abstractions.md entry 13 lists the eight rules.

var keywordSet = map[string]bool{
	"if": true, "then": true, "else": true, "assert": true, "with": true,
	"let": true, "in": true, "rec": true, "inherit": true,
}

// escapeLiteral escapes a string literal the way Nix prints one.
//
// Five ordinary escapes plus a sixth that only fires in context: a $ is escaped
// ONLY when it begins an interpolation, so "a$b" prints unescaped and a literal
// ${ prints as \${. Escaping every dollar would be valid Nix and would not be
// what --parse emits.
func escapeLiteral(text string) string {
	var b strings.Builder
	for i := 0; i < len(text); i++ {
		c := text[i]
		switch {
		case c == '"':
			b.WriteString(`\"`)
		case c == '\\':
			b.WriteString(`\\`)
		case c == '\n':
			b.WriteString(`\n`)
		case c == '\r':
			b.WriteString(`\r`)
		case c == '\t':
			b.WriteString(`\t`)
		case c == '$' && i+1 < len(text) && text[i+1] == '{':
			b.WriteString(`\$`)
		default:
			b.WriteByte(c)
		}
	}
	return b.String()
}

func isIdentifier(s string) bool {
	if s == "" || !isIDStart(s[0]) {
		return false
	}
	for i := 1; i < len(s); i++ {
		if !isIDChar(s[i]) {
			return false
		}
	}
	return true
}

// attrName renders an attribute name: bare when it is an identifier, quoted
// otherwise.
//
// A keyword is quoted even though it looks like an identifier, because a bare
// one would not parse back. `or` is the exception: Nix's grammar admits it as
// an attribute name and prints it bare.
func attrName(s string) string {
	if isIdentifier(s) && !keywordSet[s] {
		return s
	}
	return `"` + escapeLiteral(s) + `"`
}

// item is one entry of a bind tree.
//
// dynamic matters because Nix keeps static and dynamic attributes in two
// different containers, a sorted map and a source-order vector, and prints the
// map first.
type item struct {
	key      string
	dynamic  bool
	value    Expr   // nil when nested
	nested   []item // used when value is nil
	inherit  bool
	source   Expr // for an `inherit (e)` group
	inhAttrs []Attr
}

// keyOf is the RAW name, because Nix merges and sorts by SYMBOL.
//
// Sorting by the printed form puts every quoted name before every bare one,
// since a quote sorts below a letter. Quoting is applied at print time.
func keyOf(a Attr) string {
	switch a := a.(type) {
	case ID:
		return a.Name
	case StrAttr:
		if len(a.Parts) == 1 {
			if lit, ok := a.Parts[0].(Lit); ok {
				return lit.Text
			}
		}
	case DynAttr:
		if s, ok := a.Expr.(Str); ok && len(s.Parts) == 1 {
			if lit, ok := s.Parts[0].(Lit); ok {
				return lit.Text
			}
		}
	}
	return renderAttr(a)
}

func isDynamicAttr(a Attr) bool {
	switch a := a.(type) {
	case ID:
		return false
	case StrAttr:
		for _, p := range a.Parts {
			if _, ok := p.(Anti); ok {
				return true
			}
		}
		return false
	case DynAttr:
		if s, ok := a.Expr.(Str); ok && len(s.Parts) == 1 {
			if _, ok := s.Parts[0].(Lit); ok {
				return false
			}
		}
		return true
	}
	return true
}

// setBinds returns the bindings of an attribute-set value, for the merge cases.
//
// The recursive flag is accepted and dropped, which is what Nix does:
// { a = { b = 1; }; a = rec { c = 2; }; } prints as one NON-recursive set.
func setBinds(e Expr) ([]Binding, bool) {
	if s, ok := e.(AttrSet); ok {
		return s.Binds, true
	}
	return nil, false
}

func groupBinds(binds []Binding) []item {
	return addBinds(nil, binds)
}

func addBinds(items []item, binds []Binding) []item {
	for _, b := range binds {
		switch b := b.(type) {
		case Bind:
			items = insertBind(items, b.Path, b.Value)
		case Inherit:
			items = append(items, item{
				inherit: true, source: b.Source, inhAttrs: b.Attrs,
			})
		}
	}
	return items
}

// insertBind expands a dotted binding into nested sets and merges prefixes.
//
// { a.b.c = 1; } becomes { a = { b = { c = 1; }; }; } and
// { a.b = 1; a.c = 2; } becomes { a = { b = 1; c = 2; }; }, because Nix does
// that at parse time.
func insertBind(items []item, path AttrPath, value Expr) []item {
	if len(path) == 0 {
		return items
	}
	key, dyn := keyOf(path[0]), isDynamicAttr(path[0])

	if len(path) == 1 {
		// A leaf whose value is a set MERGES into an entry the dotted bindings
		// already opened, and TWO set-valued bindings with the same name merge
		// too. Nix rejects a duplicate scalar and quietly joins duplicate sets,
		// which real modules rely on.
		for i := range items {
			if items[i].inherit || items[i].key != key {
				continue
			}
			newBinds, ok := setBinds(value)
			if !ok {
				break
			}
			if items[i].value == nil {
				items[i].nested = addBinds(items[i].nested, newBinds)
				return items
			}
			if old, ok := setBinds(items[i].value); ok {
				items[i].nested = addBinds(groupBinds(old), newBinds)
				items[i].value = nil
				return items
			}
			break
		}
		return append(items, item{key: key, dynamic: dyn, value: value})
	}

	rest := path[1:]
	for i := range items {
		if items[i].inherit || items[i].key != key {
			continue
		}
		if items[i].value == nil {
			items[i].nested = insertBind(items[i].nested, rest, value)
			return items
		}
		// A leaf already holding a set is REOPENED rather than shadowed, so a
		// later dotted binding lands inside it.
		if old, ok := setBinds(items[i].value); ok {
			items[i].nested = insertBind(groupBinds(old), rest, value)
			items[i].value = nil
			return items
		}
		break
	}
	return append(items, item{
		key: key, dynamic: dyn, nested: insertBind(nil, rest, value),
	})
}

// renderItems prints an attribute set's or a let's bindings in Nix's order.
//
// An attribute set is a SORTED map keyed by symbol, so bindings print in name
// order rather than source order. Every PLAIN inherit merges into one statement
// with its names sorted and comes FIRST; each `inherit (e)` group keeps its
// identity and its source position; ordinary bindings follow, sorted; dynamic
// names come last in SOURCE order, because they are a separate container in Nix
// and not part of the sorted map.
func renderItems(items []item) string {
	var b strings.Builder

	var plain []Attr
	for _, it := range items {
		if it.inherit && it.source == nil {
			plain = append(plain, it.inhAttrs...)
		}
	}
	if len(plain) > 0 {
		sort.SliceStable(plain, func(i, j int) bool {
			return keyOf(plain[i]) < keyOf(plain[j])
		})
		b.WriteString("inherit")
		for _, a := range plain {
			b.WriteString(" " + renderAttr(a))
		}
		b.WriteString("; ")
	}

	for _, it := range items {
		if !it.inherit || it.source == nil {
			continue
		}
		attrs := append([]Attr(nil), it.inhAttrs...)
		sort.SliceStable(attrs, func(i, j int) bool {
			return keyOf(attrs[i]) < keyOf(attrs[j])
		})
		b.WriteString("inherit (" + renderExpr(it.source) + ")")
		for _, a := range attrs {
			b.WriteString(" " + renderAttr(a))
		}
		b.WriteString("; ")
	}

	var statics, dynamics []item
	for _, it := range items {
		if it.inherit {
			continue
		}
		if it.dynamic {
			dynamics = append(dynamics, it)
		} else {
			statics = append(statics, it)
		}
	}
	sort.SliceStable(statics, func(i, j int) bool {
		return statics[i].key < statics[j].key
	})
	for _, it := range append(statics, dynamics...) {
		// The key held here is the RAW name, so quoting happens now: a dynamic
		// key is already printed syntax and goes out verbatim.
		shown := it.key
		if !it.dynamic {
			shown = attrName(it.key)
		}
		if it.value != nil {
			b.WriteString(shown + " = " + renderExpr(it.value) + "; ")
		} else {
			b.WriteString(shown + " = { " + renderItems(it.nested) + "}; ")
		}
	}
	return b.String()
}

func renderAttr(a Attr) string {
	switch a := a.(type) {
	case ID:
		return attrName(a.Name)
	case StrAttr:
		if len(a.Parts) == 1 {
			if lit, ok := a.Parts[0].(Lit); ok {
				return attrName(lit.Text)
			}
		}
		// A dynamic attribute becomes ONE interpolation wrapping the whole
		// string expression: { "a${m}b" = 1; } prints as
		// { "${("a" + m + "b")}" = 1; }.
		return `"${` + renderParts(a.Parts) + `}"`
	case DynAttr:
		// a.${"c"}: a constant string folds to a plain name, as a."c" does.
		if s, ok := a.Expr.(Str); ok && len(s.Parts) == 1 {
			if lit, ok := s.Parts[0].(Lit); ok {
				return attrName(lit.Text)
			}
		}
		// a.${k}: the expression IS the name, so a bare variable stays bare.
		return `"${` + renderExpr(a.Expr) + `}"`
	}
	panic(fmt.Sprintf("unknown attribute %T", a))
}

func renderAttrPath(path AttrPath) string {
	parts := make([]string, 0, len(path))
	for _, a := range path {
		parts = append(parts, renderAttr(a))
	}
	return strings.Join(parts, ".")
}

func renderParts(parts []Part) string {
	if len(parts) == 0 {
		return `""`
	}
	if len(parts) == 1 {
		if lit, ok := parts[0].(Lit); ok {
			return `"` + escapeLiteral(lit.Text) + `"`
		}
	}
	// An interpolated string is a + chain. No parentheses of our own: the
	// interpolated expression supplies its own.
	pieces := make([]string, 0, len(parts))
	for _, p := range parts {
		switch p := p.(type) {
		case Lit:
			pieces = append(pieces, `"`+escapeLiteral(p.Text)+`"`)
		case Anti:
			pieces = append(pieces, renderExpr(p.Expr))
		}
	}
	return "(" + strings.Join(pieces, " + ") + ")"
}

func renderPattern(p Pattern) string {
	switch p := p.(type) {
	case PVar:
		return p.Name
	case PSet:
		// Formals are a sorted map too.
		formals := append([]Formal(nil), p.Formals...)
		sort.SliceStable(formals, func(i, j int) bool {
			return formals[i].Name < formals[j].Name
		})
		pieces := make([]string, 0, len(formals))
		for _, f := range formals {
			if f.Default == nil {
				pieces = append(pieces, f.Name)
			} else {
				pieces = append(pieces, f.Name+" ? "+renderExpr(f.Default))
			}
		}
		body := strings.Join(pieces, ", ")
		if p.Ellipsis {
			if len(formals) == 0 {
				body = "..."
			} else {
				body += ", ..."
			}
		}
		out := "{ " + body + " }"
		if p.Alias != "" {
			out += " @ " + p.Alias
		}
		return out
	}
	panic(fmt.Sprintf("unknown pattern %T", p))
}

// renderApply prints application FLATTENED: f 1 2 is one pair of parentheses.
func renderApply(e Expr) string {
	if a, ok := e.(Apply); ok {
		return renderApply(a.Func) + " " + renderExpr(a.Arg)
	}
	return renderExpr(e)
}

// renderExpr is the type switch a variant would make exhaustive.
//
// Go does not check that every case is present, so the default panics rather
// than silently emitting nothing: a missing case becomes a loud failure in the
// first test that reaches it, which is the best this encoding allows. The other
// three implementations had this checked by the compiler.
func renderExpr(e Expr) string {
	switch e := e.(type) {
	case Int:
		return strconv.FormatInt(e.Value, 10)
	case Float:
		// C's %g, which is what Nix uses: 3.0 prints as 3.
		return strconv.FormatFloat(e.Value, 'g', -1, 64)
	case Var:
		return e.Name
	case PathLit:
		return e.Text
	case PathInterp:
		return renderParts(e.Parts)
	case SearchPath:
		// <nixpkgs> desugars to a search-path lookup, which is why a search
		// path is impure: it reads NIX_PATH at evaluation time.
		return `(__findFile __nixPath "` + escapeLiteral(e.Text) + `")`
	case URI:
		return `"` + escapeLiteral(e.Text) + `"`
	case Str:
		return renderParts(e.Parts)
	case IndStr:
		return renderParts(e.Parts)
	case Not:
		return "(! " + renderExpr(e.Expr) + ")"
	case Neg:
		return "(__sub 0 " + renderExpr(e.Expr) + ")"
	case BinOp:
		return renderBinOp(e)
	case HasAttr:
		return "((" + renderExpr(e.Expr) + ") ? " + renderAttrPath(e.Path) + ")"
	case Apply:
		return "(" + renderApply(e.Func) + " " + renderExpr(e.Arg) + ")"
	case Select:
		head := "(" + renderExpr(e.Expr) + ")." + renderAttrPath(e.Path)
		if e.Default == nil {
			return head
		}
		return head + " or (" + renderExpr(e.Default) + ")"
	case Lambda:
		return "(" + renderPattern(e.Pattern) + ": " + renderExpr(e.Body) + ")"
	case List:
		var b strings.Builder
		b.WriteString("[ ")
		for _, i := range e.Items {
			b.WriteString("(" + renderExpr(i) + ") ")
		}
		b.WriteString("]")
		return b.String()
	case AttrSet:
		rec := ""
		if e.Recursive {
			rec = "rec "
		}
		return rec + "{ " + renderItems(groupBinds(e.Binds)) + "}"
	case Let:
		return "(let " + renderItems(groupBinds(e.Binds)) + "in " +
			renderExpr(e.Body) + ")"
	case With:
		return "(with " + renderExpr(e.Scope) + "; " + renderExpr(e.Body) + ")"
	case Assert:
		// Nix prints assert WITHOUT wrapping parentheses.
		return "assert " + renderExpr(e.Condition) + "; " + renderExpr(e.Body)
	case If:
		return "(if " + renderExpr(e.Condition) + " then " +
			renderExpr(e.Then) + " else " + renderExpr(e.Else) + ")"
	}
	panic(fmt.Sprintf("unknown expression %T", e))
}

// The comparisons all reduce to __lessThan, three with a swap or a negation.
func renderBinOp(e BinOp) string {
	l, r := renderExpr(e.Left), renderExpr(e.Right)
	switch e.Op {
	case OpLt:
		return "(__lessThan " + l + " " + r + ")"
	case OpGt:
		return "(__lessThan " + r + " " + l + ")"
	case OpGe:
		return "(! (__lessThan " + l + " " + r + "))"
	case OpLe:
		return "(! (__lessThan " + r + " " + l + "))"
	case OpSub:
		return "(__sub " + l + " " + r + ")"
	case OpMul:
		return "(__mul " + l + " " + r + ")"
	case OpDiv:
		return "(__div " + l + " " + r + ")"
	}
	return "(" + l + " " + e.Op.Text() + " " + r + ")"
}

// ToParseForm renders the AST the way nix-instantiate --parse prints it.
func ToParseForm(e Expr) string {
	return renderExpr(e)
}
