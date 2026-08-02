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
    """An attribute named by a string or an interpolation.

    ``."a"`` or ``.${e}``.
    """

    parts: tuple[Part, ...]


Attr: TypeAlias = Id | StrAttr
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
