package imgdrv

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// The regression gate: real derivations, produced by real Nix.
//
// Examples written by hand test the cases you already thought of, which is
// precisely the set that is already right. Every time hand-written examples and
// real derivations have disagreed in this repository, the hand-written ones
// were wrong.

const goldenDir = "../../docs/spec/examples"

func goldenFiles(t *testing.T) []string {
	t.Helper()
	entries, err := os.ReadDir(goldenDir)
	if err != nil {
		t.Fatalf("golden directory: %v", err)
	}
	out := []string{}
	for _, e := range entries {
		if filepath.Ext(e.Name()) == ".drv" {
			out = append(out, filepath.Join(goldenDir, e.Name()))
		}
	}
	sort.Strings(out)
	return out
}

func readGolden(t *testing.T, path string) string {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("%s: %v", path, err)
	}
	return strings.TrimRight(string(raw), "\n")
}

func TestTheExamplesArePresent(t *testing.T) {
	// A corpus that silently vanished would make everything below pass.
	if n := len(goldenFiles(t)); n < 10 {
		t.Fatalf("expected at least 10 golden files, found %d", n)
	}
}

func TestRoundTripsByteIdentically(t *testing.T) {
	// Byte equality, not structural equality: the bytes ARE the artifact, since
	// the derivation's own store path is their hash.
	for _, path := range goldenFiles(t) {
		t.Run(filepath.Base(path), func(t *testing.T) {
			text := readGolden(t, path)
			d, err := Parse(text)
			if err != nil {
				t.Fatalf("parse: %v", err)
			}
			if got := Unparse(d); got != text {
				t.Errorf("round trip differs\n got %s\nwant %s", got, text)
			}
		})
	}
}

func TestEveryOutputPathRecomputes(t *testing.T) {
	// The whole specification, end to end, on vectors nobody wrote by hand.
	corpus, err := LoadCorpus(goldenDir)
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	checked, mismatches := corpus.Verify()
	if checked < 12 {
		t.Fatalf("checked only %d outputs", checked)
	}
	for _, m := range mismatches {
		t.Errorf("%s", m)
	}
}

func TestRealDerivationsAreAlreadyCanonical(t *testing.T) {
	// If canonicalizing a real derivation changed it, our ordering rules would
	// merely be self-consistent, and every claim about byte-identity across
	// languages would be about our own convention rather than about Nix's.
	for _, path := range goldenFiles(t) {
		t.Run(filepath.Base(path), func(t *testing.T) {
			d, err := Parse(readGolden(t, path))
			if err != nil {
				t.Fatalf("parse: %v", err)
			}
			if !Canonical(d).Equal(d) {
				t.Error("canonicalizing changed a real derivation")
			}
		})
	}
}

func TestInputHashingIsMemoizedAndStable(t *testing.T) {
	// Same question, same answer: hashing is a function, not a process.
	corpus, err := LoadCorpus(goldenDir)
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	path := corpus.Paths()[0]
	first, ok := corpus.InputHash(path)
	if !ok {
		t.Fatalf("no hash for %s", path)
	}
	second, _ := corpus.InputHash(path)
	if first != second {
		t.Errorf("hashing is not a function: %s then %s", first, second)
	}
}

func TestNameComesFromTheStorePathPrefix(t *testing.T) {
	path := StorePath("/nix/store/" + strings.Repeat("a", 32) + "-hello.drv")
	if got := NameFromPath(path, nil); got != "hello" {
		t.Errorf("got %q, want %q", got, "hello")
	}
	// Not a store path: falls back rather than returning nonsense.
	if got := NameFromPath("./whatever.drv", nil); got != "whatever" {
		t.Errorf("got %q, want %q", got, "whatever")
	}
}
