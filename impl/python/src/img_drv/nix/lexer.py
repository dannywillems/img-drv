"""The Nix lexer, built with PLY's ``lex``.

Generated rather than hand-written for the reason in
``docs/decisions/2026-08-02-nix-frontend-build-not-reuse.md``: Nix's own lexer
is Flex, its tokens overlap, and maximal munch resolves them. The sharpest case
is ``x:x``, which is a URI and NOT a lambda, because the URI rule matches more
characters than the identifier rule does.

ONE DIFFERENCE FROM FLEX THAT SHAPES THIS FILE
-----------------------------------------------

Flex and ocamllex pick the LONGEST match; PLY builds one Python regex by
alternation, and :mod:`re` picks the FIRST alternative that matches. So order
here is load-bearing where in ``lexer.mll`` it was not: ``uri`` must precede
``id``, ``path`` must precede both, and every multi-character operator must
precede its one-character prefix. PLY adds function rules in definition order
and string rules by decreasing pattern length, so the tricky ones are written
as functions to fix their order explicitly.

Interpolation needs lexer STATE, exactly as Nix's start conditions do. The
state stack is explicit rather than PLY's, because ``}`` is ambiguous without
it: it closes an attribute set in expression state and ends an antiquotation
otherwise.
"""

from __future__ import annotations

import re
from typing import Any

from ply import lex  # type: ignore[import-untyped]

__all__ = ["NixLexer", "tokens"]

reserved = {
    "if": "IF",
    "then": "THEN",
    "else": "ELSE",
    "assert": "ASSERT",
    "with": "WITH",
    "let": "LET",
    "in": "IN",
    "rec": "REC",
    "inherit": "INHERIT",
    "or": "OR_KW",
}

tokens = [
    "INT",
    "FLOAT",
    "ID",
    "STR",
    "ESTR",
    "PATH",
    "SPATH",
    "URI",
    "PATH_START",
    "PATH_STR",
    "PATH_END",
    "DQUOTE",
    "IND_OPEN",
    "IND_CLOSE",
    "DOLLAR_CURLY",
    "LCURLY",
    "RCURLY",
    "LPAREN",
    "RPAREN",
    "LBRACK",
    "RBRACK",
    "SEMI",
    "COMMA",
    "COLON",
    "AT",
    "DOT",
    "ELLIPSIS",
    "ASSIGN",
    "QUESTION",
    "EQ",
    "NEQ",
    "LEQ",
    "GEQ",
    "LT",
    "GT",
    "AND",
    "OR",
    "IMPL",
    "UPDATE",
    "CONCAT",
    "PLUS",
    "MINUS",
    "TIMES",
    "SLASH",
    "NOT",
    *reserved.values(),
]

states = (
    ("str", "exclusive"),
    ("indstr", "exclusive"),
)

_PATH_CHAR = r"[A-Za-z0-9._+\-]"
#: The literal segment that can follow an interpolation inside a path.
_PATH_TAIL = re.compile(rf"(?:{_PATH_CHAR}|/)*")

_ESCAPES = {"n": "\n", "r": "\r", "t": "\t"}


def _unescape(c: str) -> str:
    return _ESCAPES.get(c, c)


def _unescape_run(text: str) -> str:
    """Resolve the backslash escapes inside a matched run.

    Nix's string rule matches a MAXIMAL run that already contains its escapes,
    so unescaping happens on the whole token rather than one escape at a time.
    Reproducing that boundary matters: string parts are never merged, so where
    the lexer splits is exactly what the printed tree shows.
    """
    out: list[str] = []
    i = 0
    while i < len(text):
        if text[i] == "\\" and i + 1 < len(text):
            out.append(_unescape(text[i + 1]))
            i += 2
        else:
            out.append(text[i])
            i += 1
    return "".join(out)


# INITIAL state


def t_ignore_comment_line(t: Any) -> None:
    r"\#[^\n]*"


def t_ignore_comment_block(t: Any) -> None:
    r"/\*(?:.|\n)*?\*/"
    t.lexer.lineno += t.value.count("\n")


def t_newline(t: Any) -> None:
    r"\n+"
    t.lexer.lineno += len(t.value)


t_ignore = " \t\r"


def t_URI(t: Any) -> Any:
    r"[A-Za-z][A-Za-z0-9+\-.]*:[A-Za-z0-9%/?:@&=+$,_.!~*'\-]+"
    return t


def t_PATH_START(t: Any) -> Any:
    r"(?:~(?:/[A-Za-z0-9._+\-]*)+|[A-Za-z0-9._+\-]*(?:/[A-Za-z0-9._+\-]*)+)\$\{"
    # A path containing an interpolation. The prefix is looser than `path`: it
    # may end in a bare slash, as in `./${v}`.
    t.value = t.value[:-2]
    t.lexer.nix_push("path")
    t.lexer.nix_push("expr")
    return t


