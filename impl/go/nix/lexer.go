package nix

import (
	"fmt"
	"strconv"
	"strings"
)

// The Nix lexer, hand-written in the goyacc idiom.
//
// The other three implementations use a lexer GENERATOR: ocamllex, PLY's lex,
// logos. Go has no standard one, and goyacc's own convention is a scanner that
// implements the Lex method, so this is the one place where the front-end
// decision record's "use the standard tools" lands on writing it out.
//
// That makes the maximal-munch discipline the generators provide for free
// something this file has to keep by hand. Every place it matters is marked,
// because the failure mode is silent: a hand-written tokeniser that reads an
// identifier and then a colon disagrees with Nix on `x:x`, which is a URI and
// NOT a lambda, and nothing about the resulting parse looks wrong.
//
// Interpolation needs lexer STATE, exactly as Nix's start conditions do. The
// mode stack is explicit because `}` is ambiguous without it: it closes an
// attribute set in expression mode and ends an antiquotation otherwise.

type mode int

const (
	modeExpr mode = iota
	modeStr
	modeIndStr
	// modePath is where an interpolated path continues after its
	// interpolation closes, so the lexer keeps reading path characters
	// rather than expression tokens.
	modePath
)

// A queued token, for the one case that has to emit without consuming input.
type queued struct {
	kind int
	text string
}

// Lexer scans Nix source for the generated parser.
type Lexer struct {
	src    string
	pos    int
	stack  []mode
	queue  []queued
	result Expr
	err    string
}

// NewLexer starts scanning src in expression mode.
func NewLexer(src string) *Lexer {
	return &Lexer{src: src, stack: []mode{modeExpr}}
}

func (l *Lexer) mode() mode {
	if len(l.stack) == 0 {
		return modeExpr
	}
	return l.stack[len(l.stack)-1]
}

func (l *Lexer) push(m mode) { l.stack = append(l.stack, m) }

func (l *Lexer) pop() {
	if len(l.stack) > 1 {
		l.stack = l.stack[:len(l.stack)-1]
	}
}

// Error records a parse error. goyacc calls this; it must not panic.
func (l *Lexer) Error(s string) {
	if l.err == "" {
		l.err = fmt.Sprintf("%d: %s", l.line(), s)
	}
}

func (l *Lexer) line() int {
	return strings.Count(l.src[:min(l.pos, len(l.src))], "\n") + 1
}

func (l *Lexer) fail(format string, args ...any) int {
	l.Error(fmt.Sprintf(format, args...))
	return -1
}

// Lex returns the next token, in the shape goyacc expects.
func (l *Lexer) Lex(lval *nixSymType) int {
	if len(l.queue) > 0 {
		q := l.queue[0]
		l.queue = l.queue[1:]
		lval.str = q.text
		return q.kind
	}
	switch l.mode() {
	case modeStr:
		return l.lexString(lval)
	case modeIndStr:
		return l.lexIndString(lval)
	default:
		return l.lexExpr(lval)
	}
}

func isIDStart(c byte) bool {
	return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c == '_'
}

func isIDChar(c byte) bool {
	return isIDStart(c) || c >= '0' && c <= '9' || c == '\'' || c == '-'
}

func isDigit(c byte) bool { return c >= '0' && c <= '9' }

func isPathChar(c byte) bool {
	return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || isDigit(c) ||
		c == '.' || c == '_' || c == '+' || c == '-'
}

func isURIChar(c byte) bool {
	return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || isDigit(c) ||
		strings.IndexByte("%/?:@&=+$,_.!~*'-", c) >= 0
}

var keywords = map[string]int{
	"if": IF, "then": THEN, "else": ELSE, "assert": ASSERT, "with": WITH,
	"let": LET, "in": IN, "rec": REC, "inherit": INHERIT, "or": OR_KW,
}

// skipTrivia advances past whitespace and comments.
func (l *Lexer) skipTrivia() {
	for l.pos < len(l.src) {
		c := l.src[l.pos]
		switch {
		case c == ' ' || c == '\t' || c == '\r' || c == '\n':
			l.pos++
		case c == '#':
			for l.pos < len(l.src) && l.src[l.pos] != '\n' {
				l.pos++
			}
		case strings.HasPrefix(l.src[l.pos:], "/*"):
			end := strings.Index(l.src[l.pos+2:], "*/")
			if end < 0 {
				l.pos = len(l.src)
				return
			}
			l.pos += end + 4
		default:
			return
		}
	}
}

