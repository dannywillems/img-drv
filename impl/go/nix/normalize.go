package nix

import "fmt"

// What emit.go forgets, named precisely.
//
// emit and parse are the two arrows between EXPR and source text. Their law is
// a RETRACTION, parse(emit(e)) == e, but it does not hold on the nose, and the
// three things it holds only up to are worth naming rather than hiding,
// because each one says something about Nix.
//
// LITERAL CHUNKING CARRIES NO MEANING.
//
// Nix's lexer splits a string into chunks at boundaries that depend on which
// ESCAPES were used, not on the value: an escaped dollar between two words
// gives three parts, and the same characters written plainly give one.
// nix-instantiate --parse shows that difference, printing ("a" + "$" + "b")
// for the first and "a$b" for the second, and Nix EVALUATES both identically.
//
// So the debug form our differential oracle compares against is FINER than
// semantic equality. That is what we want for testing a parser, since it pins
// more; it means the round-trip law has to be stated in the quotient, because
// emit writes the characters and cannot write the chunking.
//
// AN INDENTED STRING STOPS EXISTING AT PARSE TIME.
//
// Nix has no indented-string node: the two-quote form is an ExprString once
// the dedent has run, and the indentation is gone for good. IndStr is our
// invention and holds nothing that could write the original back.
//
// A URI LITERAL IS A STRING.
//
// x:x is a URI to the LEXER, which is why it is not a lambda, and --parse
// prints it as "x:x". Nix keeps no URI node either.
//
// All three quotients are semantic no-ops, and each names a node WE invented
// that Nix does not keep. Normalising by them is the honest statement of the
// law, not a way of making a failing test pass; that all three are our own
// inventions is itself the finding.

func normalizeParts(input []Part) []Part {
	out := make([]Part, 0, len(input))
	for _, p := range input {
		if anti, ok := p.(Anti); ok {
			out = append(out, Anti{Expr: Normalize(anti.Expr)})
			continue
		}
		lit := p.(Lit)
		if n := len(out); n > 0 {
			if prev, ok := out[n-1].(Lit); ok {
				out[n-1] = Lit{Text: prev.Text + lit.Text}
				continue
			}
		}
		out = append(out, lit)
	}
	return out
}

func normalizeAttr(a Attr) Attr {
	switch a := a.(type) {
	case ID:
		return a
	case StrAttr:
		return StrAttr{Parts: normalizeParts(a.Parts)}
	case DynAttr:
		return DynAttr{Expr: Normalize(a.Expr)}
	}
	panic(fmt.Sprintf("unknown attribute %T", a))
}

func normalizePath(p AttrPath) AttrPath {
	out := make(AttrPath, 0, len(p))
	for _, a := range p {
		out = append(out, normalizeAttr(a))
	}
	return out
}

func normalizeBindings(binds []Binding) []Binding {
	out := make([]Binding, 0, len(binds))
	for _, b := range binds {
		switch b := b.(type) {
		case Bind:
			out = append(out, Bind{
				Path: normalizePath(b.Path), Value: Normalize(b.Value),
			})
		case Inherit:
			var source Expr
			if b.Source != nil {
				source = Normalize(b.Source)
			}
			attrs := make([]Attr, 0, len(b.Attrs))
			for _, a := range b.Attrs {
				attrs = append(attrs, normalizeAttr(a))
			}
			out = append(out, Inherit{Source: source, Attrs: attrs})
		default:
			panic(fmt.Sprintf("unknown binding %T", b))
		}
	}
	return out
}

func normalizePattern(p Pattern) Pattern {
	switch p := p.(type) {
	case PVar:
		return p
	case PSet:
		formals := make([]Formal, 0, len(p.Formals))
		for _, f := range p.Formals {
			if f.Default != nil {
				f.Default = Normalize(f.Default)
			}
			formals = append(formals, f)
		}
		return PSet{Formals: formals, Ellipsis: p.Ellipsis, Alias: p.Alias}
	}
	panic(fmt.Sprintf("unknown pattern %T", p))
}

// Normalize returns the normal form: literals joined, indented strings and URIs
// folded.
//
// Go does not check that this type switch is exhaustive, so the default panics
// rather than silently returning a wrong tree. A missing case here would make
// the round-trip law compare something other than what it says it compares,
// which is the worst kind of green.
func Normalize(e Expr) Expr {
	switch e := e.(type) {
	case Str:
		return Str{Parts: normalizeParts(e.Parts)}
	// Nix keeps no indented-string node past parsing, so neither does the
	// normal form.
	case IndStr:
		return Str{Parts: normalizeParts(e.Parts)}
	case PathInterp:
		return PathInterp{Parts: normalizeParts(e.Parts)}
	// Nix keeps no URI node either: x:x parses to a string.
	case URI:
		return Str{Parts: []Part{Lit{Text: e.Text}}}
	case Int, Float, PathLit, SearchPath, Var:
		return e
	case Lambda:
		return Lambda{Pattern: normalizePattern(e.Pattern), Body: Normalize(e.Body)}
	case Apply:
		return Apply{Func: Normalize(e.Func), Arg: Normalize(e.Arg)}
	case Select:
		out := Select{Expr: Normalize(e.Expr), Path: normalizePath(e.Path)}
		if e.Default != nil {
			out.Default = Normalize(e.Default)
		}
		return out
	case HasAttr:
		return HasAttr{Expr: Normalize(e.Expr), Path: normalizePath(e.Path)}
	case List:
		items := make([]Expr, 0, len(e.Items))
		for _, i := range e.Items {
			items = append(items, Normalize(i))
		}
		return List{Items: items}
	case AttrSet:
		return AttrSet{
			Recursive: e.Recursive, Binds: normalizeBindings(e.Binds),
		}
	case Let:
		return Let{Binds: normalizeBindings(e.Binds), Body: Normalize(e.Body)}
	case With:
		return With{Scope: Normalize(e.Scope), Body: Normalize(e.Body)}
	case Assert:
		return Assert{Condition: Normalize(e.Condition), Body: Normalize(e.Body)}
	case If:
		return If{
			Condition: Normalize(e.Condition),
			Then:      Normalize(e.Then),
			Else:      Normalize(e.Else),
		}
	case BinOp:
		return BinOp{Op: e.Op, Left: Normalize(e.Left), Right: Normalize(e.Right)}
	case Not:
		return Not{Expr: Normalize(e.Expr)}
	case Neg:
		return Neg{Expr: Normalize(e.Expr)}
	}
	panic(fmt.Sprintf("unknown expression %T", e))
}
