# The second builtins probe: the ones lib actually reaches for.
#
# Same discipline as probe-builtins.nix: each result feeds a derivation
# attribute, so a wrong answer moves the store path rather than hiding in a
# value. These are the builtins that a static count over nixpkgs/lib said it
# uses and we did not have.
let
  dep = derivation {
    name = "more-dep";
    system = "x86_64-linux";
    builder = "/bin/sh";
    args = [ "-c" "echo d > $out" ];
  };
in
derivation {
  name = "more-probe";
  system = "x86_64-linux";
  builder = "/bin/sh";
  args = [ "-c" "true" ];

  # Version comparison is neither lexicographic nor semver: a pre/rc/alpha/beta
  # component sorts BELOW the empty component, so 1.0pre1 is older than 1.0.
  vers = builtins.concatStringsSep "," (map toString [
    (builtins.compareVersions "1.0" "1.0pre1")
    (builtins.compareVersions "1.0pre1" "1.0")
    (builtins.compareVersions "2.10" "2.9")
    (builtins.compareVersions "1.0" "1.0")
  ]);
  vsplit = builtins.concatStringsSep "|" (builtins.splitVersion "1.2.3pre4");

  # parseDrvName splits at the first dash NOT followed by a letter, which is how
  # gtk+-2.0 keeps its plus.
  parsed = let p = builtins.parseDrvName "gtk+-2.0"; in "${p.name}@${p.version}";
  parsed2 = let p = builtins.parseDrvName "lib-foo-1.2"; in "${p.name}@${p.version}";

  # concatMap, partition, groupBy.
  cm = toString (builtins.concatMap (x: [ x x ]) [ 1 2 ]);
  pt = toString (builtins.partition (x: x > 2) [ 1 2 3 4 ]).right;
  gb = builtins.concatStringsSep "," (
    builtins.attrNames (builtins.groupBy (x: x) [ "a" "b" "a" ])
  );

  # genericClosure is a least fixed point: Kleene iteration on the powerset
  # lattice, terminating because the key set is finite.
  gc = toString (map (e: e.key) (builtins.genericClosure {
    startSet = [ { key = 1; } ];
    operator = e: if e.key < 4 then [ { key = e.key + 1; } ] else [ ];
  }));

  # trace and warn are transparent to the value.
  traced = builtins.trace "ignore me" "kept";

  # Context as data. hasContext is true only for the interpolated one.
  ctx = toString (builtins.hasContext "${dep}") + toString (builtins.hasContext "plain");
  discarded = builtins.unsafeDiscardStringContext "${dep}";

  # toFile is the SECOND thing in the language that can produce a store path,
  # and it uses the text kind rather than source: hashed directly, no NAR.
  written = builtins.toFile "note.txt" "hello\n";

  # zipAttrsWith over overlapping sets.
  zipped = builtins.concatStringsSep "," (
    builtins.attrNames (builtins.zipAttrsWith (n: vs: n) [ { a = 1; } { b = 2; a = 3; } ])
  );
}
