"""Print an AST the way ``nix-instantiate --parse`` does.

This exists to be DIFFERENTIALLY TESTED. Nix re-prints the tree it parsed,
fully parenthesised and partly desugared, so matching its output byte for byte
over real files proves our tree has the same SHAPE as Nix's, which is far
stronger than "it parsed".

Not to be confused with :mod:`img_drv.nix.emit`, which writes `.nix` source a
human reads and Nix evaluates. This one writes Nix's debug form.

The desugarings are Nix's, not ours:

- ``a * b`` prints as ``(__mul a b)``, ``a / b`` as ``(__div a b)``;
- ``a - b`` prints as ``(__sub a b)``, but ``a + b`` keeps its ``+``;
- unary minus prints as ``(__sub 0 a)``;
- an interpolated string prints as a ``+`` chain;
- a constant dynamic attribute ``${"c"}`` folds to a plain ``c``.

Everything about ORDER and QUOTING below was established by probing the pinned
Nix, never from memory; ``docs/abstractions.md`` entry 13 lists the eight rules
and how each was found.
"""

from __future__ import annotations

from dataclasses import dataclass

from . import ast

__all__ = ["to_parse_form"]

_KEYWORDS = frozenset(
    {"if", "then", "else", "assert", "with", "let", "in", "rec", "inherit"}
)

_IDENT_FIRST = frozenset(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_"
)
_IDENT_REST = _IDENT_FIRST | frozenset("0123456789'-")

_BUILTIN_OF = {
    ast.Operator.SUB: "__sub",
    ast.Operator.MUL: "__mul",
    ast.Operator.DIV: "__div",
}

#: The comparisons all reduce to ``__lessThan``, three with a swap or negation.
_COMPARISON_OF = {
    ast.Operator.LT: (False, False),
    ast.Operator.GT: (False, True),
    ast.Operator.GE: (True, False),
    ast.Operator.LE: (True, True),
}

_SYMBOL_OF = {
    ast.Operator.ADD: "+",
    ast.Operator.UPDATE: "//",
    ast.Operator.CONCAT: "++",
    ast.Operator.EQ: "==",
    ast.Operator.NEQ: "!=",
    ast.Operator.AND: "&&",
    ast.Operator.OR: "||",
    ast.Operator.IMPL: "->",
}


def _escape(text: str) -> str:
    """Escape a string literal the way Nix prints one.

    Five ordinary escapes plus a sixth that only fires in context: a ``$`` is
    escaped ONLY when it begins an interpolation, so ``"a$b"`` prints unescaped
    and a literal ``${`` prints as ``\\${``. Escaping every dollar would be
    valid Nix and would not be what ``--parse`` emits.
    """
    out: list[str] = []
    for i, c in enumerate(text):
        if c == '"':
            out.append('\\"')
        elif c == "\\":
            out.append("\\\\")
        elif c == "\n":
            out.append("\\n")
        elif c == "\r":
            out.append("\\r")
        elif c == "\t":
            out.append("\\t")
        elif c == "$" and i + 1 < len(text) and text[i + 1] == "{":
            out.append("\\$")
        else:
            out.append(c)
    return "".join(out)


def _is_identifier(s: str) -> bool:
    return bool(s) and s[0] in _IDENT_FIRST and all(c in _IDENT_REST for c in s)


def _name(s: str) -> str:
    """An attribute name: bare when it is an identifier, quoted otherwise.

    A keyword is quoted even though it looks like an identifier, because a bare
    one would not parse back. ``or`` is the exception: Nix's grammar admits it
    as an attribute name and prints it bare.
    """
    if _is_identifier(s) and s not in _KEYWORDS:
        return s
    return '"' + _escape(s) + '"'


@dataclass(frozen=True, slots=True)
class _Attr:
    """One entry of a bind tree.

    ``dynamic`` matters because Nix keeps static and dynamic attributes in two
    different containers, a sorted map and a source-order vector, and prints
    the map first.
    """

    key: str
    dynamic: bool
    value: ast.Expr | None = None
    nested: tuple[_Item, ...] = ()


