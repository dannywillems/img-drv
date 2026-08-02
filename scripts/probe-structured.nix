# __structuredAttrs, and import.
#
# The SECOND env encoding (docs/spec/canonical.md section 1.8), used by 1223 of
# the 2516 real derivations in the corpus. Attributes keep their TYPES here
# rather than each becoming a string variable, so an implementation that
# coerces everything to a string passes the first probe and fails this one.
#
# Also exercises `import`, which is not textual inclusion: the imported file is
# evaluated in the GLOBAL scope, so it cannot see this file's `let` bindings.
let
  dep = import ./probe-imported.nix;
in
derivation {
  name = "structured-probe";
  system = "x86_64-linux";
  builder = "/bin/sh";
  args = [ "-c" "true" ];
  __structuredAttrs = true;

  # Types that a string-coercing implementation would flatten.
  count = 42;
  ratio = 1.5;
  enabled = true;
  disabled = false;
  nothing = null;
  words = [ "a" "b" ];
  nested = { inner = { deep = [ 1 2 3 ]; }; };

  # From the imported file, so a broken `import` moves the path.
  imported = dep.value;

  # The context still has to survive the JSON encoding: this is an inputDrvs
  # edge that exists only because a derivation was interpolated inside a
  # structured attribute.
  ref = "${dep.drv}/bin/thing";
}
