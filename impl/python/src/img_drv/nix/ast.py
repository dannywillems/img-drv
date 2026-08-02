"""The Nix language AST.

Faithful to the grammar in ``NixOS/nix`` ``src/libexpr/parser.y`` at commit
``a86a3638``, and deliberately NOT desugared: the AST records what was written.

This is the same type as ``impl/ocaml/nix/ast.ml``, and comparing the two is
the sharpest instance yet of the typing-axis measurement in
``docs/abstractions.md``. OCaml states it as one 20-constructor variant. Python
has no variants, so it is 20 frozen dataclasses plus a union alias, which mypy
checks exhaustively and the runtime does not check at all.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum
from typing import TypeAlias

__all__ = [
    "Anti",
    "Apply",
    "Assert",
    "AttrSet",
    "Bind",
    "Expr",
    "Float",
    "HasAttr",
    "Id",
    "If",
    "IndStr",
    "Inherit",
    "Int",
    "Lambda",
    "Let",
    "List",
    "Lit",
    "Neg",
    "Not",
    "Op",
    "Operator",
    "Path",
    "PathInterp",
    "Pset",
    "Pvar",
    "SearchPath",
    "Select",
    "Str",
    "StrAttr",
    "Uri",
    "Var",
    "With",
]


class Operator(Enum):
    """Binary operators, with their source spelling as the value."""

    ADD = "+"
    SUB = "-"
    MUL = "*"
    DIV = "/"
    UPDATE = "//"
    CONCAT = "++"
    EQ = "=="
    NEQ = "!="
    LT = "<"
    GT = ">"
    LE = "<="
    GE = ">="
    AND = "&&"
    OR = "||"
    IMPL = "->"


@dataclass(frozen=True, slots=True)
class Int:
    value: int


@dataclass(frozen=True, slots=True)
class Float:
    value: float


@dataclass(frozen=True, slots=True)
class Lit:
    """A literal run of characters inside a string."""

    text: str


@dataclass(frozen=True, slots=True)
class Anti:
    """An antiquotation, ``${e}``, inside a string."""

    expr: Expr


Part: TypeAlias = Lit | Anti


@dataclass(frozen=True, slots=True)
class Str:
    """A double-quoted string, possibly interpolated."""

    parts: tuple[Part, ...]


@dataclass(frozen=True, slots=True)
class IndStr:
    """An indented ``''...''`` string."""

    parts: tuple[Part, ...]


@dataclass(frozen=True, slots=True)
class Path:
    text: str


@dataclass(frozen=True, slots=True)
class PathInterp:
    """A path containing an interpolation, ``./x/${v}.nix``.

    NOT a string: Nix models it as a concatenation whose first element is a
    path, and prints it as ``(/abs/x/ + v + ".nix")``. The parts use the same
    Lit/Anti shape as a string's, with the leading path carried as an
    ``Anti(Path(...))`` so it prints bare.
    """

    parts: tuple[Part, ...]


@dataclass(frozen=True, slots=True)
class SearchPath:
    """``<nixpkgs>``"""

    text: str


@dataclass(frozen=True, slots=True)
class Uri:
    """``scheme:path``. Note ``x:x`` lexes as THIS, not as a lambda."""

    text: str


@dataclass(frozen=True, slots=True)
class Var:
    name: str


@dataclass(frozen=True, slots=True)
class Id:
    """An attribute named by an identifier, ``a``."""

    name: str


@dataclass(frozen=True, slots=True)
class StrAttr:
    """An attribute named by a STRING literal, ``."a"``."""

    parts: tuple[Part, ...]


@dataclass(frozen=True, slots=True)
class DynAttr:
    """An attribute named by an expression DIRECTLY, ``.${e}``.

    Distinct from ``StrAttr`` holding one antiquotation, which is ``."${e}"``,
    because Nix keeps them distinct and prints them differently: ``a.${k}``
    prints as ``(a)."${k}"`` while ``{ "${k}" = 1; }`` prints as
    ``{ "${(k)}" = 1; }``. The parentheses are the string wrapper showing
    through.
    """

    expr: Expr


Attr: TypeAlias = Id | StrAttr | DynAttr
AttrPath: TypeAlias = tuple[Attr, ...]


@dataclass(frozen=True, slots=True)
class Bind:
    """``a.b = e;``"""

    path: AttrPath
    value: Expr


@dataclass(frozen=True, slots=True)
class Inherit:
    """``inherit (from) a b;``"""

    source: Expr | None
    attrs: tuple[Attr, ...]


Binding: TypeAlias = Bind | Inherit


@dataclass(frozen=True, slots=True)
class Pvar:
    """``x: ...``"""

    name: str


@dataclass(frozen=True, slots=True)
class Pset:
    """``{ a, b ? d, ... } @ alias: ...``"""

    formals: tuple[tuple[str, Expr | None], ...]
    ellipsis: bool = False
    alias: str | None = None


Pattern: TypeAlias = Pvar | Pset


@dataclass(frozen=True, slots=True)
class Lambda:
    pattern: Pattern
    body: Expr


@dataclass(frozen=True, slots=True)
class Apply:
    func: Expr
    arg: Expr


@dataclass(frozen=True, slots=True)
class Select:
    """``e.a.b`` with an optional ``or e'``."""

    expr: Expr
    path: AttrPath
    default: Expr | None = None


