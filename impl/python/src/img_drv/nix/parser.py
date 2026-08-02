"""The Nix grammar, for PLY's ``yacc``.

Transcribed from ``NixOS/nix`` ``src/libexpr/parser.y`` at commit ``a86a3638``.
The precedence block below is the same twelve levels in the same order as
``parser.y:208-219``, which is the part most worth copying exactly: two of the
levels surprise everyone, and getting either wrong changes what real files MEAN
rather than failing to parse them.

- ``!`` sits BELOW ``+``, so ``!a + b`` is ``!(a + b)``;
- ``//`` sits ABOVE the comparisons, so ``a // b == c`` is ``(a // b) == c``.

Both are checked against ``nix-instantiate --parse``.
"""

from __future__ import annotations

from typing import Any

from ply import yacc  # type: ignore[import-untyped]

from . import ast
from .lexer import NixLexer, tokens  # noqa: F401  (yacc reads `tokens`)

__all__ = ["parse", "parse_and_print"]

precedence = (
    ("right", "IMPL"),
    ("left", "OR"),
    ("left", "AND"),
    ("nonassoc", "EQ", "NEQ"),
    ("nonassoc", "LT", "GT", "LEQ", "GEQ"),
    ("right", "UPDATE"),
    ("left", "NOT"),
    ("left", "PLUS", "MINUS"),
    ("left", "TIMES", "SLASH"),
    ("right", "CONCAT"),
    ("nonassoc", "QUESTION"),
    ("nonassoc", "NEGATE"),
)

start = "main"


def drop_empty(parts: list[ast.Part]) -> tuple[ast.Part, ...]:
    """Drop empty literals, which would otherwise print as ``"" + ...``.

    Note what this does NOT do: merge adjacent literals. Nix does not merge
    them either. Its lexer matches a MAXIMAL run so the pieces arrive already
    joined, and the pieces it keeps separate stay separate in the printed tree.
    """
    kept = [p for p in parts if not (isinstance(p, ast.Lit) and p.text == "")]
    return tuple(kept) if kept else (ast.Lit(""),)


def strip_indentation(
    parts: list[tuple[ast.Part, bool]],
) -> tuple[ast.Part, ...]:
    """Remove the common indentation from an indented string.

    Transcribed from ``stripIndentation`` in ``NixOS/nix`` ``parser.y``. Two
    passes: the first finds the minimum indentation over lines that have
    content, where a line of only spaces does not count and an interpolation
    counts as content; the second removes that many leading spaces per line and
    drops a final line that is nothing but spaces.

    The boolean is Nix's ``StringToken.hasIndentation``. A chunk produced by an
    escape is NOT scanned, it only ends the current run of start-of-line
    whitespace. That matters because an escaped newline is a real newline
    character: scanning it would make the following text look like an
    unindented line and switch the dedent off for the whole string.
    """
    min_indent = None
    at_start, cur = True, 0
    for part, indented in parts:
        if not (indented and isinstance(part, ast.Lit)):
            if at_start:
                at_start = False
                min_indent = cur if min_indent is None else min(min_indent, cur)
            continue
        for c in part.text:
            if at_start:
                if c == " ":
                    cur += 1
                elif c == "\n":
                    cur = 0
                else:
                    at_start = False
                    min_indent = (
                        cur if min_indent is None else min(min_indent, cur)
                    )
            elif c == "\n":
                at_start, cur = True, 0
    indent = 0 if min_indent is None else min_indent

    out: list[ast.Part] = []
    at_start, dropped = True, 0
    last = len(parts) - 1
    for i, (part, indented) in enumerate(parts):
        if not indented:
            at_start, dropped = False, 0
            out.append(part)
            continue
        if not isinstance(part, ast.Lit):
            out.append(part)
            continue
        buf: list[str] = []
        for c in part.text:
            if at_start:
                if c == " ":
                    if dropped >= indent:
                        buf.append(c)
                    dropped += 1
                elif c == "\n":
                    dropped = 0
                    buf.append(c)
                else:
                    at_start, dropped = False, 0
                    buf.append(c)
            else:
                buf.append(c)
                if c == "\n":
                    at_start, dropped = True, 0
        text = "".join(buf)
        # The closing delimiter usually sits on its own indented line, and that
        # trailing run of spaces is not part of the value.
        if i == last:
            nl = text.rfind("\n")
            if nl != -1 and text[nl + 1 :].strip(" ") == "":
                text = text[: nl + 1]
        out.append(ast.Lit(text))
    return drop_empty(out)


def p_main(p: Any) -> None:
    "main : expr"
    p[0] = p[1]


