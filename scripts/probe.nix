# The differential probe.
#
# Instantiated by the PINNED Nix (scripts/oracle.env), then every store path in
# the resulting closure is recomputed by our own implementation and compared.
# If upstream Nix ever changes how it derives paths, the recorded paths move,
# ours do not, and this fails. That is the only way we find out the oracle
# moved under us.
#
# Uses `derivation` directly rather than nixpkgs: no channel, no network, no
# evaluation of a hundred thousand attributes. Every case below is one that has
# actually cost us a wrong answer.

let
  # A plain dependency, so the derivation below has an input edge to fold in.
  dep = derivation {
    name = "dep-a";
    system = "x86_64-linux";
    builder = "/bin/sh";
    args = [ "-c" "echo a > $out" ];
  };

  # A second one, so inputDrvs has more than one entry and the two orderings
  # diverge: the .drv sorts by store path, the hashed form sorts by hash.
  dep2 = derivation {
    name = "dep-b";
    system = "x86_64-linux";
    builder = "/bin/sh";
    args = [ "-c" "echo b > $out" ];
  };

  # Fixed-output, flat ingestion: the `fixed:out:` fingerprint scheme.
  fetched = derivation {
    name = "fetched";
    system = "x86_64-linux";
    builder = "/bin/sh";
    args = [ "-c" "echo hi > $out" ];
    outputHashMode = "flat";
    outputHashAlgo = "sha256";
    outputHash = "0000000000000000000000000000000000000000000000000000000000000000";
  };

  # Fixed-output, recursive ingestion: the `source` kind with the declared hash
  # used directly. Exactly one derivation in a 226-derivation closure exercised
  # this, so it is here on purpose.
  fetchedRec = derivation {
    name = "fetched-rec";
    system = "x86_64-linux";
    builder = "/bin/sh";
    args = [ "-c" "mkdir $out" ];
    outputHashMode = "recursive";
    outputHashAlgo = "sha256";
    outputHash = "1111111111111111111111111111111111111111111111111111111111111111";
  };
in
derivation {
  name = "probe";
  system = "x86_64-linux";
  builder = "/bin/sh";

  # Depends on all four, so every scheme above appears as an INPUT and its
  # input-hash, which is not the same string as its own path hash, is folded in.
  args = [ "-c" "cat ${dep} ${dep2} ${fetched} ${fetchedRec} > $out" ];

  # Several outputs: the `out` / `-dev` / `-lib` naming rule, and the fact that
  # the outputs list is sorted by name while the `outputs` env variable keeps
  # declaration order.
  outputs = [ "out" "dev" "lib" ];

  # Declared out of order, to pin that env is sorted by key.
  zzz = "last";
  aaa = "first";
  mmm = "middle";

  # Values containing the characters that defeat pattern matching.
  nasty = ''a "quoted" \ backslash, a ],[ sequence, and a tab:	done'';
}
