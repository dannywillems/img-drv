package nix

// A real package, through a real overlay, against real nixpkgs.
//
// The eleven conformance intents are derivations nobody would write: no
// dependencies, no stdenv, no composition. They pin the SERIALIZATION. This
// pins the SURFACE, which is where the project's claim actually lives and
// which had the least evidence behind it.
//
// What it exercises that the intents do not: stdenv.mkDerivation, a dependency
// taken from nixpkgs, a value that arrived through an overlay and is
// interpolated into a build phase, and a fixed point tying the overlay's knot.
// Every one of those is something a user would write on their first day and
// none appears in the corpus.
//
// The check is scripts/worked-example.sh: this term and the hand-written
// docs/spec/examples/worked-example.nix must instantiate to the SAME store
// path. Textual similarity is neither expected nor meaningful; the .drv is the
// normal form, for the same reason the round-trip law lives there.

func workedBase() Expr {
	return Attrs(P("greeting", S("hello")), P("version", S("1.0")))
}

// bump raises the version and derives a value from final.
//
// Reading final is what forces the knot to be tied: an overlay that only ever
// looked at prev would evaluate under a plain // and would not test Fix at all.
func bump(final, prev Expr) Expr {
	return Attrs(
		P("version", S("2.0")),
		P("banner", IStr(Sel(prev, "greeting"), " v", Sel(final, "version"))),
	)
}

// WorkedExample builds the term, from a reset name supply so output is stable.
func WorkedExample() Expr {
	Reset()
	return LetIn("pkgs", App(V("import"), SPath("nixpkgs"), Attrs()),
		func(pkgs Expr) Expr {
			return LetIn("final", Fix(workedBase(), bump), func(final Expr) Expr {
				return App(Sel(pkgs, "stdenv", "mkDerivation"), Attrs(
					P("pname", S("img-drv-worked-example")),
					P("version", Sel(final, "version")),
					P("dontUnpack", B(true)),
					P("nativeBuildInputs", L(Sel(pkgs, "hello"))),
					P("buildPhase", IStr("echo ", Sel(final, "banner"), " > out.txt")),
					P("installPhase",
						S("mkdir -p $out/share && cp out.txt $out/share/")),
				))
			})
		})
}
