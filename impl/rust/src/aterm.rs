//! The ATerm reader and writer.
//!
//! A hand-written recursive-descent parser, and NOT a regex, for the reason
//! recorded in `AGENTS.md`: a regex-based reader of derivations passed 12 of 12
//! hand-written examples and then failed 323 of 403 real ones, because real
//! derivations contain escaped quotes inside values, store paths embedded in
//! unrelated environment variables, and `],[` sequences inside strings.

use std::collections::BTreeMap;
use std::error::Error;
use std::fmt;

use crate::derivation::{Derivation, InputDrv, Output, OutputName, StorePath};

/// A derivation that could not be read.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ParseError {
    /// What the parser expected to find.
    pub what: String,
    /// Byte offset at which it was expected.
    pub at: usize,
}

impl fmt::Display for ParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "expected {} at byte {}", self.what, self.at)
    }
}

impl Error for ParseError {}

type Parsed<T> = Result<T, ParseError>;

struct Parser<'a> {
    /// Bytes, not chars: offsets have to be stable, and every structural
    /// character in the grammar is ASCII.
    text: &'a [u8],
    pos: usize,
}

impl<'a> Parser<'a> {
    fn new(text: &'a str) -> Self {
        Self {
            text: text.as_bytes(),
            pos: 0,
        }
    }

    fn error<T>(&self, what: &str) -> Parsed<T> {
        Err(ParseError {
            what: what.to_owned(),
            at: self.pos,
        })
    }

    fn peek(&self) -> Option<u8> {
        self.text.get(self.pos).copied()
    }

    fn expect(&mut self, ch: u8) -> Parsed<()> {
        if self.peek() == Some(ch) {
            self.pos += 1;
            Ok(())
        } else {
            self.error(&format!("{:?}", ch as char))
        }
    }

    fn literal(&mut self, text: &str) -> Parsed<()> {
        if self.text[self.pos..].starts_with(text.as_bytes()) {
            self.pos += text.len();
            Ok(())
        } else {
            self.error(text)
        }
    }

    /// A double-quoted string, undoing exactly the five escapes.
    ///
    /// Every other byte is taken literally, INCLUDING other control
    /// characters. An implementation that also decodes `\uXXXX`, as JSON does,
    /// reads a different language.
    fn string(&mut self) -> Parsed<String> {
        self.expect(b'"')?;
        let mut out = Vec::new();
        loop {
            let Some(c) = self.peek() else {
                return self.error("closing quote");
            };
            self.pos += 1;
            match c {
                b'"' => break,
                b'\\' => {
                    let Some(esc) = self.peek() else {
                        return self.error("escape character");
                    };
                    self.pos += 1;
                    out.push(match esc {
                        b'n' => b'\n',
                        b'r' => b'\r',
                        b't' => b'\t',
                        other => other,
                    });
                }
                other => out.push(other),
            }
        }
        String::from_utf8(out).or_else(|_| self.error("valid UTF-8"))
    }

    fn list_of<T>(&mut self, mut item: impl FnMut(&mut Self) -> Parsed<T>) -> Parsed<Vec<T>> {
        self.expect(b'[')?;
        let mut out = Vec::new();
        if self.peek() == Some(b']') {
            self.pos += 1;
            return Ok(out);
        }
        loop {
            out.push(item(self)?);
            match self.peek() {
                Some(b',') => self.pos += 1,
                Some(b']') => {
                    self.pos += 1;
                    return Ok(out);
                }
                _ => return self.error("',' or ']'"),
            }
        }
    }

    fn output(&mut self) -> Parsed<Output> {
        self.expect(b'(')?;
        let name = OutputName::new(self.string()?);
        self.expect(b',')?;
        let path = StorePath::new(self.string()?);
        self.expect(b',')?;
        let hash_algo = self.string()?;
        self.expect(b',')?;
        let hash = self.string()?;
        self.expect(b')')?;
        Ok(Output {
            name,
            path,
            hash_algo,
            hash,
        })
    }

    fn input_drv(&mut self) -> Parsed<InputDrv> {
        self.expect(b'(')?;
        let path = StorePath::new(self.string()?);
        self.expect(b',')?;
        let outputs = self.list_of(|p| p.string().map(OutputName::new))?;
        self.expect(b')')?;
        Ok(InputDrv { path, outputs })
    }

