package nix

import "fmt"

// The surface: build Nix expressions in Go.
//
// This is what a developer writes instead of learning the Nix language. It
// hands back Expr values, the inspectable core, so everything downstream works
// on data rather than on host closures.
//
// BINDERS ARE HOAS HERE AND NAMED UNDERNEATH.
//
// A lambda is written with a Go function:
//
//	Lam("x", func(x Expr) Expr { return Attrs(P("name", x)) })
//
// which is what makes it composable and frees the caller from inventing names.
// Lam lowers that to a NAMED binder immediately, with a fresh supply, because
// the printer needs a name to print. That two-layer split is the
// recommendation in docs/theory.md section 8, and this file is the only place
// in the package that ever sees a host closure.
//
// The Go surface needs a helper the other three do not: Pair. OCaml and Rust
// have tuple literals and Python has keyword-ordered dicts, so an attribute
// set is written directly as a list of pairs. Go has no tuple literal, so the
// pairs are a named struct and P is its constructor. That is the same shape of
// cost the parent package's JSONValue paid, and again it is ergonomic rather
// than expressive.

// counter is the fresh-name supply.
//
// Ambient package state, like OCaml's and Python's. Rust cannot do this
// without unsafe and uses a thread-local Cell instead, which makes explicit
// what this leaves implicit: the surface is stateful and is not safe to use
// from two goroutines at once.
var counter int

// Reset restarts the fresh-name supply, so a term prints identically twice.
func Reset() { counter = 0 }

func fresh(base string) string {
	counter++
	return fmt.Sprintf("%s%d", base, counter)
}

// Pair is one attribute-set entry. See the note above on why this exists.
type Pair struct {
	Name  string
	Value Expr
}

// P builds a Pair.
func P(name string, value Expr) Pair { return Pair{Name: name, Value: value} }

// Literals

// I is an integer literal.
func I(n int64) Expr { return Int{Value: n} }

// F is a float literal.
func F(f float64) Expr { return Float{Value: f} }

// S is a plain string literal.
func S(s string) Expr { return Str{Parts: []Part{Lit{Text: s}}} }

// Path is a path literal.
func Path(p string) Expr { return PathLit{Text: p} }

// SPath is <nixpkgs>, a search-path lookup.
//
// Impure: it reads NIX_PATH when evaluated, which is why a reproducible caller
// pins it.
func SPath(p string) Expr { return SearchPath{Text: p} }

// V is a variable reference.
func V(x string) Expr { return Var{Name: x} }

// B is true or false, which are ordinary variables in Nix.
func B(b bool) Expr {
	if b {
		return Var{Name: "true"}
	}
	return Var{Name: "false"}
}

// Null is the null literal, likewise an ordinary variable.
func Null() Expr { return Var{Name: "null"} }

// IStr builds an interpolated string.
//
// A string argument is literal text and an Expr is interpolated, so
// IStr("cat ", a, " > $out") is "cat ${a} > $out". Any other type panics,
// which is the price of the variadic: Go cannot express "string or Expr" as a
// parameter type without a sealed interface neither side would want to write
// at every call.
func IStr(pieces ...any) Expr {
	parts := make([]Part, 0, len(pieces))
	for _, p := range pieces {
		switch p := p.(type) {
		case string:
			parts = append(parts, Lit{Text: p})
		case Expr:
			parts = append(parts, Anti{Expr: p})
		default:
			panic(fmt.Sprintf("IStr takes string or Expr, got %T", p))
		}
	}
	return Str{Parts: parts}
}

// Structure

// L is a list literal.
func L(items ...Expr) Expr { return List{Items: items} }

func bindsOf(pairs []Pair) []Binding {
	binds := make([]Binding, 0, len(pairs))
	for _, p := range pairs {
		binds = append(binds, Bind{Path: AttrPath{ID{Name: p.Name}}, Value: p.Value})
	}
	return binds
}

// Attrs is an attribute set. Declaration order is preserved, as Nix source is.
func Attrs(pairs ...Pair) Expr {
	return AttrSet{Recursive: false, Binds: bindsOf(pairs)}
}

// RecAttrs is a recursive attribute set: bindings can refer to each other.
func RecAttrs(pairs ...Pair) Expr {
	return AttrSet{Recursive: true, Binds: bindsOf(pairs)}
}

func idPath(names []string) AttrPath {
	path := make(AttrPath, 0, len(names))
	for _, n := range names {
		path = append(path, ID{Name: n})
	}
	return path
}

// Sel is e.a.b.
func Sel(e Expr, names ...string) Expr {
	return Select{Expr: e, Path: idPath(names)}
}

