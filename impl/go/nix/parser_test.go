package nix

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The parser, against the vectors real Nix produced.
//
// Two gates, measuring different things.
//
// docs/spec/nix-parse/vectors.tsv is 59 cases someone thought of, and it pins
// the DESUGARINGS precisely: which operators become builtin calls, which do
// not, how a comparison is rewritten, how a float formats. Those are easy to
// get subtly wrong and hard to notice on real input, because real files rarely
// exercise >= at the top level of an expression.
//
// make nixpkgs-parse is thousands of real files, and it pins everything the
// vectors do not: attribute order, quoting, string chunking, path resolution.
// The OCaml parser passed all 59 and then scored 0 of 40 on real files; see
// docs/abstractions.md entry 13.
//
// Both run. Neither is redundant.

func vectors(t *testing.T) [][2]string {
	t.Helper()
	path := filepath.Join("..", "..", "..", "docs", "spec", "nix-parse", "vectors.tsv")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("vectors.tsv: %v", err)
	}
	out := [][2]string{}
	for _, line := range strings.Split(string(data), "\n") {
		if strings.TrimSpace(line) == "" {
			continue
		}
		source, expected, ok := strings.Cut(line, "\t")
		if !ok {
			continue
		}
		out = append(out, [2]string{source, expected})
	}
	return out
}

func TestMatchesNixInstantiateParse(t *testing.T) {
	cases := vectors(t)
	if len(cases) < 20 {
		t.Fatalf("vector file looks empty: %d cases", len(cases))
	}
	for _, c := range cases {
		got, err := ParseAndPrint(c[0], "", "")
		if err != nil {
			t.Errorf("%s: %v", c[0], err)
			continue
		}
		if got != c[1] {
			t.Errorf("for %s\n  want %s\n  got  %s", c[0], c[1], got)
		}
	}
}

// a.${k} and a."${k}" are DIFFERENT nodes.
//
// Nix keeps them apart and prints them differently; the extra parentheses in
// the second are the string wrapper showing through. Conflating them was a real
// bug, so it gets a test rather than relying on one vector.
func TestDynamicAttributeFormsAreDistinct(t *testing.T) {
	direct := mustPrint(t, `let a={b=1;}; k="b"; in a.${k}`, "", "")
	if !strings.HasSuffix(direct, `(a)."${k}")`) {
		t.Errorf("direct form: %s", direct)
	}
	wrapped := mustPrint(t, `let k = "z"; in { "${k}" = 1; }`, "", "")
	if !strings.HasSuffix(wrapped, `{ "${(k)}" = 1; })`) {
		t.Errorf("wrapped form: %s", wrapped)
	}
}

// ./x/${v}.nix is a path CONCATENATION, not a string.
//
// The leading segment stays a path and keeps its trailing separator, which is
// what joins the pieces into a location rather than gluing them together.
func TestInterpolatedPathIsAConcatenation(t *testing.T) {
	got := mustPrint(t, `let v = "1"; in ./x/${v}.nix`, "/abs", "")
	if !strings.HasSuffix(got, `(/abs/x/ + v + ".nix"))`) {
		t.Errorf("got %s", got)
	}
}

// Nix resolves a relative path against the file it is written in.
func TestPathsResolveAtParseTime(t *testing.T) {
	check(t, mustPrint(t, "./common/x11.nix", "/w/nixos/tests", ""),
		"/w/nixos/tests/common/x11.nix")
	check(t, mustPrint(t, "~/x.nix", "", "/root"), "/root/x.nix")
}

// Nix stores an attribute set as a sorted map, so order is by name.
func TestAttributeSetsPrintSorted(t *testing.T) {
	check(t, mustPrint(t, "{ b = 1; a = 2; }", "", ""), "{ a = 2; b = 1; }")
	check(t, mustPrint(t, "({ b, a }: a)", "", ""), "({ a, b }: a)")
}

// A bare keyword would not parse back, so Nix quotes it. Except `or`.
func TestKeywordsAndNonIdentifiersAreQuoted(t *testing.T) {
	for _, c := range [][2]string{
		{`{ "inherit" = 1; }`, `{ "inherit" = 1; }`},
		{`{ "0.92" = 1; }`, `{ "0.92" = 1; }`},
		{`{ "a-b" = 1; }`, `{ a-b = 1; }`},
		{`{ "or" = 1; }`, `{ or = 1; }`},
	} {
		check(t, mustPrint(t, c[0], "", ""), c[1])
	}
}

// The lexer's maximal run draws the boundary; nothing merges afterwards.
//
// "a$b" is ONE chunk because Nix's run rule absorbs a dollar that does not open
// an interpolation. An escaped dollar in an indented string is its own chunk and
// stays separate, which is the case a merge pass gets wrong.
func TestStringPartsAreNotMerged(t *testing.T) {
	check(t, mustPrint(t, `"a$b"`, "", ""), `"a$b"`)
	check(t, mustPrint(t, "''a''$b''", "", ""), `("a" + "$" + "b")`)
}

// A string ending in a dollar is ONE literal, which needs flex's trailing
// context and, in a hand-written scanner, an explicit lookahead.
func TestTrailingDollarStaysInTheRun(t *testing.T) {
	check(t, mustPrint(t, `"a$"`, "", ""), `"a$"`)
}

// x:x is a URI and NOT a lambda, because the URI rule matches more characters.
//
// This is the maximal-munch case a hand-written scanner gets wrong silently,
// and Go is the only implementation here without a generator to enforce it.
func TestURIBeatsIdentifierColon(t *testing.T) {
	check(t, mustPrint(t, "x:x", "", ""), `"x:x"`)
}

func mustPrint(t *testing.T, source, base, home string) string {
	t.Helper()
	got, err := ParseAndPrint(source, base, home)
	if err != nil {
		t.Fatalf("%s: %v", source, err)
	}
	return got
}

func check(t *testing.T, got, want string) {
	t.Helper()
	if got != want {
		t.Errorf("want %s\n got  %s", want, got)
	}
}