def p_expr(p: Any) -> None:
    "expr : expr_function"
    p[0] = p[1]


def p_fn_var(p: Any) -> None:
    "expr_function : ID COLON expr_function"
    p[0] = ast.Lambda(ast.Pvar(p[1]), p[3])


def p_fn_set(p: Any) -> None:
    "expr_function : formal_set COLON expr_function"
    p[0] = ast.Lambda(p[1], p[3])


def p_fn_set_alias(p: Any) -> None:
    "expr_function : formal_set AT ID COLON expr_function"
    p[0] = ast.Lambda(_alias(p[1], p[3]), p[5])


def p_fn_alias_set(p: Any) -> None:
    "expr_function : ID AT formal_set COLON expr_function"
    p[0] = ast.Lambda(_alias(p[3], p[1]), p[5])


def p_fn_empty(p: Any) -> None:
    "expr_function : empty_braces COLON expr_function"
    p[0] = ast.Lambda(ast.Pset(()), p[3])


def p_fn_empty_alias(p: Any) -> None:
    "expr_function : empty_braces AT ID COLON expr_function"
    p[0] = ast.Lambda(ast.Pset((), False, p[3]), p[5])


def p_fn_alias_empty(p: Any) -> None:
    "expr_function : ID AT empty_braces COLON expr_function"
    p[0] = ast.Lambda(ast.Pset((), False, p[1]), p[5])


def p_fn_assert(p: Any) -> None:
    "expr_function : ASSERT expr SEMI expr_function"
    p[0] = ast.Assert(p[2], p[4])


def p_fn_with(p: Any) -> None:
    "expr_function : WITH expr SEMI expr_function"
    p[0] = ast.With(p[2], p[4])


def p_fn_let(p: Any) -> None:
    "expr_function : LET binds IN expr_function"
    p[0] = ast.Let(p[2], p[4])


def p_fn_if(p: Any) -> None:
    "expr_function : expr_if"
    p[0] = p[1]


def p_if(p: Any) -> None:
    "expr_if : IF expr THEN expr ELSE expr"
    p[0] = ast.If(p[2], p[4], p[6])


def p_if_op(p: Any) -> None:
    "expr_if : expr_op"
    p[0] = p[1]


def p_op_not(p: Any) -> None:
    "expr_op : NOT expr_op"
    p[0] = ast.Not(p[2])


def p_op_neg(p: Any) -> None:
    "expr_op : MINUS expr_op %prec NEGATE"
    p[0] = ast.Neg(p[2])


_BINOPS = {
    "==": ast.Operator.EQ,
    "!=": ast.Operator.NEQ,
    "<": ast.Operator.LT,
    ">": ast.Operator.GT,
    "<=": ast.Operator.LE,
    ">=": ast.Operator.GE,
    "&&": ast.Operator.AND,
    "||": ast.Operator.OR,
    "->": ast.Operator.IMPL,
    "//": ast.Operator.UPDATE,
    "++": ast.Operator.CONCAT,
    "+": ast.Operator.ADD,
    "-": ast.Operator.SUB,
    "*": ast.Operator.MUL,
    "/": ast.Operator.DIV,
}


def p_op_binary(p: Any) -> None:
    """expr_op : expr_op EQ expr_op
    | expr_op NEQ expr_op
    | expr_op LT expr_op
    | expr_op GT expr_op
    | expr_op LEQ expr_op
    | expr_op GEQ expr_op
    | expr_op AND expr_op
    | expr_op OR expr_op
    | expr_op IMPL expr_op
    | expr_op UPDATE expr_op
    | expr_op CONCAT expr_op
    | expr_op PLUS expr_op
    | expr_op MINUS expr_op
    | expr_op TIMES expr_op
    | expr_op SLASH expr_op"""
    p[0] = ast.Op(_BINOPS[p[2]], p[1], p[3])


def p_op_has_attr(p: Any) -> None:
    "expr_op : expr_op QUESTION attrpath"
    p[0] = ast.HasAttr(p[1], p[3])


def p_op_app(p: Any) -> None:
    "expr_op : expr_app"
    p[0] = p[1]


def p_app(p: Any) -> None:
    "expr_app : expr_app expr_select"
    p[0] = ast.Apply(p[1], p[2])


def p_app_select(p: Any) -> None:
    "expr_app : expr_select"
    p[0] = p[1]


def p_select(p: Any) -> None:
    "expr_select : expr_simple DOT attrpath"
    p[0] = ast.Select(p[1], p[3])


def p_select_or(p: Any) -> None:
    "expr_select : expr_simple DOT attrpath OR_KW expr_select"
    p[0] = ast.Select(p[1], p[3], p[5])


