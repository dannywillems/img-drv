//! Path resolution, which Nix performs at PARSE time.
//!
//! A relative path resolves against the directory of the file it is written
//! in, and a leading `~` against HOME, so `./common/x11.nix` written in
//! `nixos/tests/foo.nix` is an ABSOLUTE path in the tree and
//! `nix-instantiate --parse` prints it that way. A parser that keeps the
//! relative text produces a different tree.
//!
//! The directories live in thread-local cells rather than being threaded
//! through the parser, because the parser is generated and its entry point
//! takes only a token stream. Empty means "leave paths alone", which is what
//! the transpiler and the unit vectors want.

use std::cell::RefCell;

thread_local! {
    static BASE_DIR: RefCell<String> = const { RefCell::new(String::new()) };
    static HOME_DIR: RefCell<String> = const { RefCell::new(String::new()) };
}

/// Set the directories path literals resolve against.
pub fn set_context(base: &str, home: &str) {
    BASE_DIR.with(|b| *b.borrow_mut() = base.to_string());
    HOME_DIR.with(|h| *h.borrow_mut() = home.to_string());
}

/// Fold away `.` and `..`, collapse separators, drop a trailing one.
pub fn canonicalise(path: &str) -> String {
    let mut stack: Vec<&str> = Vec::new();
    for part in path.split('/') {
        match part {
            "" | "." => {}
            ".." => {
                stack.pop();
            }
            other => stack.push(other),
        }
    }
    format!("/{}", stack.join("/"))
}

/// Resolve a path literal against the base or home directory.
pub fn resolve_path(path: &str) -> String {
    if let Some(rest) = path.strip_prefix('~') {
        let home = HOME_DIR.with(|h| h.borrow().clone());
        return if home.is_empty() {
            path.to_string()
        } else {
            canonicalise(&format!("{home}{rest}"))
        };
    }
    let base = BASE_DIR.with(|b| b.borrow().clone());
    if base.is_empty() {
        path.to_string()
    } else if path.starts_with('/') {
        canonicalise(path)
    } else {
        canonicalise(&format!("{base}/{path}"))
    }
}

/// Resolve the literal PREFIX of an interpolated path.
///
/// Same as [`resolve_path`] except a trailing separator is KEPT, because it is
/// meaningful here: `./x/${v}` denotes `/abs/x/` concatenated with `v`, and
/// dropping the separator would glue the two segments together.
pub fn resolve_path_prefix(path: &str) -> String {
    let resolved = resolve_path(path);
    if path.ends_with('/') && resolved != "/" {
        format!("{resolved}/")
    } else {
        resolved
    }
}
