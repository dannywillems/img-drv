# A structured-attrs derivation, small enough to reason about by hand.
# Exercises what the plain encoding cannot: typed values (bool, int, list,
# nested attrset) surviving into the env instead of being flattened to strings.
derivation {
  name = "structured";
  system = "x86_64-linux";
  builder = "/bin/sh";
  args = [ "-c" "echo hi > $out" ];
  __structuredAttrs = true;
  outputs = [ "out" "dev" ];
  aFlag = true;
  aNumber = 42;
  aList = [ "x" "y" ];
  nested = { deep = { deeper = "value"; }; };
  aString = "plain";
}
