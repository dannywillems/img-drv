package imgdrv

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// A closure of derivations, and the recursive hashing over it.
//
// A real closure is a DAG with heavy sharing: a 226-derivation closure hashes
// the same bootstrap tools hundreds of times. The memo table is what makes
// verification linear in the number of edges rather than exponential in depth,
// and it is correct because a derivation is immutable and its hash depends only
// on its transitive inputs.
//
// Structurally this is a fold over a DAG. InputHash is defined by WELL-FOUNDED
// recursion: the graph is finite and acyclic, so the recursion terminates and
// picks out exactly one function, which is why every conforming implementation
// in any language must produce the same digests. See docs/abstractions.md
// entry 2.

// hashLen is the length of the base-32 prefix of a store path basename.
const hashLen = 32

// NameFromPath returns the derivation name that output paths are suffixed with.
//
// A real store path is <32 chars>-<name>.drv, so the hash prefix is stripped.
// When the file is not named that way, fall back to the name environment
// variable, which every derivation carries.
func NameFromPath(path StorePath, d *Derivation) string {
	base := string(path)
	if i := strings.LastIndex(base, "/"); i >= 0 {
		base = base[i+1:]
	}
	base = strings.TrimSuffix(base, ".drv")
	if head, tail, ok := strings.Cut(base, "-"); ok && len(head) == hashLen {
		onlyBase32 := true
		for i := 0; i < len(head); i++ {
			if !strings.ContainsRune(Base32Alphabet, rune(head[i])) {
				onlyBase32 = false
				break
			}
		}
		if onlyBase32 {
			return tail
		}
	}
	if d != nil && d.Name() != "" {
		return d.Name()
	}
	return base
}

// Mismatch is one output whose recomputed path differs from the recorded one.
type Mismatch struct {
	DrvName  string
	Output   OutputName
	Expected StorePath
	Got      StorePath
}

func (m Mismatch) String() string {
	got := string(m.Got)
	if got == "" {
		got = "<none>"
	}
	return fmt.Sprintf("%s:%s\n  expected %s\n  got      %s",
		m.DrvName, m.Output, m.Expected, got)
}

// Corpus is a set of derivations indexed by store path.
//
// Not every input is necessarily present: a closure exported from a store is
// complete, but a hand-assembled directory need not be. Inputs that are absent
// are left as paths, which is the only honest thing to do and is why an
// incomplete corpus produces mismatches rather than silence.
type Corpus struct {
	Drvs map[StorePath]Derivation
}

// LoadCorpus loads every *.drv in a directory, keyed by its store path.
func LoadCorpus(directory string) (Corpus, error) {
	entries, err := os.ReadDir(directory)
	if err != nil {
		return Corpus{}, err
	}
	drvs := map[StorePath]Derivation{}
	for _, e := range entries {
		if e.IsDir() || filepath.Ext(e.Name()) != ".drv" {
			continue
		}
		text, err := os.ReadFile(filepath.Join(directory, e.Name()))
		if err != nil {
			return Corpus{}, err
		}
		d, err := Parse(string(text))
		if err != nil {
			return Corpus{}, fmt.Errorf("%s: %w", e.Name(), err)
		}
		drvs[StorePath(Store+"/"+e.Name())] = d
	}
	return Corpus{Drvs: drvs}, nil
}

// Len is how many derivations the corpus holds.
func (c Corpus) Len() int { return len(c.Drvs) }

// Paths returns every store path in the corpus, sorted.
//
// Sorted because Go randomises map iteration, so anything that reports or
// compares in corpus order has to impose one.
func (c Corpus) Paths() []StorePath {
	out := make([]StorePath, 0, len(c.Drvs))
	for p := range c.Drvs {
		out = append(out, p)
	}
	sort.Slice(out, func(i, j int) bool { return out[i] < out[j] })
	return out
}

// InputHash is the hash by which a derivation is known when it is someone's
// INPUT.
//
// Outputs are NOT masked here; that is the asymmetry documented in OutputPaths
// and in docs/theory.md section 7.
func (c Corpus) InputHash(path StorePath) (Sha256Hex, bool) {
	memo := map[StorePath]Sha256Hex{}
	return c.inputHash(path, memo)
}

func (c Corpus) inputHash(path StorePath, memo map[StorePath]Sha256Hex) (Sha256Hex, bool) {
	if h, ok := memo[path]; ok {
		return h, true
	}
	d, ok := c.Drvs[path]
	if !ok {
		return "", false
	}
	var hash Sha256Hex
	if fixed, isFixed := d.FixedOutput(); isFixed {
		hash = FixedOutputInputHash(fixed)
	} else {
		hash = SHA256Hex(UnparseWith(d, SerializeOptions{
			InputHashes: c.inputHashesOf(d, memo),
		}))
	}
	memo[path] = hash
	return hash, true
}

func (c Corpus) inputHashesOf(d Derivation, memo map[StorePath]Sha256Hex) map[StorePath]string {
	out := map[StorePath]string{}
	for _, i := range d.InputDrvs {
		if h, ok := c.inputHash(i.Path, memo); ok {
			out[i.Path] = string(h)
		}
	}
	return out
}

// OutputPathsOf recomputes every output path of one derivation in this corpus.
func (c Corpus) OutputPathsOf(path StorePath) (map[OutputName]StorePath, bool) {
	d, ok := c.Drvs[path]
	if !ok {
		return nil, false
	}
	memo := map[StorePath]Sha256Hex{}
	return OutputPaths(d, NameFromPath(path, &d), c.inputHashesOf(d, memo)), true
}

// Verify recomputes every output path and compares with the recorded one.
//
// Returns the number of outputs checked and every mismatch. These are real
// derivations produced by real Nix, so this is a regression test against
// vectors nobody wrote by hand.
func (c Corpus) Verify() (int, []Mismatch) {
	checked := 0
	bad := []Mismatch{}
	// One memo table for the whole corpus, not one per derivation: sharing is
	// what makes this linear in edges.
	memo := map[StorePath]Sha256Hex{}
	for _, path := range c.Paths() {
		d := c.Drvs[path]
		name := NameFromPath(path, &d)
		got := OutputPaths(d, name, c.inputHashesOf(d, memo))
		for _, o := range d.Outputs {
			checked++
			if got[o.Name] != o.Path {
				bad = append(bad, Mismatch{
					DrvName:  name,
					Output:   o.Name,
					Expected: o.Path,
					Got:      got[o.Name],
				})
			}
		}
	}
	return checked, bad
}