@dataclass(frozen=True, slots=True)
class _InheritItem:
    source: ast.Expr | None
    attrs: tuple[ast.Attr, ...]


_Item = _Attr | _InheritItem


def _key_of(a: ast.Attr) -> str:
    """The RAW name, because Nix merges and sorts by SYMBOL.

    Sorting by the printed form puts every quoted name before every bare one,
    since a quote sorts below a letter. Quoting is applied at print time.
    """
    if isinstance(a, ast.Id):
        return a.name
    if (
        isinstance(a, ast.StrAttr)
        and len(a.parts) == 1
        and isinstance(a.parts[0], ast.Lit)
    ):
        return a.parts[0].text
    if (
        isinstance(a, ast.DynAttr)
        and isinstance(a.expr, ast.Str)
        and len(a.expr.parts) == 1
        and isinstance(a.expr.parts[0], ast.Lit)
    ):
        return a.expr.parts[0].text
    return _attr(a)


def _is_dynamic(a: ast.Attr) -> bool:
    if isinstance(a, ast.Id):
        return False
    if isinstance(a, ast.StrAttr):
        return any(isinstance(p, ast.Anti) for p in a.parts)
    if isinstance(a.expr, ast.Str):
        parts = a.expr.parts
        return not (len(parts) == 1 and isinstance(parts[0], ast.Lit))
    return True


def _set_binds(e: ast.Expr | None) -> tuple[ast.Binding, ...] | None:
    """The bindings of an attribute-set value, for the merge cases.

    The recursive flag is accepted and dropped, which is what Nix does:
    ``{ a = { b = 1; }; a = rec { c = 2; }; }`` prints as one NON-recursive set.
    """
    return e.binds if isinstance(e, ast.AttrSet) else None


def _add_binds(
    items: tuple[_Item, ...], binds: tuple[ast.Binding, ...]
) -> tuple[_Item, ...]:
    for b in binds:
        if isinstance(b, ast.Bind):
            items = _insert(items, b.path, b.value)
        else:
            items = (*items, _InheritItem(b.source, b.attrs))
    return items


def _group_binds(binds: tuple[ast.Binding, ...]) -> tuple[_Item, ...]:
    """Expand dotted bindings into nested sets and merge shared prefixes.

    ``{ a.b.c = 1; }`` becomes ``{ a = { b = { c = 1; }; }; }`` and
    ``{ a.b = 1; a.c = 2; }`` becomes ``{ a = { b = 1; c = 2; }; }``, because
    Nix does that at parse time.
    """
    return _add_binds((), binds)


def _insert(
    items: tuple[_Item, ...], path: ast.AttrPath, value: ast.Expr
) -> tuple[_Item, ...]:
    if not path:
        return items
    key, dyn = _key_of(path[0]), _is_dynamic(path[0])
    if len(path) == 1:
        # A leaf whose value is a set MERGES into an entry the dotted bindings
        # already opened, and TWO set-valued bindings with the same name merge
        # too. Nix rejects a duplicate scalar and quietly joins duplicate sets,
        # which real modules rely on.
        out: list[_Item] = []
        merged = False
        for it in items:
            joined = it
            if not merged and isinstance(it, _Attr) and it.key == key:
                new_binds = _set_binds(value)
                old = _set_binds(it.value)
                if it.nested and new_binds is not None:
                    joined = _Attr(
                        it.key,
                        it.dynamic,
                        None,
                        _add_binds(it.nested, new_binds),
                    )
                    merged = True
                elif old is not None and new_binds is not None:
                    joined = _Attr(
                        it.key,
                        it.dynamic,
                        None,
                        _add_binds(_group_binds(old), new_binds),
                    )
                    merged = True
            out.append(joined)
        if not merged:
            out.append(_Attr(key, dyn, value))
        return tuple(out)

    rest = path[1:]
    out2: list[_Item] = []
    merged = False
    for it in items:
        joined = it
        if not merged and isinstance(it, _Attr) and it.key == key:
            if it.nested:
                joined = _Attr(
                    it.key, it.dynamic, None, _insert(it.nested, rest, value)
                )
                merged = True
            else:
                # A leaf already holding a set is REOPENED rather than
                # shadowed, so a later dotted binding lands inside it.
                old = _set_binds(it.value)
                if old is not None:
                    joined = _Attr(
                        it.key,
                        it.dynamic,
                        None,
                        _insert(_group_binds(old), rest, value),
                    )
                    merged = True
        out2.append(joined)
    if not merged:
        out2.append(_Attr(key, dyn, None, _insert((), rest, value)))
    return tuple(out2)


