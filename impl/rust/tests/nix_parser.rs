//! The parser, against the vectors real Nix produced.
//!
//! Two gates, measuring different things.
//!
//! `docs/spec/nix-parse/vectors.tsv` is 59 cases someone thought of, and it
//! pins the DESUGARINGS precisely: which operators become builtin calls, which
//! do not, how a comparison is rewritten, how a float formats. Those are easy
//! to get subtly wrong and hard to notice on real input, because real files
//! rarely exercise `>=` at the top level.
//!
//! `make nixpkgs-parse` is thousands of real files, and it pins everything the
//! vectors do not: attribute order, quoting, string chunking, path resolution.
//! The OCaml parser passed all 59 and then scored 0 of 40 on real files; see
//! `docs/abstractions.md` entry 13.
//!
//! Both run. Neither is redundant.

use img_drv::nix::parse_and_print;

fn vectors() -> Vec<(String, String)> {
    let path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../docs/spec/nix-parse/vectors.tsv"
    );
    std::fs::read_to_string(path)
        .expect("vectors.tsv")
        .lines()
        .filter(|l| !l.trim().is_empty())
        .filter_map(|l| {
            l.split_once('\t')
                .map(|(a, b)| (a.to_string(), b.to_string()))
        })
        .collect()
}

#[test]
fn matches_nix_instantiate_parse() {
    let cases = vectors();
    assert!(cases.len() >= 20, "vector file looks empty");
    for (source, expected) in cases {
        let got = parse_and_print(&source, "", "").unwrap_or_else(|e| panic!("{source}: {e}"));
        assert_eq!(got, expected, "for {source}");
    }
}

/// `a.${k}` and `a."${k}"` are DIFFERENT nodes.
///
/// Nix keeps them apart and prints them differently; the extra parentheses in
/// the second are the string wrapper showing through. Conflating them was a
/// real bug, so it gets a test rather than relying on one vector.
#[test]
fn dynamic_attribute_forms_are_distinct() {
    let direct = parse_and_print(r#"let a={b=1;}; k="b"; in a.${k}"#, "", "").expect("parse");
    assert!(direct.ends_with(r#"(a)."${k}")"#), "{direct}");

    let wrapped = parse_and_print(r#"let k = "z"; in { "${k}" = 1; }"#, "", "").expect("parse");
    assert!(wrapped.ends_with(r#"{ "${(k)}" = 1; })"#), "{wrapped}");
}

/// `./x/${v}.nix` is a path CONCATENATION, not a string.
///
/// The leading segment stays a path and keeps its trailing separator, which is
/// what joins the pieces into a location rather than gluing them together.
#[test]
fn interpolated_path_is_a_concatenation() {
    let got = parse_and_print(r#"let v = "1"; in ./x/${v}.nix"#, "/abs", "").expect("parse");
    assert!(got.ends_with(r#"(/abs/x/ + v + ".nix"))"#), "{got}");
}

/// Nix resolves a relative path against the file it is written in.
#[test]
fn paths_resolve_at_parse_time() {
    assert_eq!(
        parse_and_print("./common/x11.nix", "/w/nixos/tests", "").unwrap(),
        "/w/nixos/tests/common/x11.nix"
    );
    assert_eq!(
        parse_and_print("~/x.nix", "", "/root").unwrap(),
        "/root/x.nix"
    );
}

/// Nix stores an attribute set as a sorted map, so order is by name.
#[test]
fn attribute_sets_print_sorted() {
    assert_eq!(
        parse_and_print("{ b = 1; a = 2; }", "", "").unwrap(),
        "{ a = 2; b = 1; }"
    );
    assert_eq!(
        parse_and_print("({ b, a }: a)", "", "").unwrap(),
        "({ a, b }: a)"
    );
}

/// A bare keyword would not parse back, so Nix quotes it. Except `or`.
#[test]
fn keywords_and_non_identifiers_are_quoted() {
    for (source, want) in [
        (r#"{ "inherit" = 1; }"#, r#"{ "inherit" = 1; }"#),
        (r#"{ "0.92" = 1; }"#, r#"{ "0.92" = 1; }"#),
        (r#"{ "a-b" = 1; }"#, "{ a-b = 1; }"),
        (r#"{ "or" = 1; }"#, "{ or = 1; }"),
    ] {
        assert_eq!(parse_and_print(source, "", "").unwrap(), want);
    }
}

/// The lexer's maximal run draws the boundary; nothing merges afterwards.
///
/// `"a$b"` is ONE chunk because Nix's run rule absorbs a dollar that does not
/// open an interpolation. An escaped dollar in an indented string is its own
/// chunk and stays separate, which is the case a merge pass gets wrong.
#[test]
fn string_parts_are_not_merged() {
    assert_eq!(parse_and_print(r#""a$b""#, "", "").unwrap(), r#""a$b""#);
    assert_eq!(
        parse_and_print("''a''$b''", "", "").unwrap(),
        r#"("a" + "$" + "b")"#
    );
}

/// A string ending in a dollar is ONE literal, which needs flex's trailing
/// context and, here, a pushback.
#[test]
fn trailing_dollar_stays_in_the_run() {
    assert_eq!(parse_and_print(r#""a$""#, "", "").unwrap(), r#""a$""#);
}