// SelOr is e.a.b or default.
func SelOr(e Expr, def Expr, names ...string) Expr {
	return Select{Expr: e, Path: idPath(names), Default: def}
}

// App is curried application: App(f, a, b) is ((f a) b).
func App(f Expr, args ...Expr) Expr {
	out := f
	for _, a := range args {
		out = Apply{Func: out, Arg: a}
	}
	return out
}

// Binders

// Lam is a lambda, written with a Go function.
//
// The bound variable is materialised as a fresh NAME, so the result is
// ordinary inspectable syntax rather than a closure.
func Lam(name string, f func(Expr) Expr) Expr {
	n := fresh(name)
	return Lambda{Pattern: PVar{Name: n}, Body: f(Var{Name: n})}
}

// LamAttrs is a lambda taking an attribute set, { a, b ? d }: body.
//
// The body receives a LOOKUP function rather than a struct, because the
// formals are named by the caller at runtime and no host type can give them
// back as fields.
func LamAttrs(formals []Formal, ellipsis bool, f func(func(string) Expr) Expr) Expr {
	body := f(func(name string) Expr { return Var{Name: name} })
	return Lambda{
		Pattern: PSet{Formals: formals, Ellipsis: ellipsis},
		Body:    body,
	}
}

// LetPairs is let a = ...; in body, with the bindings in scope in each other.
func LetPairs(pairs []Pair, body Expr) Expr {
	return Let{Binds: bindsOf(pairs), Body: body}
}

// LetIn binds one value and uses it, without naming it.
//
// The composable form: the caller never sees the generated name, so two
// independently written fragments cannot capture each other's variables.
func LetIn(name string, value Expr, f func(Expr) Expr) Expr {
	n := fresh(name)
	return Let{
		Binds: []Binding{Bind{Path: AttrPath{ID{Name: n}}, Value: value}},
		Body:  f(Var{Name: n}),
	}
}

// Operators

// Plus is a + b.
func Plus(a, b Expr) Expr { return BinOp{Op: OpAdd, Left: a, Right: b} }

// Update is a // b: b wins on a clash.
func Update(a, b Expr) Expr { return BinOp{Op: OpUpdate, Left: a, Right: b} }

// Concat is a ++ b.
func Concat(a, b Expr) Expr { return BinOp{Op: OpConcat, Left: a, Right: b} }

// Eq is a == b.
func Eq(a, b Expr) Expr { return BinOp{Op: OpEq, Left: a, Right: b} }

// Cond is if c then t else f.
func Cond(c, t, f Expr) Expr { return If{Condition: c, Then: t, Else: f} }

// Composability: overlays as mixins

// Overlay is final: prev: { ... }.
//
// Cook and Palsberg's wrapper over a generator (docs/theory.md section 8), and
// Fix is the map out of it.
//
// Overlays form a MONOID under Compose, but only UP TO NIX SEMANTICS, not up
// to syntax. Compose(OverlayID, o) emits ({ } // o) rather than o, and the two
// bracketings of Compose nest // differently; those terms are equal when Nix
// evaluates them and are not equal as syntax. See docs/abstractions.md entry
// 11.
type Overlay func(final, prev Expr) Expr

// OverlayID is the identity overlay: adds nothing.
func OverlayID(_, _ Expr) Expr { return Attrs() }

// Compose applies a first, then b on top, so b wins on a clash.
//
// That matches how a later overlay in a list overrides an earlier one.
func Compose(a, b Overlay) Overlay {
	return func(final, prev Expr) Expr {
		afterA := a(final, prev)
		return Update(afterA, b(final, Update(prev, afterA)))
	}
}

// ComposeAll folds a list of overlays into one.
func ComposeAll(overlays ...Overlay) Overlay {
	out := Overlay(OverlayID)
	for _, o := range overlays {
		out = Compose(out, o)
	}
	return out
}

// Fix closes an overlay into a package set with the knot tied.
//
// Emits (let base = ...; final = base // (overlay final base); in final): the
// fixed point is written OUT in Nix rather than computed here, because the
// point of a transpiler is that the output does the work.
//
// `base` is BOUND, not inlined. `fix` passes it to the overlay as `prev` as
// well as using it on the left of `//`, so inlining it would duplicate the
// whole expression into the output, once per mention. The hand-written Nix a
// reader would compare against binds it too.
func Fix(base Expr, o Overlay) Expr {
	b := fresh("base")
	n := fresh("final")
	added := o(Var{Name: n}, Var{Name: b})
	return Let{
		Binds: []Binding{
			Bind{Path: AttrPath{ID{Name: b}}, Value: base},
			Bind{
				Path:  AttrPath{ID{Name: n}},
				Value: Update(Var{Name: b}, added),
			},
		},
		Body: Var{Name: n},
	}
}