def t_PATH(t: Any) -> Any:
    r"~(?:/[A-Za-z0-9._+\-]+)+/?|[A-Za-z0-9._+\-]*(?:/[A-Za-z0-9._+\-]+)+/?"
    return t


def t_SPATH(t: Any) -> Any:
    r"<[A-Za-z0-9._+\-]+(?:/[A-Za-z0-9._+\-]+)*>"
    t.value = t.value[1:-1]
    return t


def t_FLOAT(t: Any) -> Any:
    r"(?:[0-9]+\.[0-9]*|\.[0-9]+)(?:[Ee][+\-]?[0-9]+)?"
    t.value = float(t.value)
    return t


def t_INT(t: Any) -> Any:
    r"[0-9]+"
    t.value = int(t.value)
    return t


def t_ID(t: Any) -> Any:
    r"[A-Za-z_][A-Za-z0-9_'\-]*"
    t.type = reserved.get(t.value, "ID")
    return t


def t_IND_OPEN(t: Any) -> Any:
    r"''[ ]*\n|''"
    # The opening delimiter swallows any spaces and ONE newline after it, which
    # is why an indented string on its own line has no leading blank line.
    t.lexer.lineno += t.value.count("\n")
    t.lexer.nix_push("indstr")
    return t


def t_DQUOTE(t: Any) -> Any:
    r"\""
    t.lexer.nix_push("str")
    return t


def t_DOLLAR_CURLY(t: Any) -> Any:
    r"\$\{"
    t.lexer.nix_push("expr")
    return t


def t_LCURLY(t: Any) -> Any:
    r"\{"
    t.lexer.nix_push("expr")
    return t


def t_RCURLY(t: Any) -> Any:
    r"\}"
    t.lexer.nix_pop()
    return t


def t_ELLIPSIS(t: Any) -> Any:
    r"\.\.\."
    return t


def t_IMPL(t: Any) -> Any:
    r"->"
    return t


def t_UPDATE(t: Any) -> Any:
    r"//"
    return t


def t_CONCAT(t: Any) -> Any:
    r"\+\+"
    return t


def t_EQ(t: Any) -> Any:
    r"=="
    return t


def t_NEQ(t: Any) -> Any:
    r"!="
    return t


def t_LEQ(t: Any) -> Any:
    r"<="
    return t


def t_GEQ(t: Any) -> Any:
    r">="
    return t


def t_AND(t: Any) -> Any:
    r"&&"
    return t


def t_OR(t: Any) -> Any:
    r"\|\|"
    return t


t_LPAREN = r"\("
t_RPAREN = r"\)"
t_LBRACK = r"\["
t_RBRACK = r"\]"
t_SEMI = r";"
t_COMMA = r","
t_COLON = r":"
t_AT = r"@"
t_DOT = r"\."
t_ASSIGN = r"="
t_QUESTION = r"\?"
t_LT = r"<"
t_GT = r">"
t_PLUS = r"\+"
t_MINUS = r"-"
t_TIMES = r"\*"
t_SLASH = r"/"
t_NOT = r"!"


def t_error(t: Any) -> None:
    raise SyntaxError(
        f"{t.lexer.lineno}:{_column(t)}: unexpected character {t.value[0]!r}"
    )


# Double-quoted string state.
#
# The chunk boundaries MATTER, because nothing merges them afterwards: what the
# lexer splits is exactly what the printed tree shows. So the runs below are
# transcribed from NixOS/nix lexer.l rather than invented.

t_str_ignore = ""


def t_str_DOLLAR_CURLY(t: Any) -> Any:
    r"\$\{"
    t.lexer.nix_push("expr")
    return t


def t_str_trailing(t: Any) -> Any:
    r"(?:[^$\"\\]|\$[^{\"\\]|\\[\s\S]|\$\\[\s\S])*\$(?=\")"
    # Nix's FIRST string rule uses flex TRAILING CONTEXT: a run ending in a
    # dollar that is followed by the closing quote. That dollar cannot be
    # absorbed by the ordinary run below, which needs a character after it, so
    # without this rule a string ending in a dollar becomes a two-part
    # concatenation. Python's lookahead expresses the trailing context directly.
    t.type = "STR"
    t.lexer.lineno += t.value.count("\n")
    t.value = _unescape_run(t.value)
    return t


def t_str_run(t: Any) -> Any:
    r"(?:[^$\"\\]|\$[^{\"\\]|\\[\s\S]|\$\\[\s\S])+"
    t.type = "STR"
    t.lexer.lineno += t.value.count("\n")
    t.value = _unescape_run(t.value)
    return t


def t_str_DQUOTE(t: Any) -> Any:
    r"\""
    t.lexer.nix_pop()
    return t


def t_str_fallback(t: Any) -> Any:
    r"\$\\|\$|\\"
    t.type = "STR"
    return t


