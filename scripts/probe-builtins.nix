# The builtins probe.
#
# Every builtin here feeds a derivation ATTRIBUTE, so the check is not "does it
# return the right value" but "does the store path move". That is a stronger
# question and a cheaper one: a builtin that is subtly wrong changes a string,
# which changes the env, which changes the input hash, which changes the
# filename. There is nowhere for a wrong answer to hide.
#
# Chosen for the cases where Nix's behaviour is not what a reimplementer would
# guess. Each line here is a decision that could have gone the other way.

let
  # listToAttrs keeps the FIRST of a duplicated name, the opposite of `//`.
  dup = builtins.listToAttrs [
    { name = "k"; value = "first"; }
    { name = "k"; value = "second"; }
  ];

  # substring CLAMPS instead of raising: past the end is empty, over-long is
  # truncated. lib depends on both.
  clamp = builtins.substring 3 100 "abcde" + "|" + builtins.substring 99 1 "abc";

  # replaceStrings tries the patterns IN ORDER, so a shorter pattern listed
  # first beats a longer one that also matches. Not longest-match.
  order = builtins.replaceStrings [ "a" "ab" ] [ "X" "Y" ] "abab";

  # sort is stable, and lessThan on mixed numbers compares by value.
  sorted = builtins.concatStringsSep "," (
    map toString (builtins.sort builtins.lessThan [ 3 1 2 ])
  );
  mixed = toString (builtins.lessThan 1 1.5) + toString (builtins.lessThan 1 1.0);

  # foldl' is strict in the accumulator.
  summed = toString (builtins.foldl' (a: b: a + b) 0 (builtins.genList (i: i) 10));

  # A Boolean coerces to "1" or the empty string, never "true"/"false".
  bools = toString true + "|" + toString false + "|" + toString null;

  # A list coerces elementwise, joined with single spaces.
  #
  # The path is the interesting element, and both directions are pinned here
  # because they differ and getting them backwards is invisible in a value:
  # `toString ./x` yields the BARE path and contributes nothing to inputSrcs,
  # while interpolating it COPIES the file into the store and does. Only the
  # basename of the first is compared, so the probe does not depend on where it
  # was run from; the second is a store path and absolute by construction.
  listcoerce = toString [ 1 "two" (baseNameOf (toString ./probe-src.txt)) ];
  interpolated = "${./probe-src.txt}";

  # tryEval turns an error into data, and only an evaluation error.
  caught = toString (builtins.tryEval (throw "nope")).success;

  # functionArgs reports which formals have defaults.
  fargs = builtins.concatStringsSep "," (
    builtins.attrNames (builtins.functionArgs ({ a, b ? 1 }: a))
  );

  # A dependency, so a computed attribute can carry a context and become an
  # inputDrvs edge without anyone writing the edge.
  dep = derivation {
    name = "builtins-dep";
    system = "x86_64-linux";
    builder = "/bin/sh";
    args = [ "-c" "echo dep > $out" ];
  };
in
derivation {
  name = "builtins-probe";
  system = "x86_64-linux";
  builder = "/bin/sh";
  args = [ "-c" "true" ];

  inherit clamp order sorted mixed summed bools listcoerce interpolated caught fargs;
  first = dup.k;

  # The edge is COMPUTED. Nothing below names dep as a dependency; the string
  # context does it, through concatStringsSep and through a nested list.
  viaSep = builtins.concatStringsSep ":" [ "${dep}" "x" ];
  viaNested = toString (builtins.concatLists [ [ "${dep}/bin" ] [ "y" ] ]);
  viaJSON = builtins.toJSON { path = "${dep}"; n = 1; ok = true; };
}
