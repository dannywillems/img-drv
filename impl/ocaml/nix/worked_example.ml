(** A real package, through a real overlay, against real nixpkgs.

    The eleven conformance intents are derivations nobody would write: no
    dependencies, no stdenv, no composition. They pin the SERIALIZATION. This
    pins the SURFACE, which is the part the project's claim actually rests on
    and the part with the least evidence behind it.

    What it exercises that the intents do not: [stdenv.mkDerivation], a
    dependency taken from nixpkgs, a value that arrived through an overlay and
    is interpolated into a build phase, and a fixed point tying the overlay's
    knot. Every one of those is something a user would write on their first
    day and none of them appears in the corpus.

    The check is in [scripts/worked-example.sh]: this term and the hand-written
    [docs/spec/examples/worked-example.nix] must instantiate to the SAME store
    path. Textual similarity is neither expected nor meaningful; the `.drv` is
    the normal form, which is the same reason the transpiler's law lives
    there. *)

open Surface

(** The overlay: bump the version, and derive a value from [final] so the knot
    has to be tied for it to evaluate at all. *)
let bump : overlay =
 fun final prev ->
  attrs
    [
      ("version", str "2.0");
      ( "banner",
        istr
          [
            `E (select prev ["greeting"]); `S " v"; `E (select final ["version"]);
          ] );
    ]

let base = attrs [("greeting", str "hello"); ("version", str "1.0")]

let term () =
  reset () ;
  let_in
    ~name:"pkgs"
    (apply (var "import") [spath "nixpkgs"; attrs []])
    (fun pkgs ->
      let_in ~name:"final" (fix base bump) (fun final ->
          apply
            (select pkgs ["stdenv"; "mkDerivation"])
            [
              attrs
                [
                  ("pname", str "img-drv-worked-example");
                  ("version", select final ["version"]);
                  ("dontUnpack", bool true);
                  ("nativeBuildInputs", list [select pkgs ["hello"]]);
                  ( "buildPhase",
                    istr
                      [
                        `S "echo "; `E (select final ["banner"]); `S " > out.txt";
                      ] );
                  ( "installPhase",
                    str "mkdir -p $out/share && cp out.txt $out/share/" );
                ];
            ]))