@dataclass(frozen=True, slots=True)
class HasAttr:
    """``e ? a.b``"""

    expr: Expr
    path: AttrPath


@dataclass(frozen=True, slots=True)
class List:
    items: tuple[Expr, ...]


@dataclass(frozen=True, slots=True)
class AttrSet:
    binds: tuple[Binding, ...]
    recursive: bool = False


@dataclass(frozen=True, slots=True)
class Let:
    binds: tuple[Binding, ...]
    body: Expr


@dataclass(frozen=True, slots=True)
class With:
    scope: Expr
    body: Expr


@dataclass(frozen=True, slots=True)
class Assert:
    condition: Expr
    body: Expr


@dataclass(frozen=True, slots=True)
class If:
    condition: Expr
    then: Expr
    otherwise: Expr


@dataclass(frozen=True, slots=True)
class Op:
    op: Operator
    left: Expr
    right: Expr


@dataclass(frozen=True, slots=True)
class Not:
    expr: Expr


@dataclass(frozen=True, slots=True)
class Neg:
    """Unary minus, which a differential printer desugars to ``__sub 0 e``."""

    expr: Expr


#: Every expression form. The recursive alias is what makes this a genuine
#: sum type to mypy; at runtime it is erased entirely.
Expr: TypeAlias = (
    Int
    | Float
    | Str
    | IndStr
    | Path
    | PathInterp
    | SearchPath
    | Uri
    | Var
    | Lambda
    | Apply
    | Select
    | HasAttr
    | List
    | AttrSet
    | Let
    | With
    | Assert
    | If
    | Op
    | Not
    | Neg
)


# Path resolution, which Nix performs at PARSE time.
#
# A relative path resolves against the directory of the file it is written in,
# and a leading `~` against HOME, so `./common/x11.nix` in `nixos/tests/foo.nix`
# is an absolute path in the tree and `nix-instantiate --parse` prints it that
# way. A parser that keeps the relative text produces a different tree.
#
# Module state rather than a parameter because the parser is generated and its
# entry point takes only a lexer. Empty means "leave paths alone", which is what
# the transpiler and the unit vectors want.

base_dir = ""
home_dir = ""


def set_context(base: str = "", home: str = "") -> None:
    """Set the directories path literals resolve against."""
    global base_dir, home_dir
    base_dir, home_dir = base, home


def canonicalise(p: str) -> str:
    """Fold away ``.`` and ``..``, collapse separators, drop a trailing one."""
    stack: list[str] = []
    for part in p.split("/"):
        if part in ("", "."):
            continue
        if part == "..":
            if stack:
                stack.pop()
        else:
            stack.append(part)
    return "/" + "/".join(stack)


def resolve_path(p: str) -> str:
    """Resolve a path literal against the base or home directory."""
    if p.startswith("~"):
        return canonicalise(home_dir + p[1:]) if home_dir else p
    if not base_dir:
        return p
    if p.startswith("/"):
        return canonicalise(p)
    return canonicalise(base_dir + "/" + p)


def resolve_path_prefix(p: str) -> str:
    """Resolve the literal PREFIX of an interpolated path.

    Same as :func:`resolve_path` except a trailing separator is KEPT, because
    it is meaningful here: ``./x/${v}`` denotes ``/abs/x/`` concatenated with
    ``v``, and dropping the separator would glue the segments together.
    """
    resolved = resolve_path(p)
    return resolved + "/" if p.endswith("/") else resolved
