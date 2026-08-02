package imgdrv

import (
	"encoding/base64"
	"encoding/hex"
	"math/rand"
	"reflect"
	"testing"
	"testing/quick"
)

// The eDSL's laws, as property tests over generated intents.
//
// These are the SAME laws as impl/python/tests/test_edsl_laws.py and
// impl/rust/tests/laws.rs, which is the point: a law is a property of the
// SPECIFICATION, so it ports rather than being rewritten.
//
// FINDING. The generator is stdlib testing/quick, which is what go.md asks for
// before reaching for a dependency. Two costs, both real and both worth
// recording rather than hiding:
//
//   - Generate has signature (rand, size) reflect.Value, so the one place this
//     implementation touches runtime typing is its PROPERTY TESTS. There is no
//     typed generator interface in the standard library.
//   - quick does not SHRINK. A failure reports whatever 40-field value happened
//     to break, not the smallest one, so a real failure here is materially
//     harder to read than the same failure in Hypothesis or proptest.
//
// The seed is pinned. A property test with an unpinned seed is not reproducible,
// which in a project about reproducibility would be an odd thing to ship.

const lawSeed = 20260802

func lawConfig() *quick.Config {
	return &quick.Config{
		MaxCount: 200,
		Rand:     rand.New(rand.NewSource(lawSeed)),
	}
}

func check(t *testing.T, law any) {
	t.Helper()
	if err := quick.Check(law, lawConfig()); err != nil {
		t.Error(err)
	}
}

// --------------------------------------------------------------------------
// generators
// --------------------------------------------------------------------------

const nameAlphabet = "abcdefghijklmnopqrstuvwxyz0123456789+-._?="

// genName builds a valid store name by CONSTRUCTION rather than by filtering.
func genName(rnd *rand.Rand) string {
	out := []byte{byte('a' + rnd.Intn(26))}
	for i := rnd.Intn(8); i > 0; i-- {
		out = append(out, nameAlphabet[rnd.Intn(len(nameAlphabet))])
	}
	return string(out)
}

// nastyRunes are the five escaped characters, a control character that must NOT
// be escaped, and the `],[` sequence that defeats pattern matching.
var nastyRunes = []rune{'"', '\\', '\n', '\r', '\t', '\x07', ']', '[', ',', '/'}

func genValue(rnd *rand.Rand) string {
	out := []rune{}
	for i := rnd.Intn(10); i > 0; i-- {
		if rnd.Intn(5) == 0 {
			out = append(out, rune(rnd.Intn(0x2000)+1))
		} else {
			out = append(out, nastyRunes[rnd.Intn(len(nastyRunes))])
		}
	}
	return string(out)
}

func genFixed(rnd *rand.Rand) *FixedOutput {
	digest := make([]byte, 32)
	rnd.Read(digest)
	var f FixedOutput
	switch rnd.Intn(3) {
	case 0:
		f = FixedOutput{Hash: hex.EncodeToString(digest), Algo: SHA256}
	case 1:
		f = FixedOutput{Hash: Base32(digest), Algo: SHA256}
	default:
		f = FixedOutput{Hash: "sha256-" + base64.StdEncoding.EncodeToString(digest)}
	}
	if rnd.Intn(2) == 0 {
		f.Mode = Recursive
	}
	return &f
}

// Intent is a build description, held apart from the call that realises it.
//
// Keeping the intent as a value is what lets a law say "these two ways of
// writing the same thing must serialize identically".
type Intent struct {
	Name    string
	System  string
	Builder string
	Args    []string
	Env     map[string]string
	Outputs Outputs
	Fixed   *FixedOutput
}

// Generate implements quick.Generator.
func (Intent) Generate(rnd *rand.Rand, _ int) reflect.Value {
	i := Intent{
		Name:    genName(rnd),
		System:  genValue(rnd),
		Builder: genValue(rnd),
		Env:     map[string]string{},
	}
	for n := rnd.Intn(3); n > 0; n-- {
		i.Args = append(i.Args, genValue(rnd))
	}
	if rnd.Intn(2) == 0 {
		names := []OutputName{}
		for n := rnd.Intn(3) + 1; n > 0; n-- {
			names = append(names, OutputName(genName(rnd)))
		}
		i.Outputs = Declare(dedupe(names)...)
	}
	names := i.Outputs.names()
	if len(names) == 1 && rnd.Intn(2) == 0 {
		i.Fixed = genFixed(rnd)
	}
	// Reserved keys are rejected at construction by design, so a collision is
	// DROPPED here rather than filtered for.
	blocked := map[string]bool{}
	for _, k := range reserved {
		blocked[k] = true
	}
	for _, n := range names {
		blocked[string(n)] = true
	}
	for n := rnd.Intn(5); n > 0; n-- {
		k := genName(rnd)
		if !blocked[k] {
			i.Env[k] = genValue(rnd)
		}
	}
	return reflect.ValueOf(i)
}

