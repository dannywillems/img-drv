# Real nixpkgs `lib`, evaluated by us.
#
# Not a probe we wrote: `lib` is tens of thousands of lines of Nix that nobody
# here designed, written by people who use every corner of the language. It is
# the first input to this evaluator that was not chosen to be evaluable.
#
# Each attribute below is a lib function applied to real input and coerced into
# a derivation attribute, so the gate is again the store path rather than the
# value.
let
  lib = import <nixpkgs/lib>;
in
derivation {
  name = "lib-probe";
  system = "x86_64-linux";
  builder = "/bin/sh";
  args = [ "-c" "true" ];

  # Strings.
  upper = lib.toUpper "abc";
  esc = lib.escapeShellArg "a b'c";
  joined = lib.concatStringsSep ":" [ "a" "b" ];
  mapped = lib.concatMapStringsSep "," (x: "<${x}>") [ "p" "q" ];
  padded = lib.fixedWidthString 6 "0" "42";

  # Lists.
  uniq = toString (lib.unique [ 1 2 2 3 1 ]);
  flat = toString (lib.flatten [ 1 [ 2 [ 3 ] ] ]);
  ranged = toString (lib.range 1 5);
  last = toString (lib.last [ 1 2 3 ]);
  parted = toString (lib.partition (x: x > 2) [ 1 2 3 4 ]).right;

  # Attribute sets.
  names = lib.concatStringsSep "," (lib.attrNames { b = 1; a = 2; });
  recursed = toString (lib.recursiveUpdate { a.b = 1; } { a.c = 2; }).a.c;
  filtered = lib.concatStringsSep "," (
    lib.attrNames (lib.filterAttrs (n: _: n != "drop") { keep = 1; drop = 2; })
  );

  # The fixed point, which is what makes overlays work.
  fixed = toString (lib.fix (self: { a = 1; b = self.a + 1; })).b;

  # Booleans and versions.
  ver = toString (lib.versionAtLeast "2.5" "2.4");
  opt = lib.optionalString true "yes" + lib.optionalString false "no";
}