// tryURI matches scheme:rest. It runs BEFORE identifiers, which is the whole
// point: `x:x` is a URI because the URI rule matches more characters, and a
// tokeniser that reads an identifier first gets a lambda instead.
func (l *Lexer) tryURI() (string, bool) {
	i := l.pos
	if i >= len(l.src) || !(l.src[i] >= 'a' && l.src[i] <= 'z' ||
		l.src[i] >= 'A' && l.src[i] <= 'Z') {
		return "", false
	}
	for i < len(l.src) {
		c := l.src[i]
		if c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || isDigit(c) ||
			c == '+' || c == '-' || c == '.' {
			i++
			continue
		}
		break
	}
	if i >= len(l.src) || l.src[i] != ':' {
		return "", false
	}
	j := i + 1
	for j < len(l.src) && isURIChar(l.src[j]) {
		j++
	}
	if j == i+1 {
		return "", false
	}
	return l.src[l.pos:j], true
}

// tryPath matches a path, and reports whether an interpolation follows it.
//
// The prefix of an INTERPOLATED path is looser than a plain one: it may end in
// a bare slash, as in `./${v}`, which the plain form rejects because it wants a
// segment after every separator.
func (l *Lexer) tryPath() (text string, interpolated bool, ok bool) {
	i := l.pos
	if i < len(l.src) && l.src[i] == '~' {
		i++
		if i >= len(l.src) || l.src[i] != '/' {
			return "", false, false
		}
	} else {
		for i < len(l.src) && isPathChar(l.src[i]) {
			i++
		}
	}
	if i >= len(l.src) || l.src[i] != '/' {
		return "", false, false
	}
	segments := 0
	last := i
	for i < len(l.src) && l.src[i] == '/' {
		i++
		start := i
		for i < len(l.src) && isPathChar(l.src[i]) {
			i++
		}
		if i > start {
			segments++
			last = i
		} else {
			last = i
			break
		}
	}
	if strings.HasPrefix(l.src[last:], "${") {
		return l.src[l.pos:last], true, true
	}
	if segments == 0 {
		return "", false, false
	}
	// A plain path may end in a separator, but only after a real segment.
	if last < len(l.src) && l.src[last] == '/' {
		last++
	}
	return l.src[l.pos:last], false, true
}

// scanPathTail consumes the literal segment after an interpolation inside a
// path, then queues either another interpolation or the end.
//
// The end has to be signalled WITHOUT consuming the character that caused it,
// which is why it is queued rather than returned.
func (l *Lexer) scanPathTail() {
	start := l.pos
	for l.pos < len(l.src) && (isPathChar(l.src[l.pos]) || l.src[l.pos] == '/') {
		l.pos++
	}
	if l.pos > start {
		l.queue = append(l.queue, queued{PATH_STR, l.src[start:l.pos]})
	}
	if strings.HasPrefix(l.src[l.pos:], "${") {
		l.pos += 2
		l.queue = append(l.queue, queued{DOLLAR_CURLY, "${"})
		l.push(modeExpr)
		return
	}
	l.queue = append(l.queue, queued{PATH_END, ""})
	l.pop()
}

// operators, LONGEST FIRST. The order is the maximal munch a generator would
// apply for us: `...` before `.`, `//` before `/`, `++` before `+`, and so on.
// Reordering this table silently changes the language.
var operators = []struct {
	text string
	kind int
}{
	{"...", ELLIPSIS},
	{"==", EQ}, {"!=", NEQ}, {"<=", LEQ}, {">=", GEQ},
	{"&&", AND}, {"||", OR}, {"->", IMPL}, {"//", UPDATE}, {"++", CONCAT},
	{"(", LPAREN}, {")", RPAREN}, {"[", LBRACK}, {"]", RBRACK},
	{";", SEMI}, {",", COMMA}, {":", COLON}, {"@", AT}, {".", DOT},
	{"=", ASSIGN}, {"?", QUESTION}, {"<", LT}, {">", GT},
	{"+", PLUS}, {"-", MINUS}, {"*", TIMES}, {"/", SLASH}, {"!", NOT},
}

