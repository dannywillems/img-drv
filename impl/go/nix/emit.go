package nix

import (
	"fmt"
	"strconv"
	"strings"
)

// Print an AST as valid Nix SOURCE. This is the transpiler.
//
// The arrow EXPR -> .nix of docs/architecture.md.
//
// Fully parenthesised, on purpose. Extra parentheses cannot change a parse, so
// the emitted file is correct BY CONSTRUCTION rather than correct if the
// precedence table was transcribed properly. docs/nix-internals.md records two
// levels that surprise everyone (! binds looser than +, // tighter than the
// comparisons); a minimal-parenthesis printer has to get both right and this
// one cannot get them wrong.
//
// Making the output pretty is a separate, later job with its own test: emit,
// re-parse, compare the ASTs.

// escaper rewrites the characters that cannot appear raw in a Nix string.
//
// The $ is the one that matters and the one that is easy to miss: Nix reads
// ${ as the start of an antiquotation, so a literal dollar must be escaped or
// the file either fails to parse or, worse, parses with a different meaning.
var escaper = strings.NewReplacer(
	`"`, `\"`,
	`\`, `\\`,
	"\n", `\n`,
	"\r", `\r`,
	"\t", `\t`,
	`$`, `\$`,
)

func escape(s string) string { return escaper.Replace(s) }

func writeParts(b *strings.Builder, parts []Part) {
	b.WriteString(`"`)
	for _, p := range parts {
		switch p := p.(type) {
		case Lit:
			b.WriteString(escape(p.Text))
		case Anti:
			b.WriteString("${")
			writeExpr(b, p.Expr)
			b.WriteString("}")
		default:
			panic(fmt.Sprintf("unknown string part %T", p))
		}
	}
	b.WriteString(`"`)
}

func writeAttr(b *strings.Builder, a Attr) {
	switch a := a.(type) {
	case ID:
		b.WriteString(a.Name)
	case StrAttr:
		if len(a.Parts) == 1 {
			if lit, ok := a.Parts[0].(Lit); ok {
				b.WriteString(`"` + escape(lit.Text) + `"`)
				return
			}
		}
		b.WriteString("${")
		writeParts(b, a.Parts)
		b.WriteString("}")
	default:
		panic(fmt.Sprintf("unknown attribute %T", a))
	}
}

func writeAttrPath(b *strings.Builder, path AttrPath) {
	for i, a := range path {
		if i > 0 {
			b.WriteString(".")
		}
		writeAttr(b, a)
	}
}

func writeBinding(b *strings.Builder, bind Binding) {
	switch bind := bind.(type) {
	case Bind:
		writeAttrPath(b, bind.Path)
		b.WriteString(" = ")
		writeExpr(b, bind.Value)
		b.WriteString("; ")
	case Inherit:
		b.WriteString("inherit")
		if bind.Source != nil {
			b.WriteString(" (")
			writeExpr(b, bind.Source)
			b.WriteString(")")
		}
		for _, a := range bind.Attrs {
			b.WriteString(" ")
			writeAttr(b, a)
		}
		b.WriteString("; ")
	default:
		panic(fmt.Sprintf("unknown binding %T", bind))
	}
}

func writePattern(b *strings.Builder, p Pattern) {
	switch p := p.(type) {
	case PVar:
		b.WriteString(p.Name)
	case PSet:
		b.WriteString("{ ")
		for i, f := range p.Formals {
			if i > 0 {
				b.WriteString(", ")
			}
			b.WriteString(f.Name)
			if f.Default != nil {
				b.WriteString(" ? ")
				writeExpr(b, f.Default)
			}
		}
		if p.Ellipsis {
			if len(p.Formals) == 0 {
				b.WriteString("...")
			} else {
				b.WriteString(", ...")
			}
		}
		b.WriteString(" }")
		if p.Alias != "" {
			b.WriteString(" @ " + p.Alias)
		}
	default:
		panic(fmt.Sprintf("unknown pattern %T", p))
	}
}

// writeExpr is the type switch a variant would make exhaustive.
//
// Go does not check that every case is present, so the default panics rather
// than silently emitting nothing. A missing case is then a loud failure in the
// first test that reaches it, which is the best this encoding allows.
func writeExpr(b *strings.Builder, e Expr) {
	switch e := e.(type) {
	case Int:
		b.WriteString(strconv.FormatInt(e.Value, 10))
	case Float:
		b.WriteString(strconv.FormatFloat(e.Value, 'g', -1, 64))
	case Var:
		b.WriteString(e.Name)
	case PathLit:
		b.WriteString(e.Text)
	case SearchPath:
		b.WriteString("<" + e.Text + ">")
	case URI:
		b.WriteString(`"` + escape(e.Text) + `"`)
	case Str:
		writeParts(b, e.Parts)
	case IndStr:
		writeParts(b, e.Parts)
	case Not:
		b.WriteString("(!")
		writeExpr(b, e.Expr)
		b.WriteString(")")
	case Neg:
		b.WriteString("(-")
		writeExpr(b, e.Expr)
		b.WriteString(")")
	case BinOp:
		b.WriteString("(")
		writeExpr(b, e.Left)
		b.WriteString(" " + e.Op.Text() + " ")
		writeExpr(b, e.Right)
		b.WriteString(")")
	case HasAttr:
		b.WriteString("(")
		writeExpr(b, e.Expr)
		b.WriteString(" ? ")
		writeAttrPath(b, e.Path)
		b.WriteString(")")
	case Apply:
		b.WriteString("(")
		writeExpr(b, e.Func)
		b.WriteString(" ")
		writeExpr(b, e.Arg)
		b.WriteString(")")
	case Select:
		b.WriteString("(")
		writeExpr(b, e.Expr)
		b.WriteString(".")
		writeAttrPath(b, e.Path)
		if e.Default != nil {
			b.WriteString(" or ")
			writeExpr(b, e.Default)
		}
		b.WriteString(")")
	case Lambda:
		b.WriteString("(")
		writePattern(b, e.Pattern)
		b.WriteString(": ")
		writeExpr(b, e.Body)
		b.WriteString(")")
	case List:
		b.WriteString("[ ")
		for _, i := range e.Items {
			writeExpr(b, i)
			b.WriteString(" ")
		}
		b.WriteString("]")
	case AttrSet:
		if e.Recursive {
			b.WriteString("rec ")
		}
		b.WriteString("{ ")
		for _, bind := range e.Binds {
			writeBinding(b, bind)
		}
		b.WriteString("}")
	case Let:
		b.WriteString("(let ")
		for _, bind := range e.Binds {
			writeBinding(b, bind)
		}
		b.WriteString("in ")
		writeExpr(b, e.Body)
		b.WriteString(")")
	case With:
		b.WriteString("(with ")
		writeExpr(b, e.Scope)
		b.WriteString("; ")
		writeExpr(b, e.Body)
		b.WriteString(")")
	case Assert:
		b.WriteString("(assert ")
		writeExpr(b, e.Condition)
		b.WriteString("; ")
		writeExpr(b, e.Body)
		b.WriteString(")")
	case If:
		b.WriteString("(if ")
		writeExpr(b, e.Condition)
		b.WriteString(" then ")
		writeExpr(b, e.Then)
		b.WriteString(" else ")
		writeExpr(b, e.Else)
		b.WriteString(")")
	default:
		panic(fmt.Sprintf("unknown expression %T", e))
	}
}

// ToNix renders the AST as Nix source.
func ToNix(e Expr) string {
	var b strings.Builder
	b.Grow(512)
	writeExpr(&b, e)
	return b.String()
}