func (i Intent) build(deps ...Dep) Drv {
	return MustDerive(Build{
		Name:    i.Name,
		System:  i.System,
		Builder: i.Builder,
		Args:    i.Args,
		Env: func() map[string]JSONValue {
			out := map[string]JSONValue{}
			for k, v := range i.Env {
				out[k] = Str(v)
			}
			return out
		}(),
		Outputs:     i.Outputs,
		InputDrvs:   deps,
		FixedOutput: i.Fixed,
	})
}

// edge depends on an output the target actually has.
//
// The no-argument shorthand means "I need out", which most derivations have and
// a generated one need not.
func edge(d Drv) Dep {
	first := d.Derivation().Outputs[0].Name
	return d.MustNeed(first)
}

// --------------------------------------------------------------------------
// laws
// --------------------------------------------------------------------------

// TestDescribingTheSameIntentTwiceGivesTheSameBytes checks that serialization
// is a FUNCTION, not a process.
//
// FINDING. This law is nearly vacuous in Python and Rust, where dict and
// BTreeMap have a stable order even if you forget to sort before serializing.
// Go RANDOMISES map iteration on purpose, so here the same law is a real test
// of canonicalization: an implementation that forgot to sort env would pass in
// the other two languages and fail loudly, if intermittently, in this one.
func TestDescribingTheSameIntentTwiceGivesTheSameBytes(t *testing.T) {
	check(t, func(i Intent) bool {
		a, b := i.build(), i.build()
		return a.ATerm() == b.ATerm() &&
			a.Path() == b.Path() &&
			a.InputHash() == b.InputHash()
	})
}

// TestDependencyOrderIsNotObservable checks that inputDrvs is a SET of edges.
//
// Listing dependencies in a different order is the same description; the .drv
// sorts them by store path.
func TestDependencyOrderIsNotObservable(t *testing.T) {
	check(t, func(a, b, c Intent) bool {
		x, y := edge(a.build()), edge(b.build())
		one, other := c.build(x, y), c.build(y, x)
		return one.ATerm() == other.ATerm() && one.Path() == other.Path()
	})
}

// TestNamingADependencyTwiceIsNamingItOnce checks that edges merge.
//
// Store paths are unique in inputDrvs in 1293 of 1293 real derivations, so a
// repeated reference cannot become a repeated entry.
func TestNamingADependencyTwiceIsNamingItOnce(t *testing.T) {
	check(t, func(i Intent) bool {
		dep := i.build()
		once := i.build(edge(dep))
		twice := i.build(edge(dep), edge(dep), edge(dep))
		return once.ATerm() == twice.ATerm()
	})
}

// TestWhatTheEDSLBuildsIsCanonicalLaw checks the eDSL emits a fixed point of
// the same normalizer real Nix output is a fixed point of.
func TestWhatTheEDSLBuildsIsCanonicalLaw(t *testing.T) {
	check(t, func(i Intent) bool {
		d := i.build().Derivation()
		return Canonical(d).Equal(d)
	})
}

// TestCanonicalIsIdempotent checks that a normal form applied twice is applied
// once.
func TestCanonicalIsIdempotent(t *testing.T) {
	check(t, func(i Intent) bool {
		d := Canonical(i.build().Derivation())
		return Canonical(d).Equal(d)
	})
}

// TestThePathIsTheHashOfTheBytes checks the store path is a function of the
// file content rather than metadata.
func TestThePathIsTheHashOfTheBytes(t *testing.T) {
	check(t, func(i Intent) bool {
		d := i.build()
		refs := []string{}
		for _, e := range d.Derivation().InputDrvs {
			refs = append(refs, string(e.Path))
		}
		return d.Path() == DrvPath(d.ATerm(), i.Name, refs)
	})
}

// TestWhatTheEDSLWritesTheParserReads checks the two halves are inverse on the
// eDSL's image.
//
// parse . unparse = id holds everywhere; unparse . parse = id holds only on
// CANONICAL text, which is exactly what the eDSL emits.
func TestWhatTheEDSLWritesTheParserReads(t *testing.T) {
	check(t, func(i Intent) bool {
		d := i.build()
		text := d.ATerm()
		read, err := Parse(text)
		return err == nil && read.Equal(d.Derivation()) && Unparse(read) == text
	})
}

