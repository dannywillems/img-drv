//! The Nix lexer, built on `logos`.
//!
//! Generated rather than hand-written for the reason in
//! `docs/decisions/2026-08-02-nix-frontend-build-not-reuse.md`: Nix's own lexer
//! is Flex, its tokens overlap, and maximal munch resolves them. The sharpest
//! case is `x:x`, which is a URI and NOT a lambda, because the URI rule matches
//! more characters than the identifier rule does. `logos` picks the longest
//! match too, so that falls out rather than needing rule ordering the way PLY
//! does.
//!
//! # Modes, and how they are done here
//!
//! Interpolation needs lexer STATE, exactly as Nix's start conditions do:
//! inside a string `${` switches back to expression lexing, and the matching
//! `}` has to be told apart from an attribute set's closing brace.
//!
//! `logos` has no start conditions, so each mode is its own token enum. Rather
//! than `morph` between them, which moves the lexer, this keeps a plain
//! `(source, position)` pair and builds a fresh `logos::Lexer` over the
//! remaining slice for each token. Constructing one is O(1), and it makes the
//! mode a value in a stack instead of a type-level state the borrow checker
//! has to be talked through.

use logos::Logos;

/// A token, in the shape LALRPOP wants: `(start, token, end)`.
pub type Spanned = (usize, Tok, usize);

/// What the lexer is in the middle of.
///
/// `Path` is here because an interpolated path continues after its
/// interpolation closes, so the lexer has to know to keep reading path
/// characters rather than expression tokens.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Mode {
    Expr,
    Str,
    IndStr,
    Path,
}

/// The tokens the grammar consumes.
///
/// One enum for every mode, because the grammar does not care which mode
/// produced a chunk, only what it is.
///
/// `missing_docs` is allowed HERE and nowhere else in the crate: forty of these
/// are punctuation whose name is its whole meaning, and a doc comment saying
/// "a semicolon" on `Semi` is noise that hides the five variants that DO carry
/// a rule. Those five are documented.
#[derive(Debug, Clone, PartialEq)]
#[allow(missing_docs)]
pub enum Tok {
    Int(i64),
    Float(f64),
    Id(String),
    /// A string chunk that DOES take part in an indented string's dedenting.
    Str(String),
    /// A chunk produced by an escape, which does NOT.
    ///
    /// This is Nix's `StringToken.hasIndentation`, and it matters for a reason
    /// that is easy to miss: an escaped newline is a real newline character,
    /// so scanning it would make the following text look like the start of an
    /// unindented line and switch the dedent off for the whole string.
    EStr(String),
    Path(String),
    SPath(String),
    Uri(String),
    /// The literal prefix of an interpolated path, `${` already consumed.
    PathStart(String),
    /// A literal segment BETWEEN interpolations in a path.
    PathStr(String),
    /// The end of an interpolated path. Emitted without consuming input.
    PathEnd,
    If,
    Then,
    Else,
    Assert,
    With,
    Let,
    In,
    Rec,
    Inherit,
    OrKw,
    DQuote,
    IndOpen,
    IndClose,
    DollarCurly,
    LCurly,
    RCurly,
    LParen,
    RParen,
    LBrack,
    RBrack,
    Semi,
    Comma,
    Colon,
    At,
    Dot,
    Ellipsis,
    Assign,
    Question,
    Eq,
    Neq,
    Leq,
    Geq,
    Lt,
    Gt,
    And,
    Or,
    Impl,
    Update,
    Concat,
    Plus,
    Minus,
    Times,
    Slash,
    Not,
}

/// A lexical error, carrying the byte offset so a message can be located.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LexError {
    /// Byte offset into the source where the lexer gave up.
    pub offset: usize,
    /// What went wrong, in the same shape as the other implementations'.
    pub message: String,
}

impl std::fmt::Display for Tok {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // Only ever used inside a parse-error message, so the debug shape is
        // the useful one: it names the variant AND its payload.
        write!(f, "{self:?}")
    }
}

impl std::fmt::Display for LexError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "offset {}: {}", self.offset, self.message)
    }
}