func (l *Lexer) lexExpr(lval *nixSymType) int {
	l.skipTrivia()
	if l.pos >= len(l.src) {
		return 0
	}
	rest := l.src[l.pos:]
	c := l.src[l.pos]

	if text, ok := l.tryURI(); ok {
		l.pos += len(text)
		lval.str = text
		return URI_LIT
	}

	if c == '<' {
		if end := strings.IndexByte(rest, '>'); end > 1 {
			inner := rest[1:end]
			if inner != "" && allPathChars(inner) {
				l.pos += end + 1
				lval.str = inner
				return SPATH
			}
		}
	}

	if text, interpolated, ok := l.tryPath(); ok {
		l.pos += len(text)
		if interpolated {
			l.pos += 2
			l.push(modePath)
			l.push(modeExpr)
			lval.str = text
			return PATH_START
		}
		lval.str = text
		return PATH
	}

	if isIDStart(c) {
		i := l.pos
		for i < len(l.src) && isIDChar(l.src[i]) {
			i++
		}
		word := l.src[l.pos:i]
		l.pos = i
		if kind, ok := keywords[word]; ok {
			return kind
		}
		lval.str = word
		return IDENT
	}

	// A float before an int, because `1.5` must not lex as `1` then `.5`.
	if isDigit(c) || (c == '.' && l.pos+1 < len(l.src) && isDigit(l.src[l.pos+1])) {
		if text, ok := matchFloat(rest); ok {
			f, err := strconv.ParseFloat(text, 64)
			if err != nil {
				return l.fail("bad float %q", text)
			}
			l.pos += len(text)
			lval.fnum = f
			return FLOAT
		}
		i := l.pos
		for i < len(l.src) && isDigit(l.src[i]) {
			i++
		}
		n, err := strconv.ParseInt(l.src[l.pos:i], 10, 64)
		if err != nil {
			return l.fail("bad integer")
		}
		l.pos = i
		lval.num = n
		return INT
	}

	// The opening delimiter of an indented string swallows any spaces and ONE
	// newline after it, which is why such a string has no leading blank line.
	if strings.HasPrefix(rest, "''") {
		i := l.pos + 2
		j := i
		for j < len(l.src) && l.src[j] == ' ' {
			j++
		}
		if j < len(l.src) && l.src[j] == '\n' {
			i = j + 1
		}
		l.pos = i
		l.push(modeIndStr)
		return IND_OPEN
	}

	if c == '"' {
		l.pos++
		l.push(modeStr)
		return DQUOTE
	}
	if strings.HasPrefix(rest, "${") {
		l.pos += 2
		l.push(modeExpr)
		return DOLLAR_CURLY
	}
	if c == '{' {
		l.pos++
		l.push(modeExpr)
		return LCURLY
	}
	if c == '}' {
		l.pos++
		l.pop()
		if l.mode() == modePath {
			l.scanPathTail()
		}
		return RCURLY
	}

	for _, op := range operators {
		if strings.HasPrefix(rest, op.text) {
			l.pos += len(op.text)
			return op.kind
		}
	}
	return l.fail("unexpected character %q", string(c))
}

func allPathChars(s string) bool {
	for i := 0; i < len(s); i++ {
		if !isPathChar(s[i]) && s[i] != '/' {
			return false
		}
	}
	return true
}

// matchFloat recognises Nix's float syntax at the start of s.
func matchFloat(s string) (string, bool) {
	i := 0
	for i < len(s) && isDigit(s[i]) {
		i++
	}
	if i >= len(s) || s[i] != '.' {
		return "", false
	}
	i++
	for i < len(s) && isDigit(s[i]) {
		i++
	}
	if i < len(s) && (s[i] == 'e' || s[i] == 'E') {
		j := i + 1
		if j < len(s) && (s[j] == '+' || s[j] == '-') {
			j++
		}
		if j < len(s) && isDigit(s[j]) {
			for j < len(s) && isDigit(s[j]) {
				j++
			}
			i = j
		}
	}
	return s[:i], true
}

func unescape(c byte) byte {
	switch c {
	case 'n':
		return '\n'
	case 'r':
		return '\r'
	case 't':
		return '\t'
	}
	return c
}

// unescapeRun resolves the backslash escapes inside a matched run.
//
// Nix's string rule matches a MAXIMAL run that already contains its escapes, so
// unescaping happens on the whole token rather than one escape at a time.
func unescapeRun(text string) string {
	var b strings.Builder
	for i := 0; i < len(text); i++ {
		if text[i] == '\\' && i+1 < len(text) {
			b.WriteByte(unescape(text[i+1]))
			i++
			continue
		}
		b.WriteByte(text[i])
	}
	return b.String()
}

