//! The two string transformations Nix applies at PARSE time.
//!
//! Both are in the parser rather than the printer because Nix puts them there:
//! the AST holds the dedented text, so `--parse` prints one plain string for an
//! indented literal.

use super::ast::Part;

/// Drop empty literals, which would otherwise print as `"" + ...`.
///
/// Note what this does NOT do: merge adjacent literals. Nix does not merge them
/// either. Its lexer matches a MAXIMAL run so the pieces arrive already joined,
/// and the pieces it keeps separate stay separate in the printed tree.
pub fn drop_empty(parts: Vec<Part>) -> Vec<Part> {
    let kept: Vec<Part> = parts
        .into_iter()
        .filter(|p| !matches!(p, Part::Lit(s) if s.is_empty()))
        .collect();
    if kept.is_empty() {
        vec![Part::Lit(String::new())]
    } else {
        kept
    }
}

/// Remove the common indentation from an indented string.
///
/// Transcribed from `stripIndentation` in `NixOS/nix` `parser.y`. Two passes:
/// the first finds the minimum indentation over lines that have content, where
/// a line of only spaces does not count and an interpolation counts as content;
/// the second removes that many leading spaces per line and drops a final line
/// that is nothing but spaces.
///
/// The boolean is Nix's `StringToken.hasIndentation`. A chunk produced by an
/// escape is NOT scanned; it only ends the current run of start-of-line
/// whitespace. That matters because an escaped newline is a real newline
/// character: scanning it would make the following text look like an
/// unindented line and switch the dedent off for the whole string.
pub fn strip_indentation(parts: Vec<(Part, bool)>) -> Vec<Part> {
    let mut min_indent: Option<usize> = None;
    let mut at_start = true;
    let mut cur = 0usize;

    for (part, indented) in &parts {
        match (part, indented) {
            (Part::Lit(text), true) => {
                for c in text.chars() {
                    if at_start {
                        match c {
                            ' ' => cur += 1,
                            '\n' => cur = 0,
                            _ => {
                                at_start = false;
                                min_indent = Some(min_indent.map_or(cur, |m| m.min(cur)));
                            }
                        }
                    } else if c == '\n' {
                        at_start = true;
                        cur = 0;
                    }
                }
            }
            _ => {
                if at_start {
                    at_start = false;
                    min_indent = Some(min_indent.map_or(cur, |m| m.min(cur)));
                }
            }
        }
    }
    let indent = min_indent.unwrap_or(0);

    let last = parts.len().saturating_sub(1);
    let mut out: Vec<Part> = Vec::with_capacity(parts.len());
    let mut at_start = true;
    let mut dropped = 0usize;

    for (i, (part, indented)) in parts.into_iter().enumerate() {
        if !indented {
            at_start = false;
            dropped = 0;
            out.push(part);
            continue;
        }
        let Part::Lit(text) = part else {
            out.push(part);
            continue;
        };
        let mut buf = String::with_capacity(text.len());
        for c in text.chars() {
            if at_start {
                match c {
                    ' ' => {
                        if dropped >= indent {
                            buf.push(c);
                        }
                        dropped += 1;
                    }
                    '\n' => {
                        dropped = 0;
                        buf.push(c);
                    }
                    _ => {
                        at_start = false;
                        dropped = 0;
                        buf.push(c);
                    }
                }
            } else {
                buf.push(c);
                if c == '\n' {
                    at_start = true;
                    dropped = 0;
                }
            }
        }
        // The closing delimiter usually sits on its own indented line, and that
        // trailing run of spaces is not part of the value.
        if i == last
            && let Some(nl) = buf.rfind('\n')
            && buf[nl + 1..].chars().all(|c| c == ' ')
        {
            buf.truncate(nl + 1);
        }
        out.push(Part::Lit(buf));
    }
    drop_empty(out)
}