#[derive(Logos, Debug, PartialEq)]
#[logos(skip r"[ \t\r\n]+")]
// `allow_greedy` because a line comment genuinely runs to the newline;
// logos warns since such a pattern can scan far, which is what it must do.
#[logos(skip(r"#[^\n]*", allow_greedy = true))]
#[logos(skip r"/\*([^*]|\*+[^*/])*\*+/")]
enum ExprTok {
    // `uri` before `id` is not needed here: logos takes the longest match, so
    // `x:x` lexes as a URI on its own.
    #[regex(r"[A-Za-z][A-Za-z0-9+\-.]*:[A-Za-z0-9%/?:@&=+$,_.!~*'\-]+")]
    Uri,
    #[token("if")]
    If,
    #[token("then")]
    Then,
    #[token("else")]
    Else,
    #[token("assert")]
    Assert,
    #[token("with")]
    With,
    #[token("let")]
    Let,
    #[token("in")]
    In,
    #[token("rec")]
    Rec,
    #[token("inherit")]
    Inherit,
    #[token("or")]
    OrKw,
    #[regex(r"[A-Za-z_][A-Za-z0-9_'\-]*")]
    Id,
    #[regex(r"([0-9]+\.[0-9]*|\.[0-9]+)([Ee][+\-]?[0-9]+)?")]
    Float,
    #[regex(r"[0-9]+")]
    Int,
    // A path containing an interpolation. The prefix is looser than `path`: it
    // may end in a bare slash, as in `./${v}`.
    #[regex(r"(~(/[A-Za-z0-9._+\-]*)+|[A-Za-z0-9._+\-]*(/[A-Za-z0-9._+\-]*)+)\$\{")]
    PathStart,
    #[regex(r"~(/[A-Za-z0-9._+\-]+)+/?")]
    #[regex(r"[A-Za-z0-9._+\-]*(/[A-Za-z0-9._+\-]+)+/?")]
    Path,
    #[regex(r"<[A-Za-z0-9._+\-]+(/[A-Za-z0-9._+\-]+)*>")]
    SPath,
    // The opening delimiter swallows any spaces and ONE newline after it, which
    // is why an indented string on its own line has no leading blank line.
    #[regex(r"''[ ]*\n")]
    #[token("''")]
    IndOpen,
    #[token("\"")]
    DQuote,
    #[token("${")]
    DollarCurly,
    #[token("{")]
    LCurly,
    #[token("}")]
    RCurly,
    #[token("(")]
    LParen,
    #[token(")")]
    RParen,
    #[token("[")]
    LBrack,
    #[token("]")]
    RBrack,
    #[token(";")]
    Semi,
    #[token(",")]
    Comma,
    #[token(":")]
    Colon,
    #[token("@")]
    At,
    #[token("...")]
    Ellipsis,
    #[token(".")]
    Dot,
    #[token("=")]
    Assign,
    #[token("?")]
    Question,
    #[token("==")]
    Eq,
    #[token("!=")]
    Neq,
    #[token("<=")]
    Leq,
    #[token(">=")]
    Geq,
    #[token("<")]
    Lt,
    #[token(">")]
    Gt,
    #[token("&&")]
    And,
    #[token("||")]
    Or,
    #[token("->")]
    Impl,
    #[token("//")]
    Update,
    #[token("++")]
    Concat,
    #[token("+")]
    Plus,
    #[token("-")]
    Minus,
    #[token("*")]
    Times,
    #[token("/")]
    Slash,
    #[token("!")]
    Not,
}

/// Inside a double-quoted string.
///
/// The chunk boundaries MATTER, because nothing merges them afterwards: what
/// the lexer splits is exactly what the printed tree shows. So the runs are
/// transcribed from `NixOS/nix` `lexer.l` rather than invented.
#[derive(Logos, Debug, PartialEq)]
enum StrTok {
    #[token("\"")]
    DQuote,
    #[token("${")]
    DollarCurly,
    // Nix's FIRST rule uses flex TRAILING CONTEXT: a run ending in a dollar
    // that is followed by the closing quote. That dollar cannot be absorbed by
    // the ordinary run, which needs a character after it, so without this a
    // string ending in a dollar becomes a two-part concatenation. `logos` has
    // no lookahead, so the quote is matched and pushed back by the wrapper.
    #[regex(r#"([^$"\\]|\$[^{"\\]|\\[\s\S]|\$\\[\s\S])*\$""#)]
    RunThenQuote,
    #[regex(r#"([^$"\\]|\$[^{"\\]|\\[\s\S]|\$\\[\s\S])+"#)]
    Run,
    #[regex(r"\$\\|\$|\\")]
    Fallback,
}

/// Inside an indented string.
#[derive(Logos, Debug, PartialEq)]
enum IndTok {
    // One MAXIMAL run. Note what it EXCLUDES: a quote before another quote or
    // before a dollar, so the two-quote escapes below still get their chance.
    #[regex(r"([^$']|\$[^{']|'[^'$])+")]
    Run,
    #[token("'''")]
    EscQuotes,
    #[token("''$")]
    EscDollar,
    #[regex(r"''\\[\s\S]")]
    EscBackslash,
    #[token("''")]
    IndClose,
    #[token("${")]
    DollarCurly,
    #[token("'")]
    Quote,
    #[token("$")]
    Dollar,
}

