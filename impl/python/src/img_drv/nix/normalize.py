"""What :mod:`img_drv.nix.emit` forgets, named precisely.

``emit`` and ``parse`` are the two arrows between EXPR and source text. Their
law is a RETRACTION, ``parse(emit(e)) == e``, but it does not hold on the nose,
and the three things it holds only up to are worth naming rather than hiding,
because each one says something about Nix.

Literal CHUNKING carries no meaning
-----------------------------------

Nix's lexer splits a string into chunks at boundaries that depend on which
ESCAPES were used, not on the value: an escaped dollar between two words gives
three parts, and the same characters written plainly give one.
``nix-instantiate --parse`` shows that difference, printing
``("a" + "$" + "b")`` for the first and ``"a$b"`` for the second, and Nix
EVALUATES both identically.

So the debug form our differential oracle compares against is FINER than
semantic equality. That is what we want for testing a parser, since it pins
more; it means the round-trip law has to be stated in the quotient, because
``emit`` writes the characters and cannot write the chunking.

An indented string stops existing at parse time
------------------------------------------------

Nix has no indented-string node: ``''a''`` is an ``ExprString`` once the dedent
has run, and the indentation is gone for good. :class:`~img_drv.nix.ast.IndStr`
is our invention and holds nothing that could write the original back.

A URI literal is a string
--------------------------

``x:x`` is a URI to the LEXER, which is why it is not a lambda, and ``--parse``
prints it as ``"x:x"``. Nix keeps no URI node either.

All three quotients are semantic no-ops, and each names a node WE invented that
Nix does not keep. Normalising by them is the honest statement of the law, not a
way of making a failing test pass; that all three are our own inventions is
itself the finding.
"""

from __future__ import annotations

from . import ast

__all__ = ["expr"]


def _parts(parts: tuple[ast.Part, ...]) -> tuple[ast.Part, ...]:
    out: list[ast.Part] = []
    for p in parts:
        if isinstance(p, ast.Anti):
            out.append(ast.Anti(expr(p.expr)))
            continue
        if out and isinstance(out[-1], ast.Lit):
            out[-1] = ast.Lit(out[-1].text + p.text)
        else:
            out.append(p)
    return tuple(out)


def _attr(a: ast.Attr) -> ast.Attr:
    if isinstance(a, ast.Id):
        return a
    if isinstance(a, ast.StrAttr):
        return ast.StrAttr(_parts(a.parts))
    return ast.DynAttr(expr(a.expr))


def _path(path: ast.AttrPath) -> ast.AttrPath:
    return tuple(_attr(a) for a in path)


def _binding(b: ast.Binding) -> ast.Binding:
    if isinstance(b, ast.Bind):
        return ast.Bind(_path(b.path), expr(b.value))
    source = None if b.source is None else expr(b.source)
    return ast.Inherit(source, _path(b.attrs))


def _pattern(p: ast.Pattern) -> ast.Pattern:
    if isinstance(p, ast.Pvar):
        return p
    formals = tuple(
        (name, None if d is None else expr(d)) for name, d in p.formals
    )
    return ast.Pset(formals, p.ellipsis, p.alias)


def expr(e: ast.Expr) -> ast.Expr:
    """The normal form: literals joined, indented strings and URIs folded."""
    match e:
        case ast.Str():
            return ast.Str(_parts(e.parts))
        # Nix keeps no indented-string node past parsing, so neither does the
        # normal form.
        case ast.IndStr():
            return ast.Str(_parts(e.parts))
        case ast.PathInterp():
            return ast.PathInterp(_parts(e.parts))
        # Nix keeps no URI node either: `x:x` parses to a string.
        case ast.Uri():
            return ast.Str((ast.Lit(e.text),))
        case (
            ast.Int() | ast.Float() | ast.Path() | ast.SearchPath() | ast.Var()
        ):
            return e
        case ast.Lambda():
            return ast.Lambda(_pattern(e.pattern), expr(e.body))
        case ast.Apply():
            return ast.Apply(expr(e.func), expr(e.arg))
        case ast.Select():
            default = None if e.default is None else expr(e.default)
            return ast.Select(expr(e.expr), _path(e.path), default)
        case ast.HasAttr():
            return ast.HasAttr(expr(e.expr), _path(e.path))
        case ast.List():
            return ast.List(tuple(expr(i) for i in e.items))
        case ast.AttrSet():
            binds = tuple(_binding(b) for b in e.binds)
            return ast.AttrSet(binds, e.recursive)
        case ast.Let():
            return ast.Let(tuple(_binding(b) for b in e.binds), expr(e.body))
        case ast.With():
            return ast.With(expr(e.scope), expr(e.body))
        case ast.Assert():
            return ast.Assert(expr(e.condition), expr(e.body))
        case ast.If():
            return ast.If(expr(e.condition), expr(e.then), expr(e.otherwise))
        case ast.Op():
            return ast.Op(e.op, expr(e.left), expr(e.right))
        case ast.Not():
            return ast.Not(expr(e.expr))
        case ast.Neg():
            return ast.Neg(expr(e.expr))
