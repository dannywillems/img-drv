package imgdrv

import (
	"encoding/base64"
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// The eDSL, checked against derivations real Nix actually emitted.
//
// The test that matters is not "does it build a plausible record". It is:
// DESCRIBE the same intent that produced a golden file, and demand the same
// bytes, including the derivation's own store path.
//
// These are the SAME ten intents as the Python and Rust suites. That is the
// point: three languages, one set of bytes.

func TestEveryGoldenFileHasAnIntent(t *testing.T) {
	// A golden nobody describes is a rule nobody is testing.
	onDisk := []string{}
	for _, p := range goldenFiles(t) {
		onDisk = append(onDisk, filepath.Base(p))
	}
	described := []string{}
	for _, e := range ExampleCorpus() {
		described = append(described, e.File)
	}
	sort.Strings(onDisk)
	sort.Strings(described)
	if !equalSlice(onDisk, described) {
		t.Errorf("on disk %v\ndescribed %v", onDisk, described)
	}
}

func TestDescribingTheIntentReproducesNixByteForByte(t *testing.T) {
	// The exit test of Phase 1, in miniature. Structural equality would not do:
	// the bytes are hashed to produce the derivation's own store path.
	for _, e := range ExampleCorpus() {
		t.Run(e.File, func(t *testing.T) {
			want := readGolden(t, filepath.Join(goldenDir, e.File))
			if got := e.Drv.ATerm(); got != want {
				t.Errorf("bytes differ\n got %s\nwant %s", got, want)
			}
		})
	}
}

func TestTheDerivationLandsAtItsOwnStorePath(t *testing.T) {
	// Reproducing the CONTENT while computing the wrong path would mean the
	// text-kind store path rule is wrong, which nothing else here would catch.
	for _, e := range ExampleCorpus() {
		t.Run(e.File, func(t *testing.T) {
			base := string(e.Drv.Path())
			base = base[strings.LastIndex(base, "/")+1:]
			if base != e.File {
				t.Errorf("landed at %s, want %s", base, e.File)
			}
		})
	}
}

func TestOutputPathsAreKnownBeforeAnythingIsBuilt(t *testing.T) {
	want := StorePath("/nix/store/mjs27ix6ig2bkbi3s3sm470vrv4lf7ic-hello")
	if got := ExampleHello().MustOutput("out"); got != want {
		t.Errorf("got %s, want %s", got, want)
	}
	multi := ExampleMulti()
	if !strings.HasSuffix(string(multi.MustOutput("dev")), "-multi-dev") {
		t.Errorf("dev output not suffixed: %s", multi.MustOutput("dev"))
	}
	if !strings.HasSuffix(string(multi.MustOutput("out")), "-multi") {
		t.Errorf("out output suffixed: %s", multi.MustOutput("out"))
	}
}

func TestADependentAgreesWithWhatItDependsOn(t *testing.T) {
	a := ExampleDepA()
	d := ExampleDependent()
	edges := d.Derivation().InputDrvs
	if len(edges) != 1 || edges[0].Path != a.Path() {
		t.Fatalf("edges %v, want one pointing at %s", edges, a.Path())
	}
	if !strings.Contains(d.Derivation().Args[1], string(a.MustOutput("out"))) {
		t.Error("args do not reference the dependency's output")
	}
}

// --------------------------------------------------------------------------
// outputs is an OPTION, and both cases occur in real nixpkgs
// --------------------------------------------------------------------------

func TestDeclaringOutputsIsObservableInTheBytes(t *testing.T) {
	// A bare `derivation { ... }` emits no outputs env variable; a package that
	// writes outputs = [ "out" ] emits ("outputs","out"). 96 of the corpus's
	// single-output derivations do the first and 605 do the second.
	implicit := MustDerive(Build{Name: "x", System: ExampleSystem, Builder: ExampleBuilder})
	explicit := MustDerive(Build{
		Name: "x", System: ExampleSystem, Builder: ExampleBuilder,
		Outputs: Declare("out"),
	})
	if strings.Contains(implicit.ATerm(), `("outputs"`) {
		t.Error("implicit outputs emitted an outputs env variable")
	}
	if !strings.Contains(explicit.ATerm(), `("outputs","out")`) {
		t.Error("declared outputs did not emit an outputs env variable")
	}
	if implicit.Path() == explicit.Path() {
		t.Error("Implicit() and Declare(\"out\") produced the same derivation")
	}
	if implicit.MustOutput("out") == explicit.MustOutput("out") {
		t.Error("Implicit() and Declare(\"out\") produced the same output path")
	}
}

func TestTheOutputsVariableKeepsDeclarationOrder(t *testing.T) {
	// The outputs LIST is sorted by name; the outputs env VARIABLE is in
	// declaration order. They differ in 575 of the 1197 real derivations that
	// declare outputs.
	d := ExampleMulti().Derivation()
	names := []string{}
	for _, o := range d.Outputs {
		names = append(names, string(o.Name))
	}
	if !equalSlice(names, []string{"dev", "lib", "out"}) {
		t.Errorf("outputs list %v, want sorted", names)
	}
	for _, e := range d.Env {
		if e.Key == "outputs" && e.Value != "out dev lib" {
			t.Errorf("outputs env %q, want declaration order", e.Value)
		}
	}
}

// --------------------------------------------------------------------------
// fixed-output derivations
// --------------------------------------------------------------------------

func testDigest() []byte {
	d := make([]byte, 32)
	for i := range d {
		d[i] = byte(i)
	}
	return d
}

func sri(digest []byte) string {
	return "sha256-" + base64.StdEncoding.EncodeToString(digest)
}

func TestAHashIsAcceptedInEveryRepresentationNixWrites(t *testing.T) {
	digest := testDigest()
	want := hex.EncodeToString(digest)
	forms := []FixedOutput{
		{Hash: want, Algo: SHA256},
		{Hash: Base32(digest), Algo: SHA256},
		{Hash: sri(digest)},
	}
	for _, f := range forms {
		_, got, err := f.Resolve()
		if err != nil {
			t.Fatalf("%q: %v", f.Hash, err)
		}
		if got != want {
			t.Errorf("%q resolved to %s, want %s", f.Hash, got, want)
		}
	}
}

func TestTheOutputPathDoesNotDependOnHowTheHashWasWritten(t *testing.T) {
	// Why every fetchurl in nixpkgs can share one cache entry. The .drv path is
	// NOT representation-independent, because the env keeps the hash verbatim.
	digest := testDigest()
	build := func(f FixedOutput) Drv {
		return MustDerive(Build{
			Name: "fetched", System: ExampleSystem, Builder: ExampleBuilder,
			FixedOutput: &f,
		})
	}
	asHex := build(FixedOutput{Hash: hex.EncodeToString(digest), Algo: SHA256})
	asSRI := build(FixedOutput{Hash: sri(digest)})
	if asHex.MustOutput("out") != asSRI.MustOutput("out") {
		t.Error("output path depends on the hash's spelling")
	}
	if asHex.Path() == asSRI.Path() {
		t.Error("two different derivations collided on one .drv path")
	}
}

func TestRecursiveIngestionTakesADifferentPathScheme(t *testing.T) {
	// r:sha256 is the source kind with the declared hash used directly. Exactly
	// one derivation in a 226-derivation closure exercised this.
	digest := hex.EncodeToString(testDigest())
	flat := MustDerive(Build{
		Name: "f", System: ExampleSystem, Builder: ExampleBuilder,
		FixedOutput: &FixedOutput{Hash: digest, Algo: SHA256},
	})
	rec := MustDerive(Build{
		Name: "f", System: ExampleSystem, Builder: ExampleBuilder,
		FixedOutput: &FixedOutput{Hash: digest, Algo: SHA256, Mode: Recursive},
	})
	if !strings.Contains(rec.ATerm(), `"r:sha256"`) {
		t.Error("recursive mode did not prefix the algorithm")
	}
	if !strings.Contains(rec.ATerm(), `("outputHashMode","recursive")`) {
		t.Error("recursive mode not recorded in env")
	}
	if flat.MustOutput("out") == rec.MustOutput("out") {
		t.Error("flat and recursive produced the same output path")
	}
}

func TestAnSRIHashEmitsNoOutputHashAlgo(t *testing.T) {
	// 11 of the 93 real fixed-output derivations omit it; matching matters.
	d := MustDerive(Build{
		Name: "f", System: ExampleSystem, Builder: ExampleBuilder,
		FixedOutput: &FixedOutput{Hash: sri(make([]byte, 32))},
	})
	if strings.Contains(d.ATerm(), "outputHashAlgo") {
		t.Error("an SRI hash emitted outputHashAlgo")
	}
}

func TestAnInvalidAlgorithmIsOnlyCaughtAtRuntime(t *testing.T) {
	// FINDING, and the whole reason Go is the falsification test. HashAlgo is a
	// defined string type, so this line COMPILES; in Rust the equivalent does
	// not, and in Python mypy rejects it. The runtime check below is the
	// compensation, and it is the cost being measured.
	f := FixedOutput{Hash: strings.Repeat("0", 64), Algo: HashAlgo("sha3")}
	if _, _, err := f.Resolve(); !errors.Is(err, ErrHash) {
		t.Errorf("HashAlgo(\"sha3\") was accepted: %v", err)
	}
}

// --------------------------------------------------------------------------
// invariants from spec/signature.md, enforced at construction
// --------------------------------------------------------------------------

func TestInvalidDescriptionsAreRejectedAtConstruction(t *testing.T) {
	base := func() Build {
		return Build{Name: "x", System: ExampleSystem, Builder: ExampleBuilder}
	}
	cases := []struct {
		why   string
		build func() Build
		want  error
	}{
		{"empty outputs", func() Build {
			b := base()
			b.Outputs = Outputs{Declared: true, Names: []OutputName{}}
			return b
		}, ErrEmptyOutputs},
		{"duplicate outputs", func() Build {
			b := base()
			b.Outputs = Declare("out", "out")
			return b
		}, ErrDuplicateOutputs},
		{"fixed with several outputs", func() Build {
			b := base()
			b.Outputs = Declare("out", "dev")
			b.FixedOutput = &FixedOutput{Hash: strings.Repeat("0", 64), Algo: SHA256}
			return b
		}, ErrFixedNeedsOneOutput},
	}
	for _, c := range cases {
		t.Run(c.why, func(t *testing.T) {
			if _, err := Derive(c.build()); !errors.Is(err, c.want) {
				t.Errorf("got %v, want %v", err, c.want)
			}
		})
	}
	for _, key := range []string{"name", "out", "outputHash", "system", "builder", "outputs"} {
		t.Run("reserved "+key, func(t *testing.T) {
			b := base()
			b.Env = map[string]JSONValue{key: Str("x")}
			if _, err := Derive(b); !errors.Is(err, ErrReservedEnvKey) {
				t.Errorf("%q was accepted: %v", key, err)
			}
		})
	}
}

func TestInvalidNamesAreRejected(t *testing.T) {
	for _, bad := range []string{"", ".", "..", ".hidden", "a b", "a/b", strings.Repeat("x", 212)} {
		if ValidName(bad) {
			t.Errorf("%q accepted", bad)
		}
		_, err := Derive(Build{Name: bad, System: ExampleSystem, Builder: ExampleBuilder})
		if !errors.Is(err, ErrInvalidName) {
			t.Errorf("%q: got %v", bad, err)
		}
	}
}

func TestNamesRealPackagesUseAreAccepted(t *testing.T) {
	for _, good := range []string{"hello", "hello-1.0", "a+b", "x_y", "q?", "n=1", strings.Repeat("x", 211)} {
		if !ValidName(good) {
			t.Errorf("%q rejected", good)
		}
	}
}

func TestAskingForAnOutputThatDoesNotExistFails(t *testing.T) {
	if _, err := ExampleHello().Output("dev"); !errors.Is(err, ErrNoSuchOutput) {
		t.Errorf("got %v", err)
	}
	if _, err := ExampleHello().Needs("dev"); !errors.Is(err, ErrNoSuchOutput) {
		t.Errorf("got %v", err)
	}
}

func TestOneEdgePerDependencyHoweverOftenItIsNamed(t *testing.T) {
	m := ExampleMulti()
	d := MustDerive(Build{
		Name: "user", System: ExampleSystem, Builder: ExampleBuilder,
		InputDrvs: []Dep{m.MustNeed("dev"), m.MustNeed("lib"), m.MustNeed("dev")},
	})
	edges := d.Derivation().InputDrvs
	if len(edges) != 1 {
		t.Fatalf("got %d edges, want 1", len(edges))
	}
	if !equalSlice(edges[0].Outputs, []OutputName{"dev", "lib"}) {
		t.Errorf("outputs %v, want [dev lib]", edges[0].Outputs)
	}
}

func TestWhatTheEDSLBuildsIsCanonical(t *testing.T) {
	for _, e := range ExampleCorpus() {
		t.Run(e.File, func(t *testing.T) {
			d := e.Drv.Derivation()
			if !Canonical(d).Equal(d) {
				t.Error("the eDSL emitted a non-canonical derivation")
			}
		})
	}
}

func TestWriteProducesTheStoreFilename(t *testing.T) {
	dir := t.TempDir()
	written, err := ExampleHello().Write(dir)
	if err != nil {
		t.Fatalf("write: %v", err)
	}
	raw, err := os.ReadFile(written)
	if err != nil {
		t.Fatalf("read back: %v", err)
	}
	if string(raw) != ExampleHello().ATerm() {
		t.Error("written bytes differ from ATerm()")
	}
	if strings.HasSuffix(string(raw), "\n") {
		t.Error("a trailing newline was written; the store object has none")
	}
}
