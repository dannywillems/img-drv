package nix

import (
	"fmt"
	"strings"
)

// The eleven conformance intents, written as Nix EXPRESSIONS in Go.
//
// The same intents as the parent package's Examples, expressed through the
// other arrow. There they are built directly as IR and serialized to .drv;
// here they are built as Nix syntax and printed as .nix, for real Nix to
// instantiate.
//
// That is the COMMUTING SQUARE of docs/architecture.md: both routes must end
// at the same bytes, and the bytes are already known to be right because
// make conformance pins them for four implementations.
//
// Note what a reader does NOT have to write: no store paths, no hashes, and
// for the dependent cases no explicit edge. Interpolating one derivation into
// another's arguments is what creates the dependency, via the string context
// described in docs/nix-internals.md. That is the mechanism the eDSLs
// deliberately do without, and having it back is the point of transpiling.

func system() Expr { return S("x86_64-linux") }

func sh() Expr { return S("/bin/sh") }

func drv(pairs ...Pair) Expr { return App(V("derivation"), Attrs(pairs...)) }

func echo(name, word string) Expr {
	return drv(
		P("name", S(name)),
		P("system", system()),
		P("builder", sh()),
		P("args", L(S("-c"), S(fmt.Sprintf("echo %s > $out", word)))),
	)
}

func hello() Expr { return echo("hello", "hi") }

func aaa() Expr { return echo("aaa", "aaa") }

func mmm() Expr { return echo("mmm", "mmm") }

func zzz() Expr { return echo("zzz", "zzz") }

func depA() Expr { return echo("dep-a", "a") }

// dependent's edge is IMPLICIT.
//
// ${a} carries a's drv path in its string context, so Nix adds the inputDrvs
// entry itself. Compare the eDSL, where the caller passes the dependency
// explicitly.
func dependent() Expr {
	return LetIn("a", depA(), func(a Expr) Expr {
		return drv(
			P("name", S("dependent")),
			P("system", system()),
			P("builder", sh()),
			P("args", L(S("-c"), IStr("cat ", a, " > $out"))),
		)
	})
}

func many() Expr {
	return LetIn("a", aaa(), func(a Expr) Expr {
		return LetIn("m", mmm(), func(m Expr) Expr {
			return LetIn("z", zzz(), func(z Expr) Expr {
				return drv(
					P("name", S("many")),
					P("system", system()),
					P("builder", sh()),
					P("args", L(
						S("-c"),
						IStr("cat ", z, " ", a, " ", m, " > $out"),
					)),
				)
			})
		})
	})
}

func ordering() Expr {
	return drv(
		P("name", S("ordering")),
		P("system", system()),
		P("builder", sh()),
		P("zzz", S("last-declared-first")),
		P("aaa", S("first")),
		P("mmm", S("middle")),
	)
}

func multi() Expr {
	return drv(
		P("name", S("multi")),
		P("system", system()),
		P("builder", sh()),
		P("outputs", L(S("out"), S("dev"), S("lib"))),
	)
}

func fixed() Expr {
	return drv(
		P("name", S("fixed")),
		P("system", system()),
		P("builder", sh()),
		P("outputHash", S(strings.Repeat("0", 52))),
		P("outputHashAlgo", S("sha256")),
		P("outputHashMode", S("flat")),
	)
}

func structured() Expr {
	return drv(
		P("name", S("structured")),
		P("system", system()),
		P("builder", sh()),
		P("args", L(S("-c"), S("echo hi > $out"))),
		P("__structuredAttrs", B(true)),
		P("outputs", L(S("out"), S("dev"))),
		P("aFlag", B(true)),
		P("aNumber", I(42)),
		P("aList", L(S("x"), S("y"))),
		P("nested", Attrs(P("deep", Attrs(P("deeper", S("value")))))),
		P("aString", S("plain")),
	)
}

// Named is a golden file name and the expression that must produce it through
// real Nix.
type Named struct {
	Name string
	Expr Expr
}

// Corpus builds every intent from a reset name supply, so output is stable.
func Corpus() []Named {
	Reset()
	return []Named{
		{"sb07z720914wba188q8vzq7jnx4596xp-dependent.drv", dependent()},
		{"3k9aahbip0dn0kb9m6i20sr2mjfmzsij-aaa.drv", aaa()},
		{"6hjg3xda34qvj2vpw27girg51gpdyd19-fixed.drv", fixed()},
		{"76w21n1f03fs5kw8fnffphx7qrqffw6r-hello.drv", hello()},
		{"7v25018h9x5nc7sc0sv57ghaq2qa0j9n-zzz.drv", zzz()},
		{"5x04ng0y0kgnkp3kyah1ziwlyj107q8m-many.drv", many()},
		{"k1lc1y192xiajlyy4zvsdnfprnjx32i3-dep-a.drv", depA()},
		{"mfdcxzh0v906c5hngb3x0b7sjl130hpk-ordering.drv", ordering()},
		{"sqgix69fbs6hjh5kmf2pb1zvfmi5d0am-structured.drv", structured()},
		{"v27a425rg4n7prwzpyyw0y1fw2ssc46f-multi.drv", multi()},
		{"vk8wqbqg3k8w4134kwa0392kbc1953aq-mmm.drv", mmm()},
	}
}