fn unescape(c: char) -> char {
    match c {
        'n' => '\n',
        'r' => '\r',
        't' => '\t',
        c => c,
    }
}

/// Resolve the backslash escapes inside a matched run.
///
/// Nix's string rule matches a MAXIMAL run that already contains its escapes,
/// so unescaping happens on the whole token rather than one escape at a time.
fn unescape_run(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut chars = text.chars();
    while let Some(c) = chars.next() {
        if c == '\\' {
            match chars.next() {
                Some(next) => out.push(unescape(next)),
                None => out.push(c),
            }
        } else {
            out.push(c);
        }
    }
    out
}

/// The token stream LALRPOP drives.
pub struct Lexer<'a> {
    src: &'a str,
    pos: usize,
    stack: Vec<Mode>,
    queue: std::collections::VecDeque<Spanned>,
}

impl<'a> Lexer<'a> {
    /// Start lexing `src` in expression mode.
    pub fn new(src: &'a str) -> Self {
        Lexer {
            src,
            pos: 0,
            stack: vec![Mode::Expr],
            queue: std::collections::VecDeque::new(),
        }
    }

    fn mode(&self) -> Mode {
        *self.stack.last().unwrap_or(&Mode::Expr)
    }

    fn push(&mut self, mode: Mode) {
        self.stack.push(mode);
    }

    fn pop(&mut self) {
        if self.stack.len() > 1 {
            self.stack.pop();
        }
    }

    /// Consume the literal segment after an interpolation inside a path.
    ///
    /// The end of a path has to be signalled WITHOUT consuming the character
    /// that ended it, so it is queued here rather than matched by a rule.
    fn scan_path_tail(&mut self) {
        let rest = &self.src[self.pos..];
        let len = rest
            .find(|c: char| !(c.is_ascii_alphanumeric() || "._+-/".contains(c)))
            .unwrap_or(rest.len());
        let start = self.pos;
        if len > 0 {
            self.queue
                .push_back((start, Tok::PathStr(rest[..len].to_string()), start + len));
            self.pos += len;
        }
        if self.src[self.pos..].starts_with("${") {
            let at = self.pos;
            self.pos += 2;
            self.queue.push_back((at, Tok::DollarCurly, at + 2));
            self.push(Mode::Expr);
        } else {
            self.queue.push_back((self.pos, Tok::PathEnd, self.pos));
            self.pop();
        }
    }

    fn err(&self, message: &str) -> LexError {
        LexError {
            offset: self.pos,
            message: message.to_string(),
        }
    }

    fn next_expr(&mut self) -> Option<Result<Spanned, LexError>> {
        let rest = &self.src[self.pos..];
        let mut lex = ExprTok::lexer(rest);
        let token = lex.next()?;
        let span = lex.span();
        let (start, end) = (self.pos + span.start, self.pos + span.end);
        let text = &rest[span.clone()];
        self.pos = end;
        let tok = match token {
            Err(()) => return Some(Err(self.err("unexpected character"))),
            Ok(t) => t,
        };
        let out = match tok {
            ExprTok::Uri => Tok::Uri(text.to_string()),
            ExprTok::If => Tok::If,
            ExprTok::Then => Tok::Then,
            ExprTok::Else => Tok::Else,
            ExprTok::Assert => Tok::Assert,
            ExprTok::With => Tok::With,
            ExprTok::Let => Tok::Let,
            ExprTok::In => Tok::In,
            ExprTok::Rec => Tok::Rec,
            ExprTok::Inherit => Tok::Inherit,
            ExprTok::OrKw => Tok::OrKw,
            ExprTok::Id => Tok::Id(text.to_string()),
            ExprTok::Float => match text.parse() {
                Ok(f) => Tok::Float(f),
                Err(_) => return Some(Err(self.err("bad float"))),
            },
            ExprTok::Int => match text.parse() {
                Ok(n) => Tok::Int(n),
                Err(_) => return Some(Err(self.err("bad integer"))),
            },
            ExprTok::PathStart => {
                self.push(Mode::Path);
                self.push(Mode::Expr);
                Tok::PathStart(text[..text.len() - 2].to_string())
            }
            ExprTok::Path => Tok::Path(text.to_string()),
            ExprTok::SPath => Tok::SPath(text[1..text.len() - 1].to_string()),
            ExprTok::IndOpen => {
                self.push(Mode::IndStr);
                Tok::IndOpen
            }
            ExprTok::DQuote => {
                self.push(Mode::Str);
                Tok::DQuote
            }
            ExprTok::DollarCurly => {
                self.push(Mode::Expr);
                Tok::DollarCurly
            }
            ExprTok::LCurly => {
                self.push(Mode::Expr);
                Tok::LCurly
            }
            ExprTok::RCurly => {
                self.pop();
                if self.mode() == Mode::Path {
                    self.scan_path_tail();
                }
                Tok::RCurly
            }
            ExprTok::LParen => Tok::LParen,
            ExprTok::RParen => Tok::RParen,
            ExprTok::LBrack => Tok::LBrack,
            ExprTok::RBrack => Tok::RBrack,
            ExprTok::Semi => Tok::Semi,
            ExprTok::Comma => Tok::Comma,
            ExprTok::Colon => Tok::Colon,
            ExprTok::At => Tok::At,
            ExprTok::Ellipsis => Tok::Ellipsis,
            ExprTok::Dot => Tok::Dot,
            ExprTok::Assign => Tok::Assign,
            ExprTok::Question => Tok::Question,
            ExprTok::Eq => Tok::Eq,
            ExprTok::Neq => Tok::Neq,
            ExprTok::Leq => Tok::Leq,
            ExprTok::Geq => Tok::Geq,
            ExprTok::Lt => Tok::Lt,
            ExprTok::Gt => Tok::Gt,
            ExprTok::And => Tok::And,
            ExprTok::Or => Tok::Or,
            ExprTok::Impl => Tok::Impl,
            ExprTok::Update => Tok::Update,
            ExprTok::Concat => Tok::Concat,
            ExprTok::Plus => Tok::Plus,
            ExprTok::Minus => Tok::Minus,
            ExprTok::Times => Tok::Times,
            ExprTok::Slash => Tok::Slash,
            ExprTok::Not => Tok::Not,
        };
        Some(Ok((start, out, end)))
    }