// TestDeclaringOutputsIsObservable checks Implicit() and Declare("out") are
// different derivations, for every intent.
//
// Both forms occur in real nixpkgs, so an implementation that conflates them
// cannot reproduce one of them.
func TestDeclaringOutputsIsObservable(t *testing.T) {
	check(t, func(i Intent) bool {
		implicit, explicit := i, i
		implicit.Outputs = Implicit()
		implicit.Fixed = i.Fixed
		explicit.Outputs = Declare("out")
		explicit.Fixed = i.Fixed
		a, b := implicit.build(), explicit.build()
		return a.ATerm() != b.ATerm() && a.Path() != b.Path()
	})
}

// TestEveryOutputIsAnEnvVariableHoldingItsOwnPath checks invariant 6 of
// spec/signature.md for every intent rather than one.
func TestEveryOutputIsAnEnvVariableHoldingItsOwnPath(t *testing.T) {
	check(t, func(i Intent) bool {
		d := i.build()
		env := map[string]string{}
		for _, e := range d.Derivation().Env {
			env[e.Key] = e.Value
		}
		for name, path := range d.Outputs() {
			if env[string(name)] != string(path) {
				return false
			}
		}
		return true
	})
}

// TestTheInputHashIsNotTheSelfHash checks the asymmetry that cost this
// repository 145 downstream failures.
//
// A derivation's own path is computed from a form with its outputs MASKED; the
// hash by which it is known as someone's INPUT is not.
func TestTheInputHashIsNotTheSelfHash(t *testing.T) {
	check(t, func(i Intent) bool {
		d := i.build()
		masked := SHA256Hex(UnparseWith(d.Derivation(), SerializeOptions{MaskOutputs: true}))
		return d.InputHash() != masked
	})
}

// TestBase32DecodeInvertsBase32 checks an inverse, not an approximation of one.
func TestBase32DecodeInvertsBase32(t *testing.T) {
	check(t, func(data []byte) bool {
		if len(data) == 0 {
			return true
		}
		back, err := Base32Decode(Base32(data), len(data))
		return err == nil && equalSlice(back, data)
	})
}

// TestADigestMeansTheSameHoweverItIsWritten checks representation-independence,
// which is why fetchers share cache entries.
//
// Two fixed-output derivations declaring the same BYTES agree on the output
// path however differently the hash was spelled, while remaining
// distinguishable as files, because the env keeps the spelling verbatim.
func TestADigestMeansTheSameHoweverItIsWritten(t *testing.T) {
	check(t, func(digest [32]byte, recursive bool) bool {
		mode := Flat
		if recursive {
			mode = Recursive
		}
		spell := func(f FixedOutput) Drv {
			f.Mode = mode
			return MustDerive(Build{
				Name: "f", System: ExampleSystem, Builder: ExampleBuilder,
				FixedOutput: &f,
			})
		}
		drvs := []Drv{
			spell(FixedOutput{Hash: hex.EncodeToString(digest[:]), Algo: SHA256}),
			spell(FixedOutput{Hash: Base32(digest[:]), Algo: SHA256}),
			spell(FixedOutput{Hash: "sha256-" + base64.StdEncoding.EncodeToString(digest[:])}),
		}
		paths := map[StorePath]bool{}
		for _, d := range drvs {
			if d.MustOutput("out") != drvs[0].MustOutput("out") {
				return false
			}
			paths[d.Path()] = true
		}
		return len(paths) == 3
	})
}

// TestADescribedClosureVerifiesLikeARealOne describes a DAG, writes it out, and
// checks it the way nixpkgs is checked.
//
// The strongest law available without invoking Nix: the eDSL's output is handed
// to the same recursive path computation that reproduces 1259 of 1259 real
// output paths, reached by a different route.
func TestADescribedClosureVerifiesLikeARealOne(t *testing.T) {
	cfg := lawConfig()
	cfg.MaxCount = 40
	law := func(a, b, c Intent) bool {
		dir := t.TempDir()
		built := []Drv{a.build()}
		built = append(built, b.build(edge(built[0])))
		built = append(built, c.build(edge(built[0]), edge(built[1])))
		for _, d := range built {
			if _, err := d.Write(dir); err != nil {
				return false
			}
		}
		corpus, err := LoadCorpus(dir)
		if err != nil {
			return false
		}
		checked, mismatches := corpus.Verify()
		return checked >= 1 && len(mismatches) == 0
	}
	if err := quick.Check(law, cfg); err != nil {
		t.Error(err)
	}
}