def _order(items: tuple[_Item, ...]) -> list[_Item]:
    """Nix's print order for an attribute set or a ``let``.

    An attribute set is a SORTED map keyed by symbol, so bindings print in name
    order rather than source order. Every PLAIN inherit merges into one
    statement with its names sorted and comes FIRST; each ``inherit (e)`` group
    keeps its identity and its source position; ordinary bindings follow,
    sorted; dynamic names come last in SOURCE order, because they are a
    separate container in Nix and not part of the sorted map.
    """
    plain: list[ast.Attr] = []
    for it in items:
        if isinstance(it, _InheritItem) and it.source is None:
            plain.extend(it.attrs)
    merged: list[_Item] = []
    if plain:
        merged.append(_InheritItem(None, tuple(sorted(plain, key=_key_of))))
    from_groups = [
        _InheritItem(it.source, tuple(sorted(it.attrs, key=_key_of)))
        for it in items
        if isinstance(it, _InheritItem) and it.source is not None
    ]
    statics = sorted(
        (it for it in items if isinstance(it, _Attr) and not it.dynamic),
        key=lambda it: it.key,
    )
    dynamics = [it for it in items if isinstance(it, _Attr) and it.dynamic]
    return merged + from_groups + list(statics) + dynamics


def _items(items: tuple[_Item, ...]) -> str:
    out: list[str] = []
    for it in _order(items):
        if isinstance(it, _InheritItem):
            source = f" ({_expr(it.source)})" if it.source is not None else ""
            names = "".join(" " + _attr(a) for a in it.attrs)
            out.append(f"inherit{source}{names}; ")
        else:
            # The key held here is the RAW name, so quoting happens now: a
            # dynamic key is already printed syntax and goes out verbatim.
            name = it.key if it.dynamic else _name(it.key)
            if it.value is not None:
                out.append(f"{name} = {_expr(it.value)}; ")
            else:
                out.append(f"{name} = {{ {_items(it.nested)}}}; ")
    return "".join(out)


def _attr(a: ast.Attr) -> str:
    if isinstance(a, ast.Id):
        return _name(a.name)
    if isinstance(a, ast.StrAttr):
        if len(a.parts) == 1 and isinstance(a.parts[0], ast.Lit):
            return _name(a.parts[0].text)
        # A dynamic attribute becomes ONE interpolation wrapping the whole
        # string expression: `{ "a${m}b" = 1; }` prints as
        # `{ "${("a" + m + "b")}" = 1; }`.
        return '"${' + _parts(a.parts) + '}"'
    # `a.${"c"}`: a constant string folds to a plain name, as `a."c"` does.
    if isinstance(a.expr, ast.Str):
        parts = a.expr.parts
        if len(parts) == 1 and isinstance(parts[0], ast.Lit):
            return _name(parts[0].text)
    # `a.${k}`: the expression IS the name, so a bare variable stays bare.
    return '"${' + _expr(a.expr) + '}"'


def _attrpath(path: ast.AttrPath) -> str:
    return ".".join(_attr(a) for a in path)


def _parts(parts: tuple[ast.Part, ...]) -> str:
    if not parts:
        return '""'
    if len(parts) == 1 and isinstance(parts[0], ast.Lit):
        return '"' + _escape(parts[0].text) + '"'
    # An interpolated string is a `+` chain. No parentheses of our own: the
    # interpolated expression supplies its own.
    pieces = [
        '"' + _escape(p.text) + '"' if isinstance(p, ast.Lit) else _expr(p.expr)
        for p in parts
    ]
    return "(" + " + ".join(pieces) + ")"