    fn next_str(&mut self) -> Option<Result<Spanned, LexError>> {
        let rest = &self.src[self.pos..];
        let mut lex = StrTok::lexer(rest);
        let token = lex.next()?;
        let span = lex.span();
        let start = self.pos + span.start;
        let mut end = self.pos + span.end;
        let text = &rest[span.clone()];
        let tok = match token {
            Err(()) => return Some(Err(self.err("unterminated string"))),
            Ok(StrTok::DQuote) => {
                self.pop();
                Tok::DQuote
            }
            Ok(StrTok::DollarCurly) => {
                self.push(Mode::Expr);
                Tok::DollarCurly
            }
            Ok(StrTok::RunThenQuote) => {
                // Push the closing quote back, which is what flex's trailing
                // context does for free.
                end -= 1;
                Tok::Str(unescape_run(&text[..text.len() - 1]))
            }
            Ok(StrTok::Run) => Tok::Str(unescape_run(text)),
            Ok(StrTok::Fallback) => Tok::Str(text.to_string()),
        };
        self.pos = end;
        Some(Ok((start, tok, end)))
    }

    fn next_ind(&mut self) -> Option<Result<Spanned, LexError>> {
        let rest = &self.src[self.pos..];
        let mut lex = IndTok::lexer(rest);
        let token = lex.next()?;
        let span = lex.span();
        let (start, end) = (self.pos + span.start, self.pos + span.end);
        let text = &rest[span.clone()];
        self.pos = end;
        let tok = match token {
            Err(()) => {
                return Some(Err(self.err("unterminated indented string")));
            }
            Ok(IndTok::Run) => Tok::Str(text.to_string()),
            Ok(IndTok::EscQuotes) => Tok::EStr("''".to_string()),
            Ok(IndTok::EscDollar) => Tok::EStr("$".to_string()),
            Ok(IndTok::EscBackslash) => {
                let c = text.chars().nth(3).unwrap_or('\\');
                Tok::EStr(unescape(c).to_string())
            }
            Ok(IndTok::IndClose) => {
                self.pop();
                Tok::IndClose
            }
            Ok(IndTok::DollarCurly) => {
                self.push(Mode::Expr);
                Tok::DollarCurly
            }
            Ok(IndTok::Quote) => Tok::EStr("'".to_string()),
            Ok(IndTok::Dollar) => Tok::EStr("$".to_string()),
        };
        Some(Ok((start, tok, end)))
    }
}

impl Iterator for Lexer<'_> {
    type Item = Result<Spanned, LexError>;

    fn next(&mut self) -> Option<Self::Item> {
        if let Some(queued) = self.queue.pop_front() {
            return Some(Ok(queued));
        }
        match self.mode() {
            Mode::Expr | Mode::Path => self.next_expr(),
            Mode::Str => self.next_str(),
            Mode::IndStr => self.next_ind(),
        }
    }
}
