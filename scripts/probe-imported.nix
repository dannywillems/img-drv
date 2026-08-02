# Imported by probe-structured.nix.
#
# Deliberately uses a builtin and a derivation of its own, so that a broken
# `import` cannot pass by accident: both the string and the edge below have to
# arrive intact in the importing file.
{
  value = builtins.concatStringsSep "-" [ "im" "por" "ted" ];

  drv = derivation {
    name = "imported-dep";
    system = "x86_64-linux";
    builder = "/bin/sh";
    args = [ "-c" "echo imported > $out" ];
  };
}