def _pattern(p: ast.Pattern) -> str:
    if isinstance(p, ast.Pvar):
        return p.name
    # Formals are a sorted map too.
    formals = sorted(p.formals, key=lambda f: f[0])
    body = ", ".join(
        name if default is None else f"{name} ? {_expr(default)}"
        for name, default in formals
    )
    if p.ellipsis:
        body = "..." if not formals else body + ", ..."
    alias = f" @ {p.alias}" if p.alias is not None else ""
    return "{ " + body + " }" + alias


def _apply(e: ast.Expr) -> str:
    """Application prints FLATTENED: ``f 1 2`` is one pair of parentheses."""
    if isinstance(e, ast.Apply):
        return f"{_apply(e.func)} {_expr(e.arg)}"
    return _expr(e)


def _expr(e: ast.Expr) -> str:
    match e:
        case ast.Int():
            return str(e.value)
        case ast.Float():
            # C's `%g`, which is what Nix uses: `3.0` prints as `3`.
            return f"{e.value:g}"
        case ast.Var():
            return e.name
        case ast.Path():
            return e.text
        case ast.PathInterp():
            return _parts(e.parts)
        case ast.SearchPath():
            # `<nixpkgs>` desugars to a search-path lookup, which is why a
            # search path is impure: it reads NIX_PATH at evaluation time.
            return f'(__findFile __nixPath "{_escape(e.text)}")'
        case ast.Uri():
            return '"' + _escape(e.text) + '"'
        case ast.Str() | ast.IndStr():
            return _parts(e.parts)
        case ast.Not():
            return f"(! {_expr(e.expr)})"
        case ast.Neg():
            return f"(__sub 0 {_expr(e.expr)})"
        case ast.Op() if e.op in _COMPARISON_OF:
            negated, swapped = _COMPARISON_OF[e.op]
            left, right = (e.right, e.left) if swapped else (e.left, e.right)
            body = f"(__lessThan {_expr(left)} {_expr(right)})"
            return f"(! {body})" if negated else body
        case ast.Op() if e.op in _BUILTIN_OF:
            return f"({_BUILTIN_OF[e.op]} {_expr(e.left)} {_expr(e.right)})"
        case ast.Op():
            return f"({_expr(e.left)} {_SYMBOL_OF[e.op]} {_expr(e.right)})"
        case ast.HasAttr():
            return f"(({_expr(e.expr)}) ? {_attrpath(e.path)})"
        case ast.Apply():
            return f"({_apply(e.func)} {_expr(e.arg)})"
        case ast.Select():
            head = f"({_expr(e.expr)}).{_attrpath(e.path)}"
            if e.default is None:
                return head
            return f"{head} or ({_expr(e.default)})"
        case ast.Lambda():
            return f"({_pattern(e.pattern)}: {_expr(e.body)})"
        case ast.List():
            return "[ " + "".join(f"({_expr(i)}) " for i in e.items) + "]"
        case ast.AttrSet():
            rec = "rec " if e.recursive else ""
            return rec + "{ " + _items(_group_binds(e.binds)) + "}"
        case ast.Let():
            return f"(let {_items(_group_binds(e.binds))}in {_expr(e.body)})"
        case ast.With():
            return f"(with {_expr(e.scope)}; {_expr(e.body)})"
        case ast.Assert():
            # Nix prints assert WITHOUT wrapping parentheses.
            return f"assert {_expr(e.condition)}; {_expr(e.body)}"
        case ast.If():
            return (
                f"(if {_expr(e.condition)} then {_expr(e.then)} "
                f"else {_expr(e.otherwise)})"
            )


def to_parse_form(e: ast.Expr) -> str:
    """The AST, printed the way ``nix-instantiate --parse`` prints it."""
    return _expr(e)
