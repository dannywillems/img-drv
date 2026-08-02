// Package nix is the Nix EXPRESSION layer: write Nix in Go, print .nix.
//
// This is the second of the two term algebras in docs/architecture.md. The
// parent package is the FIRST-ORDER one (derivations, ATerm, store paths);
// this package is the SECOND-ORDER one, because Nix expressions have binders
// and derivations do not.
//
// It depends on the parent and the parent never depends on it, which is the
// rule that keeps a bug in the expression layer from being able to change a
// store path.
//
// Nothing here needs a parser. The transpiler is only the arrow EXPR -> .nix,
// so it is ast, emit and surface alone; goyacc arrives with the arrow the
// other way and is not a dependency of this package.
package nix

// The Nix language AST.
//
// Faithful to the grammar in NixOS/nix src/libexpr/parser.y at commit
// a86a3638, and deliberately NOT desugared: the AST records what was written.
//
// FINDING, and it revises the one recorded on JSONValue in the parent package.
//
// This is a 21-case sum, three times the size of the JSON one, and at that
// width the discriminant-struct encoding used for JSONValue stops being
// tenable: it would be a struct with 21 mostly-nil fields. So this uses the
// other Go encoding of a sum, a SEALED INTERFACE: an interface with an
// unexported marker method, which only types in this package can implement.
//
// The sealed interface is strictly better than the discriminant struct and it
// was available for JSONValue too. It costs one method per case instead of a
// field per case, and it makes Kind-disagrees-with-payload UNREPRESENTABLE,
// which was the exact defect noted on JSONValue. Recording that here rather
// than quietly fixing it: the earlier choice was the worse of Go's two
// options, and only writing the bigger sum made that obvious.
//
// What the sealed interface still does NOT buy, and what a variant does:
//
//  1. No exhaustiveness checking. A type switch that forgets a case compiles,
//     and falls through to default at runtime. OCaml and Rust reject it. Every
//     switch here therefore ends in a panic-on-unknown default, which converts
//     a silent wrong answer into a loud one but cannot prevent it.
//  2. The zero value is nil, so a nil Expr is a representable invalid term.
//     OCaml and Rust have no such value.
//
// Neither costs expressiveness. Both cost the compiler's help.

// Expr is a Nix expression.
//
// Sealed: only this package can implement it, because isExpr is unexported.
type Expr interface {
	isExpr()
}

// Int is an integer literal.
type Int struct{ Value int64 }

// Float is a float literal.
type Float struct{ Value float64 }

// Str is a double-quoted string, possibly interpolated.
type Str struct{ Parts []Part }

// IndStr is an indented string, the two-single-quote form.
type IndStr struct{ Parts []Part }

// PathLit is a path literal.
type PathLit struct{ Text string }

// SearchPath is <nixpkgs>.
type SearchPath struct{ Text string }

// URI is scheme:path. Note that x:x lexes as THIS and not as a lambda.
type URI struct{ Text string }

// Var is a variable reference.
type Var struct{ Name string }

// Lambda is pattern: body.
type Lambda struct {
	Pattern Pattern
	Body    Expr
}

// Apply is f a.
type Apply struct {
	Func Expr
	Arg  Expr
}

// Select is e.a.b, with an optional `or` default.
type Select struct {
	Expr    Expr
	Path    AttrPath
	Default Expr // nil when absent
}

// HasAttr is e ? a.b.
type HasAttr struct {
	Expr Expr
	Path AttrPath
}

// List is [ a b ].
type List struct{ Items []Expr }

// AttrSet is { a = b; }, or rec { ... }.
type AttrSet struct {
	Recursive bool
	Binds     []Binding
}

// Let is let a = b; in e.
type Let struct {
	Binds []Binding
	Body  Expr
}

// With is with e; body.
type With struct {
	Scope Expr
	Body  Expr
}

// Assert is assert c; body.
type Assert struct {
	Condition Expr
	Body      Expr
}

