"""Print an AST as valid Nix SOURCE. This is the transpiler.

The arrow ``EXPR -> .nix`` of ``docs/architecture.md``.

Fully parenthesised, on purpose. Extra parentheses cannot change a parse, so
the emitted file is correct BY CONSTRUCTION rather than correct if the
precedence table was transcribed properly. ``docs/nix-internals.md`` records two
levels that surprise everyone (``!`` binds looser than ``+``, ``//`` tighter
than the comparisons); a minimal-parenthesis printer has to get both right and
this one cannot get them wrong.

Making the output pretty is a separate, later job with its own test: emit,
re-parse, compare the ASTs.
"""

from __future__ import annotations

from . import ast

__all__ = ["to_nix"]

_ESCAPES = {
    '"': '\\"',
    "\\": "\\\\",
    "\n": "\\n",
    "\r": "\\r",
    "\t": "\\t",
    # `${` in a literal must be escaped or Nix reads an interpolation.
    "$": "\\$",
}


def _escape(text: str) -> str:
    return "".join(_ESCAPES.get(c, c) for c in text)


def _parts(parts: tuple[ast.Part, ...]) -> str:
    out = []
    for p in parts:
        if isinstance(p, ast.Lit):
            out.append(_escape(p.text))
        else:
            out.append("${" + _expr(p.expr) + "}")
    return '"' + "".join(out) + '"'


def _attr(a: ast.Attr) -> str:
    if isinstance(a, ast.Id):
        return a.name
    if len(a.parts) == 1 and isinstance(a.parts[0], ast.Lit):
        return '"' + _escape(a.parts[0].text) + '"'
    return "${" + _parts(a.parts) + "}"


def _attrpath(path: ast.AttrPath) -> str:
    return ".".join(_attr(a) for a in path)


def _bind(b: ast.Binding) -> str:
    if isinstance(b, ast.Bind):
        return f"{_attrpath(b.path)} = {_expr(b.value)}; "
    source = f" ({_expr(b.source)})" if b.source is not None else ""
    names = "".join(" " + _attr(a) for a in b.attrs)
    return f"inherit{source}{names}; "


def _pattern(p: ast.Pattern) -> str:
    if isinstance(p, ast.Pvar):
        return p.name
    formals = ", ".join(
        name if default is None else f"{name} ? {_expr(default)}"
        for name, default in p.formals
    )
    if p.ellipsis:
        formals = "..." if not p.formals else formals + ", ..."
    alias = f" @ {p.alias}" if p.alias is not None else ""
    return "{ " + formals + " }" + alias


def _expr(e: ast.Expr) -> str:
    match e:
        case ast.Int():
            return str(e.value)
        case ast.Float():
            return f"{e.value:g}"
        case ast.Var():
            return e.name
        case ast.Path():
            return e.text
        case ast.SearchPath():
            return f"<{e.text}>"
        case ast.Uri():
            return '"' + _escape(e.text) + '"'
        case ast.Str() | ast.IndStr():
            return _parts(e.parts)
        case ast.Not():
            return f"(!{_expr(e.expr)})"
        case ast.Neg():
            return f"(-{_expr(e.expr)})"
        case ast.Op():
            return f"({_expr(e.left)} {e.op.value} {_expr(e.right)})"
        case ast.HasAttr():
            return f"({_expr(e.expr)} ? {_attrpath(e.path)})"
        case ast.Apply():
            return f"({_expr(e.func)} {_expr(e.arg)})"
        case ast.Select():
            default = "" if e.default is None else f" or {_expr(e.default)}"
            return f"({_expr(e.expr)}.{_attrpath(e.path)}{default})"
        case ast.Lambda():
            return f"({_pattern(e.pattern)}: {_expr(e.body)})"
        case ast.List():
            return "[ " + "".join(_expr(i) + " " for i in e.items) + "]"
        case ast.AttrSet():
            rec = "rec " if e.recursive else ""
            return rec + "{ " + "".join(_bind(b) for b in e.binds) + "}"
        case ast.Let():
            return (
                "(let "
                + "".join(_bind(b) for b in e.binds)
                + f"in {_expr(e.body)})"
            )
        case ast.With():
            return f"(with {_expr(e.scope)}; {_expr(e.body)})"
        case ast.Assert():
            return f"(assert {_expr(e.condition)}; {_expr(e.body)})"
        case ast.If():
            return (
                f"(if {_expr(e.condition)} then {_expr(e.then)} "
                f"else {_expr(e.otherwise)})"
            )


def to_nix(e: ast.Expr) -> str:
    """The AST as Nix source."""
    return _expr(e)