def p_select_simple(p: Any) -> None:
    "expr_select : expr_simple"
    p[0] = p[1]


def p_simple_id(p: Any) -> None:
    "expr_simple : ID"
    p[0] = ast.Var(p[1])


def p_simple_int(p: Any) -> None:
    "expr_simple : INT"
    p[0] = ast.Int(p[1])


def p_simple_float(p: Any) -> None:
    "expr_simple : FLOAT"
    p[0] = ast.Float(p[1])


def p_simple_path(p: Any) -> None:
    "expr_simple : PATH"
    p[0] = ast.Path(ast.resolve_path(p[1]))


def p_simple_path_interp(p: Any) -> None:
    "expr_simple : PATH_START expr RCURLY path_parts"
    # The lexer hands over the prefix having ALREADY consumed the opening `${`,
    # so the first interpolation is spelled out here rather than coming from
    # `path_parts`.
    head: tuple[ast.Part, ...] = (
        ast.Anti(ast.Path(ast.resolve_path_prefix(p[1]))),
        ast.Anti(p[2]),
    )
    p[0] = ast.PathInterp(head + p[4])


def p_simple_spath(p: Any) -> None:
    "expr_simple : SPATH"
    p[0] = ast.SearchPath(p[1])


def p_simple_uri(p: Any) -> None:
    "expr_simple : URI"
    p[0] = ast.Uri(p[1])


def p_simple_string(p: Any) -> None:
    "expr_simple : DQUOTE string_parts DQUOTE"
    p[0] = ast.Str(drop_empty([part for part, _ in p[2]]))


def p_simple_ind_string(p: Any) -> None:
    "expr_simple : IND_OPEN string_parts IND_CLOSE"
    # After dedenting, an indented string with a single literal part IS a plain
    # string: Nix does not wrap a one-element concatenation.
    parts = strip_indentation(p[2])
    if len(parts) == 1 and isinstance(parts[0], ast.Lit):
        p[0] = ast.Str(parts)
    else:
        p[0] = ast.IndStr(parts)


def p_simple_paren(p: Any) -> None:
    "expr_simple : LPAREN expr RPAREN"
    p[0] = p[2]


def p_simple_rec(p: Any) -> None:
    "expr_simple : REC LCURLY binds RCURLY"
    p[0] = ast.AttrSet(p[3], recursive=True)


def p_simple_set(p: Any) -> None:
    "expr_simple : LCURLY binds1 RCURLY"
    p[0] = ast.AttrSet(p[2])


def p_simple_empty_set(p: Any) -> None:
    "expr_simple : empty_braces"
    p[0] = ast.AttrSet(())


def p_simple_list(p: Any) -> None:
    "expr_simple : LBRACK list_items RBRACK"
    p[0] = ast.List(p[2])


def p_path_parts_end(p: Any) -> None:
    "path_parts : PATH_END"
    p[0] = ()


def p_path_parts_str(p: Any) -> None:
    "path_parts : PATH_STR path_parts"
    p[0] = (ast.Lit(p[1]), *p[2])


def p_path_parts_anti(p: Any) -> None:
    "path_parts : DOLLAR_CURLY expr RCURLY path_parts"
    p[0] = (ast.Anti(p[2]), *p[4])


def p_string_parts_empty(p: Any) -> None:
    "string_parts :"
    p[0] = []


def p_string_parts_str(p: Any) -> None:
    "string_parts : STR string_parts"
    p[0] = [(ast.Lit(p[1]), True), *p[2]]


def p_string_parts_estr(p: Any) -> None:
    "string_parts : ESTR string_parts"
    p[0] = [(ast.Lit(p[1]), False), *p[2]]


def p_string_parts_anti(p: Any) -> None:
    "string_parts : DOLLAR_CURLY expr RCURLY string_parts"
    p[0] = [(ast.Anti(p[2]), False), *p[4]]


def p_list_items_empty(p: Any) -> None:
    "list_items :"
    p[0] = ()


def p_list_items(p: Any) -> None:
    "list_items : expr_select list_items"
    p[0] = (p[1], *p[2])


def p_empty_braces(p: Any) -> None:
    "empty_braces : LCURLY RCURLY"
    # `{}` is the ONE genuinely ambiguous prefix: an empty attribute set in
    # expression position and an empty formal set before a `:`. Factoring it
    # into its own nonterminal defers the decision to the token AFTER the brace,
    # which is what makes the grammar LR(1). Nix's parser.y has the same shape.
    p[0] = None


def p_binds_empty(p: Any) -> None:
    "binds :"
    p[0] = ()


