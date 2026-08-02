# builtins.match and builtins.split, against the engine Nix actually uses.
#
# Nix specifies POSIX ERE (std::regex with std::regex::extended), and we use
# ocaml-re's Re.Posix. Two different engines, and the second is a lazy DFA
# where Nix's is a backtracker, so agreement is a claim to be TESTED rather
# than assumed. The four documented deviations in ocaml-re's posix.mli are
# about submatch selection, which is exactly what these attributes expose.
#
# Every result feeds a derivation attribute, so a disagreement moves the store
# path.
let
  # A group that did not participate is null, not the empty string, and lib
  # branches on that distinction.
  optional = builtins.match "(a)(b)?" "a";
  showList = l: builtins.concatStringsSep "|" (
    map (x: if x == null then "<null>" else toString x) l
  );
in
derivation {
  name = "regex-probe";
  system = "x86_64-linux";
  builder = "/bin/sh";
  args = [ "-c" "true" ];

  # match is WHOLE-string: std::regex_match, not regex_search.
  whole = toString (builtins.match "b" "abc" == null);
  full = showList (builtins.match "a(b)c" "abc");
  nogroup = toString (builtins.match "abc" "abc");
  missed = showList optional;

  # Leftmost-LONGEST is the POSIX rule, and it is where a leftmost-first engine
  # (PCRE, Rust's regex, Python's re) gives a different answer.
  longest = showList (builtins.match "(a|ab)(c|bcd)" "abcd");
  greedy = showList (builtins.match "(a*)(a*)" "aaa");

  # ERE character classes and repetition counts.
  classes = showList (builtins.match "([[:alpha:]]+)-([[:digit:]]{2,3})" "abc-123");
  alt = showList (builtins.match "(foo|bar)+" "foobar");

  # split alternates strings and group-lists, always starts and ends with a
  # string, and therefore always has odd length.
  splitLen = toString (builtins.length (builtins.split "," "a,b,c"));
  splitParts = builtins.concatStringsSep "/" (
    builtins.filter builtins.isString (builtins.split "[,;]" "a,b;c")
  );
  splitGroups = showList (
    builtins.concatLists (builtins.filter builtins.isList (builtins.split "(x)" "axbxc"))
  );

  # A zero-width match still produces its pair.
  empty = toString (builtins.length (builtins.split "" "ab"));

  # The lib functions that were blocked on all of the above.
  esc = (import <nixpkgs/lib>).escapeShellArg "a b'c;d";
  escre = (import <nixpkgs/lib>).escapeRegex "a.b*c";
  splitstr = builtins.concatStringsSep "+" ((import <nixpkgs/lib>).splitString "." "1.2.3");
}
