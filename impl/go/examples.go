package imgdrv

import "fmt"

// The conformance corpus: intents, and the bytes real Nix produced for them.
//
// This is the language-independent set PLAN.md phase 2 asks for. Each entry is
// an INTENT expressed through the eDSL, paired with the name of the golden file
// in docs/spec/examples/ that real Nix emitted for the same intent.
//
// It lives in the library rather than in the tests because three things consume
// it: the test suite, the examples CLI command, and make conformance.
//
// These are the SAME ten intents as img_drv.examples in Python and
// img_drv::examples in Rust, transcribed rather than shared, because there is
// nothing to share them THROUGH: that is exactly the claim under test.

// ExampleSystem is the platform every example targets, so the corpus is
// comparable across machines: a derivation's store path depends on its system.
const ExampleSystem = "x86_64-linux"

// ExampleBuilder is the builder every example runs.
const ExampleBuilder = "/bin/sh"

func exampleBase(name string) Build {
	return Build{Name: name, System: ExampleSystem, Builder: ExampleBuilder}
}

func exampleEcho(name, word string) Drv {
	b := exampleBase(name)
	b.Args = []string{"-c", fmt.Sprintf("echo %s > $out", word)}
	return MustDerive(b)
}

// ExampleHello is the smallest real derivation: one output, no dependencies.
func ExampleHello() Drv { return exampleEcho("hello", "hi") }

// ExampleAaa is one of three leaves exercising multi-entry inputDrvs.
func ExampleAaa() Drv { return exampleEcho("aaa", "aaa") }

// ExampleMmm is one of three leaves exercising multi-entry inputDrvs.
func ExampleMmm() Drv { return exampleEcho("mmm", "mmm") }

// ExampleZzz is one of three leaves exercising multi-entry inputDrvs.
func ExampleZzz() Drv { return exampleEcho("zzz", "zzz") }

// ExampleDepA is the dependency of ExampleDependent.
func ExampleDepA() Drv { return exampleEcho("dep-a", "a") }

// ExampleDependent has one edge, which pins the mask/do-not-mask asymmetry.
func ExampleDependent() Drv {
	a := ExampleDepA()
	b := exampleBase("dependent")
	b.Args = []string{"-c", fmt.Sprintf("cat %s > $out", a.MustOutput("out"))}
	b.InputDrvs = []Dep{a.MustNeed()}
	return MustDerive(b)
}

// ExampleMany has three edges, named in an order that is NOT their store-path
// order. That is what makes this example evidence: inputDrvs has to come out
// sorted by path regardless of the order the caller used them in.
func ExampleMany() Drv {
	a, m, z := ExampleAaa(), ExampleMmm(), ExampleZzz()
	b := exampleBase("many")
	b.Args = []string{"-c", fmt.Sprintf("cat %s %s %s > $out",
		z.MustOutput("out"), a.MustOutput("out"), m.MustOutput("out"))}
	b.InputDrvs = []Dep{z.MustNeed(), a.MustNeed(), m.MustNeed()}
	return MustDerive(b)
}

// ExampleOrdering declares env out of order, to pin that env is sorted by key.
func ExampleOrdering() Drv {
	b := exampleBase("ordering")
	b.Env = map[string]JSONValue{
		"zzz": Str("last-declared-first"),
		"aaa": Str("first"),
		"mmm": Str("middle"),
	}
	return MustDerive(b)
}

// ExampleMulti has three outputs, carrying TWO orderings of the same list.
func ExampleMulti() Drv {
	b := exampleBase("multi")
	b.Outputs = Declare("out", "dev", "lib")
	return MustDerive(b)
}

// ExampleFixed is a fixed-output derivation with the hash written in base-32.
//
// The outputs tuple must carry it re-encoded as hex while the env keeps it
// exactly as written, which is the rule an implementation is most likely to get
// wrong.
func ExampleFixed() Drv {
	b := exampleBase("fixed")
	zeros := ""
	for i := 0; i < 52; i++ {
		zeros += "0"
	}
	b.FixedOutput = &FixedOutput{Hash: zeros, Algo: SHA256}
	return MustDerive(b)
}

// ExampleStructured is __structuredAttrs: attributes as JSON, with their types
// preserved.
//
// The flat encoding can only carry strings, so a boolean, an integer, a list or
// a nested attribute set has to be flattened and re-parsed by the builder. This
// one keeps them. 1223 of 2516 real derivations use it.
//
// It also exercises the same two-orderings rule as ExampleMulti: the outputs
// tuple comes out sorted (dev, out) while outputs inside the JSON keeps
// declaration order (out, dev).
func ExampleStructured() Drv {
	b := exampleBase("structured")
	b.Args = []string{"-c", "echo hi > $out"}
	b.Outputs = Declare("out", "dev")
	b.StructuredAttrs = true
	b.Env = map[string]JSONValue{
		"aFlag":   Bool(true),
		"aNumber": Int(42),
		"aList":   Strings("x", "y"),
		"nested": Object(map[string]JSONValue{
			"deep": Object(map[string]JSONValue{"deeper": Str("value")}),
		}),
		"aString": Str("plain"),
	}
	return MustDerive(b)
}