// lexString scans inside a double-quoted string.
//
// The chunk boundaries MATTER, because nothing merges them afterwards: what the
// lexer splits is exactly what the printed tree shows. So the run below is
// transcribed from NixOS/nix lexer.l rather than invented.
func (l *Lexer) lexString(lval *nixSymType) int {
	if l.pos >= len(l.src) {
		return l.fail("unterminated string")
	}
	if l.src[l.pos] == '"' {
		l.pos++
		l.pop()
		return DQUOTE
	}
	if strings.HasPrefix(l.src[l.pos:], "${") {
		l.pos += 2
		l.push(modeExpr)
		return DOLLAR_CURLY
	}
	start := l.pos
	i := l.pos
	for i < len(l.src) {
		c := l.src[i]
		if c == '"' {
			break
		}
		if c == '\\' {
			if i+1 >= len(l.src) {
				break
			}
			i += 2
			continue
		}
		if c == '$' {
			// A dollar that opens an interpolation ends the run. One that is
			// followed by the closing quote does NOT: Nix's first rule uses
			// flex trailing context to keep it, so a string ending in a dollar
			// stays one literal instead of becoming a concatenation.
			if i+1 < len(l.src) && l.src[i+1] == '{' {
				break
			}
			if i+1 < len(l.src) && l.src[i+1] == '"' {
				i++
				break
			}
			if i+1 >= len(l.src) {
				break
			}
			i += 2
			continue
		}
		i++
	}
	if i == start {
		// The fallback Nix keeps for a dollar or backslash the run could not
		// absorb, which happens at the very end of a string.
		l.pos++
		lval.str = l.src[start:l.pos]
		return STR
	}
	l.pos = i
	lval.str = unescapeRun(l.src[start:i])
	return STR
}

// lexIndString scans inside an indented string.
func (l *Lexer) lexIndString(lval *nixSymType) int {
	if l.pos >= len(l.src) {
		return l.fail("unterminated indented string")
	}
	rest := l.src[l.pos:]
	// The escapes come first because each is longer than the delimiter it
	// starts with; that is the maximal munch a generator would apply.
	switch {
	case strings.HasPrefix(rest, "'''"):
		l.pos += 3
		lval.str = "''"
		return ESTR
	case strings.HasPrefix(rest, "''$"):
		l.pos += 3
		lval.str = "$"
		return ESTR
	case strings.HasPrefix(rest, "''\\") && len(rest) > 3:
		l.pos += 4
		lval.str = string(unescape(rest[3]))
		return ESTR
	case strings.HasPrefix(rest, "''"):
		l.pos += 2
		l.pop()
		return IND_CLOSE
	case strings.HasPrefix(rest, "${"):
		l.pos += 2
		l.push(modeExpr)
		return DOLLAR_CURLY
	}
	start := l.pos
	i := l.pos
	for i < len(l.src) {
		c := l.src[i]
		if c == '$' {
			if i+1 < len(l.src) && (l.src[i+1] == '{' || l.src[i+1] == '\'') {
				break
			}
			if i+1 >= len(l.src) {
				break
			}
			i += 2
			continue
		}
		if c == '\'' {
			// A quote before another quote or before a dollar ends the run, so
			// the escapes above get their chance.
			if i+1 < len(l.src) && (l.src[i+1] == '\'' || l.src[i+1] == '$') {
				break
			}
			if i+1 >= len(l.src) {
				break
			}
			i += 2
			continue
		}
		i++
	}
	if i == start {
		l.pos++
		lval.str = l.src[start:l.pos]
		return ESTR
	}
	l.pos = i
	lval.str = l.src[start:i]
	return STR
}

// Parse parses Nix source into an AST.
//
// base and home are what relative and tilde paths resolve against, because Nix
// performs that resolution at PARSE time.
func Parse(source, base, home string) (Expr, error) {
	SetContext(base, home)
	l := NewLexer(source)
	if nixParse(l) != 0 || l.err != "" {
		if l.err == "" {
			l.err = "syntax error"
		}
		return nil, fmt.Errorf("%s", l.err)
	}
	return l.result, nil
}

// ParseAndPrint parses, then prints in nix-instantiate --parse form.
func ParseAndPrint(source, base, home string) (string, error) {
	e, err := Parse(source, base, home)
	if err != nil {
		return "", err
	}
	return ToParseForm(e), nil
}