// If is if c then t else f.
type If struct {
	Condition Expr
	Then      Expr
	Else      Expr
}

// BinOp is a binary operator application.
type BinOp struct {
	Op    Op
	Left  Expr
	Right Expr
}

// Not is !e.
type Not struct{ Expr Expr }

// Neg is unary minus, which a differential printer desugars to __sub 0 e.
type Neg struct{ Expr Expr }

func (Int) isExpr()        {}
func (Float) isExpr()      {}
func (Str) isExpr()        {}
func (IndStr) isExpr()     {}
func (PathLit) isExpr()    {}
func (SearchPath) isExpr() {}
func (URI) isExpr()        {}
func (Var) isExpr()        {}
func (Lambda) isExpr()     {}
func (Apply) isExpr()      {}
func (Select) isExpr()     {}
func (HasAttr) isExpr()    {}
func (List) isExpr()       {}
func (AttrSet) isExpr()    {}
func (Let) isExpr()        {}
func (With) isExpr()       {}
func (Assert) isExpr()     {}
func (If) isExpr()         {}
func (BinOp) isExpr()      {}
func (Not) isExpr()        {}
func (Neg) isExpr()        {}

// Part is one piece of a string literal. Sealed, like Expr.
type Part interface {
	isPart()
}

// Lit is a literal run of characters.
type Lit struct{ Text string }

// Anti is an antiquotation, ${e}.
type Anti struct{ Expr Expr }

func (Lit) isPart()  {}
func (Anti) isPart() {}

// Attr is one component of an attribute path. Sealed, like Expr.
type Attr interface {
	isAttr()
}

// ID is an attribute named by an identifier, a.
type ID struct{ Name string }

// StrAttr is an attribute named by a string or interpolation, ."a" or .${e}.
type StrAttr struct{ Parts []Part }

func (ID) isAttr()      {}
func (StrAttr) isAttr() {}

// AttrPath is a.b.c.
type AttrPath []Attr

// Binding is one binding inside { ... } or let ... in. Sealed, like Expr.
type Binding interface {
	isBinding()
}

// Bind is a.b = e;.
type Bind struct {
	Path  AttrPath
	Value Expr
}

// Inherit is inherit (from) a b;.
type Inherit struct {
	Source Expr // nil when absent
	Attrs  []Attr
}

func (Bind) isBinding()    {}
func (Inherit) isBinding() {}

// Pattern is a lambda's parameter. Sealed, like Expr.
type Pattern interface {
	isPattern()
}

// PVar is x: ....
type PVar struct{ Name string }

// Formal is one entry of a set pattern, with an optional default.
type Formal struct {
	Name    string
	Default Expr // nil when absent
}

// PSet is { a, b ? d, ... } @ alias: ....
type PSet struct {
	Formals  []Formal
	Ellipsis bool
	Alias    string
}

func (PVar) isPattern() {}
func (PSet) isPattern() {}

// Op is a binary operator.
type Op uint8

// The binary operators, in the order of parser.y's precedence table.
const (
	OpAdd Op = iota
	OpSub
	OpMul
	OpDiv
	OpUpdate
	OpConcat
	OpEq
	OpNeq
	OpLt
	OpGt
	OpLe
	OpGe
	OpAnd
	OpOr
	OpImpl
)

// Text is the operator's spelling in Nix source.
func (o Op) Text() string {
	switch o {
	case OpAdd:
		return "+"
	case OpSub:
		return "-"
	case OpMul:
		return "*"
	case OpDiv:
		return "/"
	case OpUpdate:
		return "//"
	case OpConcat:
		return "++"
	case OpEq:
		return "=="
	case OpNeq:
		return "!="
	case OpLt:
		return "<"
	case OpGt:
		return ">"
	case OpLe:
		return "<="
	case OpGe:
		return ">="
	case OpAnd:
		return "&&"
	case OpOr:
		return "||"
	case OpImpl:
		return "->"
	}
	panic("unknown operator")
}