def t_str_error(t: Any) -> None:
    raise SyntaxError(f"{t.lexer.lineno}: unterminated string")


# Indented string state.

t_indstr_ignore = ""


def t_indstr_run(t: Any) -> Any:
    r"(?:[^$']|\$[^{']|'[^'$])+"
    # One MAXIMAL run. Note what it EXCLUDES: a quote before another quote or
    # before a dollar, so the two-quote escapes below still get their chance.
    t.type = "STR"
    t.lexer.lineno += t.value.count("\n")
    return t


def t_indstr_esc_quotes(t: Any) -> Any:
    r"'''"
    t.type = "ESTR"
    t.value = "''"
    return t


def t_indstr_esc_dollar(t: Any) -> Any:
    r"''\$"
    t.type = "ESTR"
    t.value = "$"
    return t


def t_indstr_esc_backslash(t: Any) -> Any:
    r"''\\[\s\S]"
    t.type = "ESTR"
    t.value = _unescape(t.value[3])
    return t


def t_indstr_IND_CLOSE(t: Any) -> Any:
    r"''"
    t.lexer.nix_pop()
    return t


def t_indstr_DOLLAR_CURLY(t: Any) -> Any:
    r"\$\{"
    t.lexer.nix_push("expr")
    return t


def t_indstr_fallback(t: Any) -> Any:
    r"'|\$"
    # Every chunk that is not the plain run takes no part in indentation, which
    # is what Nix's StringToken.hasIndentation records. An escaped newline
    # produces a REAL newline character, so if the dedent pass scanned it the
    # text after would look like an unindented line and the whole string would
    # stop being dedented.
    t.type = "ESTR"
    return t


def t_indstr_error(t: Any) -> None:
    raise SyntaxError(f"{t.lexer.lineno}: unterminated indented string")


def _column(t: Any) -> int:
    start: int = t.lexer.lexdata.rfind("\n", 0, t.lexpos) + 1
    pos: int = t.lexpos
    return pos - start + 1


class NixLexer:
    """A stateful wrapper around PLY's lexer.

    Two things PLY does not do on its own live here.

    The STATE STACK, because ``}`` is ambiguous: it closes an attribute set in
    expression state and ends an antiquotation otherwise, so the lexer has to
    remember which.

    The PATH TAIL. After an interpolation inside a path closes, the remaining
    path characters are consumed here and a ``PATH_END`` is queued, because
    that end has to be signalled WITHOUT consuming the character that caused
    it and PLY rejects a zero-length match. A one-token queue is the smallest
    thing that expresses it.
    """

    def __init__(self) -> None:
        # Cloned rather than rebuilt: PLY compiles one master regex per lexer,
        # and the corpus check builds thousands of these.
        self._lexer = _MASTER.clone()
        self._lexer.nix_push = self._push
        self._lexer.nix_pop = self._pop
        self._queue: list[Any] = []
        self._stack: list[str] = ["expr"]

    def _begin(self, state: str) -> None:
        self._lexer.begin("INITIAL" if state in ("expr", "path") else state)

    def _push(self, state: str) -> None:
        self._stack.append(state)
        self._begin(state)

    def _pop(self) -> str:
        top = self._stack.pop() if len(self._stack) > 1 else "expr"
        self._begin(self._stack[-1])
        if self._stack[-1] == "path":
            self._scan_path_tail()
        return top

    def _scan_path_tail(self) -> None:
        """Consume the literal segment after an interpolation inside a path."""
        lexer = self._lexer
        m = _PATH_TAIL.match(lexer.lexdata, lexer.lexpos)
        segment = m.group(0) if m else ""
        lexer.lexpos += len(segment)
        if segment:
            self._queue.append(_tok("PATH_STR", segment, lexer.lineno))
        if lexer.lexdata[lexer.lexpos : lexer.lexpos + 2] == "${":
            lexer.lexpos += 2
            self._queue.append(_tok("DOLLAR_CURLY", "${", lexer.lineno))
            self._stack.append("expr")
        else:
            self._queue.append(_tok("PATH_END", "", lexer.lineno))
            self._stack.pop()
            self._begin(self._stack[-1])

    def input(self, text: str) -> None:
        self._lexer.input(text)
        self._lexer.lineno = 1
        self._stack = ["expr"]
        self._queue = []
        self._begin("expr")

    def token(self) -> Any:
        if self._queue:
            return self._queue.pop(0)
        tok: Any = self._lexer.token()
        return tok


def _tok(type_: str, value: str, lineno: int) -> Any:
    t = lex.LexToken()
    t.type = type_
    t.value = value
    t.lineno = lineno
    t.lexpos = 0
    return t


#: Built once; every :class:`NixLexer` clones it.
_MASTER = lex.lex(reflags=re.VERBOSE)
