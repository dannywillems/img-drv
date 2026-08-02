# A worked example: a real package, through a real overlay, against real nixpkgs.
#
# This is the HAND-WRITTEN reference. Each implementation's `surface` layer
# builds a term that must instantiate to the SAME store path, which is the only
# comparison that means anything: the two files are not textually similar and
# were never meant to be.
#
# Deliberately not a conformance intent. Those eleven are derivations nobody
# would write, with no dependencies, no stdenv and no composition. This one uses
# stdenv.mkDerivation, takes a dependency from nixpkgs, interpolates a value
# that came through an overlay, and closes the overlay with a fixed point. It is
# the first thing the surface has to survive that a user might actually write.
let
  pkgs = import <nixpkgs> { };

  base = {
    greeting = "hello";
    version = "1.0";
  };

  # An overlay is `final: prev: { ... }`. This one bumps the version and derives
  # a value from `final`, so the knot has to be tied for it to evaluate at all.
  bump = final: prev: {
    version = "2.0";
    banner = "${prev.greeting} v${final.version}";
  };

  final = base // (bump final base);
in
pkgs.stdenv.mkDerivation {
  pname = "img-drv-worked-example";
  version = final.version;
  dontUnpack = true;
  nativeBuildInputs = [ pkgs.hello ];
  buildPhase = "echo ${final.banner} > out.txt";
  installPhase = "mkdir -p $out/share && cp out.txt $out/share/";
}
