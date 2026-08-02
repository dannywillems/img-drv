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
	b.Env = map[string]string{
		"zzz": "last-declared-first", "aaa": "first", "mmm": "middle",
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

// CorpusEntry pairs a golden file name with the intent that must reproduce it.
type CorpusEntry struct {
	File string
	Drv  Drv
}

// ExampleCorpus is every golden file, and the intent that must reproduce it
// byte for byte.
func ExampleCorpus() []CorpusEntry {
	return []CorpusEntry{
		{"34h63y306vjiqi9974m0abrkp8aplgjq-dependent.drv", ExampleDependent()},
		{"3k9aahbip0dn0kb9m6i20sr2mjfmzsij-aaa.drv", ExampleAaa()},
		{"6hjg3xda34qvj2vpw27girg51gpdyd19-fixed.drv", ExampleFixed()},
		{"76w21n1f03fs5kw8fnffphx7qrqffw6r-hello.drv", ExampleHello()},
		{"7v25018h9x5nc7sc0sv57ghaq2qa0j9n-zzz.drv", ExampleZzz()},
		{"h3ik45ycljylpdzjssckqi3vvslsbxpn-many.drv", ExampleMany()},
		{"k1lc1y192xiajlyy4zvsdnfprnjx32i3-dep-a.drv", ExampleDepA()},
		{"mfdcxzh0v906c5hngb3x0b7sjl130hpk-ordering.drv", ExampleOrdering()},
		{"v27a425rg4n7prwzpyyw0y1fw2ssc46f-multi.drv", ExampleMulti()},
		{"vk8wqbqg3k8w4134kwa0392kbc1953aq-mmm.drv", ExampleMmm()},
	}
}