def p_binds(p: Any) -> None:
    "binds : binds1"
    p[0] = p[1]


def p_binds1_bind(p: Any) -> None:
    "binds1 : attrpath ASSIGN expr SEMI binds"
    p[0] = (ast.Bind(p[1], p[3]), *p[5])


def p_binds1_inherit(p: Any) -> None:
    "binds1 : INHERIT inherit_attrs SEMI binds"
    p[0] = (ast.Inherit(None, p[2]), *p[4])


def p_binds1_inherit_from(p: Any) -> None:
    "binds1 : INHERIT LPAREN expr RPAREN inherit_attrs SEMI binds"
    p[0] = (ast.Inherit(p[3], p[5]), *p[7])


def p_inherit_attrs_empty(p: Any) -> None:
    "inherit_attrs :"
    p[0] = ()


def p_inherit_attrs(p: Any) -> None:
    "inherit_attrs : attr inherit_attrs"
    p[0] = (p[1], *p[2])


def p_attrpath_one(p: Any) -> None:
    "attrpath : attr"
    p[0] = (p[1],)


def p_attrpath(p: Any) -> None:
    "attrpath : attr DOT attrpath"
    p[0] = (p[1], *p[3])


def p_attr_id(p: Any) -> None:
    "attr : ID"
    p[0] = ast.Id(p[1])


def p_attr_or(p: Any) -> None:
    "attr : OR_KW"
    p[0] = ast.Id("or")


def p_attr_string(p: Any) -> None:
    "attr : DQUOTE string_parts DQUOTE"
    p[0] = ast.StrAttr(drop_empty([part for part, _ in p[2]]))


def p_attr_dynamic(p: Any) -> None:
    "attr : DOLLAR_CURLY expr RCURLY"
    p[0] = ast.DynAttr(p[2])


def p_formal_set_ellipsis(p: Any) -> None:
    "formal_set : LCURLY ELLIPSIS RCURLY"
    p[0] = ast.Pset((), True)


def p_formal_set(p: Any) -> None:
    "formal_set : LCURLY formals RCURLY"
    p[0] = ast.Pset(p[2])


def p_formal_set_trailing(p: Any) -> None:
    "formal_set : LCURLY formals COMMA RCURLY"
    p[0] = ast.Pset(p[2])


def p_formal_set_trailing_ellipsis(p: Any) -> None:
    "formal_set : LCURLY formals COMMA ELLIPSIS RCURLY"
    p[0] = ast.Pset(p[2], True)


def p_formals_one(p: Any) -> None:
    "formals : formal"
    p[0] = (p[1],)


def p_formals(p: Any) -> None:
    "formals : formals COMMA formal"
    # LEFT recursive, as parser.y:578-583 is. The right-recursive form creates
    # a shift/reduce conflict on `,`: after `{ a` with `,` ahead, a trailing
    # comma and another formal are not yet distinguishable.
    p[0] = (*p[1], p[3])


def p_formal(p: Any) -> None:
    "formal : ID"
    p[0] = (p[1], None)


def p_formal_default(p: Any) -> None:
    "formal : ID QUESTION expr"
    p[0] = (p[1], p[3])


def p_error(p: Any) -> None:
    if p is None:
        raise SyntaxError("unexpected end of input")
    raise SyntaxError(f"{p.lineno}: syntax error at {p.value!r}")


def _alias(pattern: ast.Pattern, name: str) -> ast.Pattern:
    # `formal_set` only ever produces a Pset, so this is a grammar invariant
    # rather than a check on input.
    assert isinstance(pattern, ast.Pset)  # noqa: S101
    return ast.Pset(pattern.formals, pattern.ellipsis, name)


#: Built once. `write_tables=False` keeps the generated table out of the source
#: tree, which matters because the checks run against a read-only mount.
_PARSER = yacc.yacc(debug=False, write_tables=False)


def parse(source: str, base: str = "", home: str = "") -> ast.Expr:
    """Parse Nix source into an AST.

    ``base`` and ``home`` are what relative and tilde paths resolve against,
    because Nix performs that resolution at PARSE time.
    """
    ast.set_context(base, home)
    result: ast.Expr = _PARSER.parse(source, lexer=NixLexer())
    return result


def parse_and_print(source: str, base: str = "", home: str = "") -> str:
    """Parse, then print in ``nix-instantiate --parse`` form."""
    # Imported here rather than at module level so `printer` and `parser` can
    # refer to each other without a cycle.
    from .printer import to_parse_form  # noqa: PLC0415

    return to_parse_form(parse(source, base, home))