    fn env_entry(&mut self) -> Parsed<(String, String)> {
        self.expect(b'(')?;
        let key = self.string()?;
        self.expect(b',')?;
        let value = self.string()?;
        self.expect(b')')?;
        Ok((key, value))
    }
}

/// Read a derivation from its ATerm text.
///
/// A trailing newline is tolerated, because a `.drv` checked into a repository
/// has one and the store object does not.
pub fn parse(text: &str) -> Parsed<Derivation> {
    let mut p = Parser::new(text.trim());
    p.literal("Derive(")?;
    let outputs = p.list_of(Parser::output)?;
    p.expect(b',')?;
    let input_drvs = p.list_of(Parser::input_drv)?;
    p.expect(b',')?;
    let input_srcs = p.list_of(|q| q.string().map(StorePath::new))?;
    p.expect(b',')?;
    let system = p.string()?;
    p.expect(b',')?;
    let builder = p.string()?;
    p.expect(b',')?;
    let args = p.list_of(Parser::string)?;
    p.expect(b',')?;
    let env = p.list_of(Parser::env_entry)?;
    p.expect(b')')?;
    Ok(Derivation {
        outputs,
        input_drvs,
        input_srcs,
        system,
        builder,
        args,
        env,
    })
}

/// Apply exactly the five ATerm escapes, and nothing else.
pub fn escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            other => out.push(other),
        }
    }
    out
}

/// Escape and wrap in double quotes.
pub fn quote(s: &str) -> String {
    format!("\"{}\"", escape(s))
}

/// How to serialize: the two variants needed for hashing.
///
/// Getting either backwards yields a syntactically perfect derivation with
/// wrong paths, which is worse than an error because it looks correct.
#[derive(Default)]
pub struct Serialize<'a> {
    /// Blank this derivation's own output paths, in the outputs list AND in the
    /// env entries whose KEY is an output name. Required when computing those
    /// paths, since they are what is being computed. It must NOT blank an
    /// output path that merely appears inside some other value, which is
    /// precisely where a textual substitution goes wrong.
    pub mask_outputs: bool,
    /// Replace each input's store path with that input's own hash, and RE-SORT
    /// by it. The serialized `.drv` sorts inputs by PATH; the form that gets
    /// hashed sorts them by HASH. One derivation, two orderings.
    pub input_hashes: Option<&'a BTreeMap<StorePath, String>>,
}

/// Serialize a derivation back to ATerm, in the plain canonical form.
///
/// This is the inverse of [`parse`] on canonical input.
pub fn unparse(drv: &Derivation) -> String {
    unparse_with(drv, &Serialize::default())
}

/// Serialize a derivation, selecting one of the hashing variants.
pub fn unparse_with(drv: &Derivation, opts: &Serialize<'_>) -> String {
    let outs = join(drv.outputs.iter().map(|o| {
        format!(
            "({},{},{},{})",
            quote(o.name.as_str()),
            quote(if opts.mask_outputs {
                ""
            } else {
                o.path.as_str()
            }),
            quote(&o.hash_algo),
            quote(&o.hash),
        )
    }));

    let mut entries: Vec<(String, &Vec<OutputName>)> = drv
        .input_drvs
        .iter()
        .map(|i| {
            let key = match opts.input_hashes {
                Some(map) => map
                    .get(&i.path)
                    .cloned()
                    .unwrap_or_else(|| i.path.as_str().to_owned()),
                None => i.path.as_str().to_owned(),
            };
            (key, &i.outputs)
        })
        .collect();
    if opts.input_hashes.is_some() {
        entries.sort();
    }
    let ins = join(entries.iter().map(|(key, names)| {
        format!(
            "({},[{}])",
            quote(key),
            join(names.iter().map(|n| quote(n.as_str())))
        )
    }));

    let srcs = join(drv.input_srcs.iter().map(|s| quote(s.as_str())));
    let args = join(drv.args.iter().map(|a| quote(a)));
    let names = drv.output_names();
    let env = join(drv.env.iter().map(|(k, v)| {
        let blank = opts.mask_outputs && names.contains(k.as_str());
        format!("({},{})", quote(k), quote(if blank { "" } else { v }))
    }));

    format!(
        "Derive([{}],[{}],[{}],{},{},[{}],[{}])",
        outs,
        ins,
        srcs,
        quote(&drv.system),
        quote(&drv.builder),
        args,
        env,
    )
}

fn join(parts: impl Iterator<Item = String>) -> String {
    parts.collect::<Vec<_>>().join(",")
}
