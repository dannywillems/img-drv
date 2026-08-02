# Real nixpkgs `lib`, evaluated by us.
#
# Every other gate here runs on input this project wrote. This one runs on tens
# of thousands of lines of Nix that nobody here designed, using every corner of
# the language, and it is the first input to the evaluator that was not chosen
# to be evaluable. The parser learned the same lesson the same way
# (docs/abstractions.md entry 13): a curated corpus tells you about the curator.
#
# The gate is still bytes: each result feeds a derivation attribute, so a lib
# function that returns a subtly different string moves the store path.
#
# NOT here, and deliberately: lib.escapeShellArg and the other functions built
# on builtins.match. They need a POSIX ERE engine, which is a dependency and so
# an approval. See docs/decisions/ for the request.
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
  joined = lib.concatStringsSep ":" [ "a" "b" ];
  mapped = lib.concatMapStringsSep "," (x: "<${x}>") [ "p" "q" ];
  padded = lib.fixedWidthString 6 "0" "42";
  removed = lib.removePrefix "lib" "libfoo";

  # Lists.
  uniq = toString (lib.unique [ 1 2 2 3 1 ]);
  flat = toString (lib.flatten [ 1 [ 2 [ 3 ] ] ]);
  ranged = toString (lib.range 1 5);
  last = toString (lib.last [ 1 2 3 ]);
  parted = toString (lib.partition (x: x > 2) [ 1 2 3 4 ]).right;
  sorted = toString (lib.sort (a: b: a < b) [ 3 1 2 ]);
  crossed = toString (map (p: "${toString p.a}${p.b}")
    (lib.cartesianProduct { a = [ 1 2 ]; b = [ "x" ]; }));

  # Attribute sets.
  names = lib.concatStringsSep "," (lib.attrNames { b = 1; a = 2; });
  recursed = toString (lib.recursiveUpdate { a.b = 1; } { a.c = 2; }).a.c;
  filtered = lib.concatStringsSep "," (
    lib.attrNames (lib.filterAttrs (n: _: n != "drop") { keep = 1; drop = 2; })
  );
  mappedAttrs = lib.concatStringsSep "," (
    lib.attrValues (lib.mapAttrs (n: v: "${n}=${toString v}") { a = 1; b = 2; })
  );

  # The fixed point, which is what makes overlays work: lib.fix is the map out
  # of a generator, exactly as in docs/theory.md section 8.
  fixed = toString (lib.fix (self: { a = 1; b = self.a + 1; })).b;
  extended = toString (lib.fix (lib.extends
    (final: prev: { b = prev.a + 10; })
    (self: { a = 1; b = 0; }))).b;

  # Versions and options.
  ver = toString (lib.versionAtLeast "2.5" "2.4");
  ver2 = lib.getVersion { name = "foo-1.2"; };
  opt = lib.optionalString true "yes" + lib.optionalString false "no";
  optl = toString (lib.optionals true [ 1 2 ]);
}
