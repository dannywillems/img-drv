//! The Nix language AST.
//!
//! Faithful to the grammar in `NixOS/nix` `src/libexpr/parser.y` at commit
//! `a86a3638`, and deliberately NOT desugared: the AST records what was
//! written.
//!
//! This is the same type as `impl/ocaml/nix/ast.ml`, and the two read almost
//! identically: Rust's `enum` is a sum type, so the 21 forms are 21 variants
//! and every `match` over them is checked exhaustive. The Go port of this file
//! is where the typing axis will show, exactly as it did for `JsonValue`
//! (`docs/abstractions.md` entry 9).
//!
//! Recursion goes through [`Box`] because a Rust `enum` is unboxed and a
//! directly recursive variant would have no finite size. That is the one
//! difference from OCaml, where every constructor argument is already a
//! pointer.

/// A Nix expression.
#[derive(Debug, Clone, PartialEq)]
pub enum Expr {
    /// An integer literal.
    Int(i64),
    /// A float literal.
    Float(f64),
    /// A double-quoted string, possibly interpolated.
    Str(Vec<Part>),
    /// An indented `''...''` string.
    IndStr(Vec<Part>),
    /// A path literal.
    Path(String),
    /// A path containing an interpolation, `./x/${v}.nix`.
    ///
    /// NOT a string: Nix models it as a concatenation whose first element is a
    /// path, and prints it as `(/abs/x/ + v + ".nix")`. The parts use the same
    /// `Lit`/`Anti` shape as a string's, with the leading path carried as an
    /// `Anti(Path(..))` so it prints bare.
    PathInterp(Vec<Part>),
    /// `<nixpkgs>`
    SearchPath(String),
    /// `scheme:path`. Note that `x:x` lexes as THIS and not as a lambda.
    Uri(String),
    /// A variable reference.
    Var(String),
    /// `pattern: body`
    Lambda(Pattern, Box<Expr>),
    /// `f a`
    Apply(Box<Expr>, Box<Expr>),
    /// `e.a.b` with an optional `or e'`.
    Select(Box<Expr>, AttrPath, Option<Box<Expr>>),
    /// `e ? a.b`
    HasAttr(Box<Expr>, AttrPath),
    /// `[ a b ]`
    List(Vec<Expr>),
    /// `{ a = b; }`, or `rec { ... }`.
    AttrSet {
        /// Whether the bindings can see each other.
        recursive: bool,
        /// The bindings, in source order.
        binds: Vec<Binding>,
    },
    /// `let a = b; in e`
    Let(Vec<Binding>, Box<Expr>),
    /// `with e; body`
    With(Box<Expr>, Box<Expr>),
    /// `assert c; body`
    Assert(Box<Expr>, Box<Expr>),
    /// `if c then t else f`
    If(Box<Expr>, Box<Expr>, Box<Expr>),
    /// A binary operator application.
    Op(Op, Box<Expr>, Box<Expr>),
    /// `!e`
    Not(Box<Expr>),
    /// Unary minus, which a differential printer desugars to `__sub 0 e`.
    Neg(Box<Expr>),
}

/// A piece of a string literal.
#[derive(Debug, Clone, PartialEq)]
pub enum Part {
    /// A literal run of characters.
    Lit(String),
    /// An antiquotation, `${e}`.
    Anti(Expr),
}

/// One component of an attribute path.
#[derive(Debug, Clone, PartialEq)]
pub enum Attr {
    /// An identifier, `a`.
    Id(String),
    /// A string literal, `."a"`.
    Str(Vec<Part>),
    /// An expression naming the attribute DIRECTLY, `.${e}`.
    ///
    /// Distinct from `Str` holding one antiquotation, which is `."${e}"`,
    /// because Nix keeps them apart and prints them differently: `a.${k}`
    /// prints as `(a)."${k}"` while `{ "${k}" = 1; }` prints as
    /// `{ "${(k)}" = 1; }`. The parentheses are the string wrapper showing
    /// through.
    Dyn(Expr),
}

/// `a.b.c`
pub type AttrPath = Vec<Attr>;

/// One binding inside `{ ... }` or `let ... in`.
#[derive(Debug, Clone, PartialEq)]
pub enum Binding {
    /// `a.b = e;`
    Bind(AttrPath, Expr),
    /// `inherit (from) a b;`
    Inherit(Option<Expr>, Vec<Attr>),
}

/// A lambda's parameter.
#[derive(Debug, Clone, PartialEq)]
pub enum Pattern {
    /// `x: ...`
    Var(String),
    /// `{ a, b ? d, ... } @ alias: ...`
    Set {
        /// Each formal, with an optional default.
        formals: Vec<(String, Option<Expr>)>,
        /// Whether `...` was written.
        ellipsis: bool,
        /// The `@ name` alias, if any.
        alias: Option<String>,
    },
}

/// A binary operator.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Op {
    /// `+`
    Add,
    /// `-`
    Sub,
    /// `*`
    Mul,
    /// `/`
    Div,
    /// `//`
    Update,
    /// `++`
    Concat,
    /// `==`
    Eq,
    /// `!=`
    Neq,
    /// `<`
    Lt,
    /// `>`
    Gt,
    /// `<=`
    Le,
    /// `>=`
    Ge,
    /// `&&`
    And,
    /// `||`
    Or,
    /// `->`
    Impl,
}

impl Op {
    /// The operator's spelling in Nix source.
    pub fn text(self) -> &'static str {
        match self {
            Op::Add => "+",
            Op::Sub => "-",
            Op::Mul => "*",
            Op::Div => "/",
            Op::Update => "//",
            Op::Concat => "++",
            Op::Eq => "==",
            Op::Neq => "!=",
            Op::Lt => "<",
            Op::Gt => ">",
            Op::Le => "<=",
            Op::Ge => ">=",
            Op::And => "&&",
            Op::Or => "||",
            Op::Impl => "->",
        }
    }
}