// CorpusEntry pairs a golden file name with the intent that must reproduce it.
type CorpusEntry struct {
	File string
	Drv  Drv
}

// ExampleCorpus is every golden file, and the intent that must reproduce it
// byte for byte.
func ExampleCorpus() []CorpusEntry {
	return []CorpusEntry{
		{"sb07z720914wba188q8vzq7jnx4596xp-dependent.drv", ExampleDependent()},
		{"3k9aahbip0dn0kb9m6i20sr2mjfmzsij-aaa.drv", ExampleAaa()},
		{"6hjg3xda34qvj2vpw27girg51gpdyd19-fixed.drv", ExampleFixed()},
		{"76w21n1f03fs5kw8fnffphx7qrqffw6r-hello.drv", ExampleHello()},
		{"7v25018h9x5nc7sc0sv57ghaq2qa0j9n-zzz.drv", ExampleZzz()},
		{"5x04ng0y0kgnkp3kyah1ziwlyj107q8m-many.drv", ExampleMany()},
		{"k1lc1y192xiajlyy4zvsdnfprnjx32i3-dep-a.drv", ExampleDepA()},
		{"mfdcxzh0v906c5hngb3x0b7sjl130hpk-ordering.drv", ExampleOrdering()},
		{"sqgix69fbs6hjh5kmf2pb1zvfmi5d0am-structured.drv", ExampleStructured()},
		{"v27a425rg4n7prwzpyyw0y1fw2ssc46f-multi.drv", ExampleMulti()},
		{"vk8wqbqg3k8w4134kwa0392kbc1953aq-mmm.drv", ExampleMmm()},
	}
}

// The DIFFERENTIAL probe, described through the eDSL.
//
// scripts/probe.nix is instantiated by the pinned Nix on every run, and until
// now only our PATH COMPUTATION was checked against the result: parse what Nix
// emitted, recompute the paths, compare. The eDSL itself was checked only
// against the golden files, which are checked in and therefore frozen.
//
// Describing the same five derivations here makes make differential a LIVE
// oracle for the eDSL too: our bytes against bytes a real nix-instantiate
// produced moments earlier, rather than against a file someone committed. A
// frozen golden cannot notice the ORACLE moving; this can.

// exampleNasty is the characters that defeat naive pattern matching, exactly as
// the probe writes them.
//
// No trailing newline: the probe writes this as a ONE-LINE indented string, and
// one that does not end in a newline does not gain one. Adding it was the first
// thing the live oracle caught.
const exampleNasty = "a \"quoted\" \\ backslash, a ],[ sequence, and a tab:\tdone"

func repeatChar(c byte, n int) string {
	out := make([]byte, n)
	for i := range out {
		out[i] = c
	}
	return string(out)
}

// ProbeFetched is fixed-output with FLAT ingestion: the fixed:out: scheme.
func ProbeFetched() Drv {
	b := exampleBase("fetched")
	b.Args = []string{"-c", "echo hi > $out"}
	b.FixedOutput = &FixedOutput{Hash: repeatChar('0', 64), Algo: SHA256}
	return MustDerive(b)
}

// ProbeFetchedRec is fixed-output with RECURSIVE ingestion: the source kind.
//
// The declared hash is used DIRECTLY as the inner hash rather than wrapped in a
// fingerprint. Missing this costs exactly one path in a real closure, which is
// how it survived a hand-written corpus.
func ProbeFetchedRec() Drv {
	b := exampleBase("fetched-rec")
	b.Args = []string{"-c", "mkdir $out"}
	b.FixedOutput = &FixedOutput{
		Hash: repeatChar('1', 64), Algo: SHA256, Mode: Recursive,
	}
	return MustDerive(b)
}

// Probe has four input edges covering every scheme above, plus the awkward
// cases: several outputs, env out of order, and a value full of metacharacters.
func Probe() Drv {
	dep, dep2 := exampleEcho("dep-a", "a"), exampleEcho("dep-b", "b")
	fetched, fetchedRec := ProbeFetched(), ProbeFetchedRec()
	b := exampleBase("probe")
	b.Args = []string{"-c", fmt.Sprintf("cat %s %s %s %s > $out",
		dep.MustOutput("out"), dep2.MustOutput("out"),
		fetched.MustOutput("out"), fetchedRec.MustOutput("out"))}
	b.InputDrvs = []Dep{
		dep.MustNeed(), dep2.MustNeed(), fetched.MustNeed(), fetchedRec.MustNeed(),
	}
	b.Outputs = Declare("out", "dev", "lib")
	b.Env = map[string]JSONValue{
		"zzz":   Str("last"),
		"aaa":   Str("first"),
		"mmm":   Str("middle"),
		"nasty": Str(exampleNasty),
	}
	return MustDerive(b)
}

// ProbeCorpus is every derivation the probe closure contains.
func ProbeCorpus() []Drv {
	return []Drv{
		exampleEcho("dep-a", "a"),
		exampleEcho("dep-b", "b"),
		ProbeFetched(),
		ProbeFetchedRec(),
		Probe(),
	}
}
