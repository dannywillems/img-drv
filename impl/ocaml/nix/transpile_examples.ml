(** The eleven conformance intents, written as Nix EXPRESSIONS in OCaml.

    These are the same intents as [Img_drv.Examples], expressed through the
    other arrow. There they are built directly as IR and serialized to `.drv`;
    here they are built as Nix syntax and printed as `.nix`, for real Nix to
    instantiate.

    That is the COMMUTING SQUARE of [docs/architecture.md]: both routes must
    end at the same bytes, and the bytes are already known to be right because
    `make conformance` pins them for four implementations.

    Note what a reader does NOT have to write: no store paths, no hashes, and
    for the dependent cases no explicit edge. Interpolating one derivation into
    another's arguments is what creates the dependency, via the string context
    described in [docs/nix-internals.md]. That is the mechanism the eDSLs
    deliberately do without, and having it back is the point of transpiling. *)

open Surface

let system = str "x86_64-linux"

let sh = str "/bin/sh"

let drv pairs = apply (var "derivation") [attrs pairs]

let echo name word =
  drv
    [
      ("name", str name);
      ("system", system);
      ("builder", sh);
      ("args", list [str "-c"; str (Printf.sprintf "echo %s > $out" word)]);
    ]

let hello () = echo "hello" "hi"

let aaa () = echo "aaa" "aaa"

let mmm () = echo "mmm" "mmm"

let zzz () = echo "zzz" "zzz"

let dep_a () = echo "dep-a" "a"

(* The edge is implicit: `${a}` carries a's drv path in its string context, so
   Nix adds the inputDrvs entry itself. Compare the eDSL, where the caller
   passes the dependency explicitly. *)
let dependent () =
  let_in ~name:"a" (dep_a ()) (fun a ->
      drv
        [
          ("name", str "dependent");
          ("system", system);
          ("builder", sh);
          ("args", list [str "-c"; istr [`S "cat "; `E a; `S " > $out"]]);
        ])

let many () =
  let_in ~name:"a" (aaa ()) (fun a ->
      let_in ~name:"m" (mmm ()) (fun m ->
          let_in ~name:"z" (zzz ()) (fun z ->
              drv
                [
                  ("name", str "many");
                  ("system", system);
                  ("builder", sh);
                  ( "args",
                    list
                      [
                        str "-c";
                        istr
                          [
                            `S "cat ";
                            `E z;
                            `S " ";
                            `E a;
                            `S " ";
                            `E m;
                            `S " > $out";
                          ];
                      ] );
                ])))

let ordering () =
  drv
    [
      ("name", str "ordering");
      ("system", system);
      ("builder", sh);
      ("zzz", str "last-declared-first");
      ("aaa", str "first");
      ("mmm", str "middle");
    ]

let multi () =
  drv
    [
      ("name", str "multi");
      ("system", system);
      ("builder", sh);
      ("outputs", list [str "out"; str "dev"; str "lib"]);
    ]

let fixed () =
  drv
    [
      ("name", str "fixed");
      ("system", system);
      ("builder", sh);
      ("outputHash", str (String.make 52 '0'));
      ("outputHashAlgo", str "sha256");
      ("outputHashMode", str "flat");
    ]

let structured () =
  drv
    [
      ("name", str "structured");
      ("system", system);
      ("builder", sh);
      ("args", list [str "-c"; str "echo hi > $out"]);
      ("__structuredAttrs", bool true);
      ("outputs", list [str "out"; str "dev"]);
      ("aFlag", bool true);
      ("aNumber", int 42);
      ("aList", list [str "x"; str "y"]);
      ("nested", attrs [("deep", attrs [("deeper", str "value")])]);
      ("aString", str "plain");
    ]

(** Golden file name, and the expression that must produce it through real
    Nix. *)
let corpus () =
  reset () ;
  [
    ("sb07z720914wba188q8vzq7jnx4596xp-dependent.drv", dependent ());
    ("3k9aahbip0dn0kb9m6i20sr2mjfmzsij-aaa.drv", aaa ());
    ("6hjg3xda34qvj2vpw27girg51gpdyd19-fixed.drv", fixed ());
    ("76w21n1f03fs5kw8fnffphx7qrqffw6r-hello.drv", hello ());
    ("7v25018h9x5nc7sc0sv57ghaq2qa0j9n-zzz.drv", zzz ());
    ("5x04ng0y0kgnkp3kyah1ziwlyj107q8m-many.drv", many ());
    ("k1lc1y192xiajlyy4zvsdnfprnjx32i3-dep-a.drv", dep_a ());
    ("mfdcxzh0v906c5hngb3x0b7sjl130hpk-ordering.drv", ordering ());
    ("sqgix69fbs6hjh5kmf2pb1zvfmi5d0am-structured.drv", structured ());
    ("v27a425rg4n7prwzpyyw0y1fw2ssc46f-multi.drv", multi ());
    ("vk8wqbqg3k8w4134kwa0392kbc1953aq-mmm.drv", mmm ());
  ]
