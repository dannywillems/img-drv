# A derivation with a non-empty inputSrcs.
#
# This is the ONE half of the `.drv` references rule that nothing else here
# exercises. A derivation's own store path lists the paths it REFERENCES, which
# is `inputDrvs` UNION `inputSrcs`, and every derivation the project could
# previously build had an empty `inputSrcs`. So that half of the rule was
# verified only by READING real files, never by producing one.
#
# Interpolating a path literal is what puts it there: Nix adds the file to the
# store as a `source` object and records it in `inputSrcs`.
derivation {
  name = "with-src";
  system = "x86_64-linux";
  builder = "/bin/sh";
  args = [ "-c" "cat ${./probe-src.txt} > $out" ];
}
