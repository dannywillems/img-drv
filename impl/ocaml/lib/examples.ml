(** The conformance corpus: intents, and the bytes real Nix produced for them.

    This is the language-independent set [PLAN.md] phase 2 asks for. Each entry
    is an INTENT expressed through the eDSL, paired with the name of the golden
    file in [docs/spec/examples/] that real Nix emitted for the same intent.

    It lives in the library rather than in the tests because three things
    consume it: the test suite, the [examples] CLI command, and
    [make conformance].

    These are the SAME ten intents as the Python, Rust and Go implementations,
    transcribed rather than shared, because there is nothing to share them
    THROUGH: that is exactly the claim under test. *)

open Types

(** Every example targets one system, so the corpus is comparable across
    machines: a derivation's store path depends on its system. *)
let system = "x86_64-linux"

(** The builder every example runs. *)
let builder = "/bin/sh"

(** These names are literals known to be valid, so the [Name.of_string] result
    is unwrapped here rather than threaded through. Everything ELSE in this file
    goes through the checked path; this is the one place a fixed corpus is
    allowed to assert. *)
let name_exn s = match Name.of_string s with Ok n -> n | Error e -> failwith e

let derive_exn b =
  match Edsl.derive b with
  | Ok d -> d
  | Error e -> failwith (Edsl.error_to_string e)

let output_exn d n =
  match Edsl.output d n with
  | Ok p -> Store_path.to_string p
  | Error e -> failwith (Edsl.error_to_string e)

let needs_exn d =
  match Edsl.needs d [] with
  | Ok dep -> dep
  | Error e -> failwith (Edsl.error_to_string e)

let base name = Edsl.build ~name:(name_exn name) ~system ~builder

let echo name word =
  derive_exn (base name ~args:["-c"; Printf.sprintf "echo %s > $out" word] ())

(** The smallest real derivation: one output, no dependencies. *)
let hello () = echo "hello" "hi"

(** One of three leaves used to exercise multi-entry [inputDrvs]. *)
let aaa () = echo "aaa" "aaa"

(** One of three leaves used to exercise multi-entry [inputDrvs]. *)
let mmm () = echo "mmm" "mmm"

(** One of three leaves used to exercise multi-entry [inputDrvs]. *)
let zzz () = echo "zzz" "zzz"

(** The dependency of {!dependent}, and a reconstruction target itself. *)
let dep_a () = echo "dep-a" "a"

(** One edge, which is what pins the mask/do-not-mask asymmetry. *)
let dependent () =
  let a = dep_a () in
  derive_exn
    (base
       "dependent"
       ~args:["-c"; Printf.sprintf "cat %s > $out" (output_exn a "out")]
       ~input_drvs:[needs_exn a]
       ())

(** Three edges, named in an order that is NOT their store-path order.

    That is what makes this example evidence: [inputDrvs] has to come out sorted
    by path regardless of the order the caller used them in. *)
let many () =
  let a = aaa () and m = mmm () and z = zzz () in
  derive_exn
    (base
       "many"
       ~args:
         [
           "-c";
           Printf.sprintf
             "cat %s %s %s > $out"
             (output_exn z "out")
             (output_exn a "out")
             (output_exn m "out");
         ]
       ~input_drvs:[needs_exn z; needs_exn a; needs_exn m]
       ())

(** Env declared out of order, to pin that env is sorted by key. *)
let ordering () =
  derive_exn
    (base
       "ordering"
       ~env:
         [
           ("zzz", Json.String "last-declared-first");
           ("aaa", Json.String "first");
           ("mmm", Json.String "middle");
         ]
       ())

(** Three outputs, which carries TWO orderings of the same list. *)
let multi () =
  derive_exn
    (base "multi" ~outputs:[name_exn "out"; name_exn "dev"; name_exn "lib"] ())

(** A fixed-output derivation, with the hash written in base-32.

    The outputs tuple must carry it re-encoded as hex while the env keeps it
    exactly as written, which is the rule an implementation is most likely to
    get wrong. *)
let fixed () =
  derive_exn
    (base
       "fixed"
       ~fixed_output:(Edsl.fixed ~algo:Edsl.Sha256 (String.make 52 '0'))
       ())

(** [__structuredAttrs]: attributes as JSON, with their types preserved.

    The flat encoding can only carry strings, so a boolean, an integer, a list
    or a nested attribute set has to be flattened and re-parsed by the builder.
    This one keeps them. 1223 of 2516 real derivations use it.

    It also exercises the same two-orderings rule as {!multi}: the outputs
    tuple comes out sorted ([dev], [out]) while [outputs] inside the JSON keeps
    declaration order ([out], [dev]). *)
let structured () =
  derive_exn
    (base
       "structured"
       ~args:["-c"; "echo hi > $out"]
       ~outputs:[name_exn "out"; name_exn "dev"]
       ~structured_attrs:true
       ~env:
         [
           ("aFlag", Json.Bool true);
           ("aNumber", Json.Int 42);
           ("aList", Json.strings ["x"; "y"]);
           ( "nested",
             Json.Object
               [("deep", Json.Object [("deeper", Json.String "value")])] );
           ("aString", Json.String "plain");
         ]
       ())

(** Golden file name, and the intent that must reproduce it byte for byte. *)
let corpus () =
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

(* The DIFFERENTIAL probe, described through the eDSL.

   [scripts/probe.nix] is instantiated by the pinned Nix on every run, and until
   now only our PATH COMPUTATION was checked against the result: parse what Nix
   emitted, recompute the paths, compare. The eDSL itself was checked only
   against the golden files in [docs/spec/examples/], which are checked in and
   therefore frozen.

   Describing the same five derivations here makes [make differential] a LIVE
   oracle for the eDSL as well: our bytes against bytes a real nix-instantiate
   produced moments earlier, rather than against a file someone committed. If
   upstream Nix changes anything about how these are serialized, this is what
   notices.

   Every case is here because it once cost a wrong answer, which is why the
   probe is not simply the conformance corpus again: a fixed-output derivation
   with RECURSIVE ingestion appears in neither, and exactly one derivation in a
   226-derivation closure exercised it. *)

let probe_dep name word =
  derive_exn (base name ~args:["-c"; Printf.sprintf "echo %s > $out" word] ())

(** Fixed-output, FLAT ingestion: the [fixed:out:] fingerprint scheme. *)
let probe_fetched () =
  derive_exn
    (base
       "fetched"
       ~args:["-c"; "echo hi > $out"]
       ~fixed_output:(Edsl.fixed ~algo:Edsl.Sha256 (String.make 64 '0'))
       ())

(** Fixed-output, RECURSIVE ingestion: the [source] kind, with the declared
    hash used DIRECTLY as the inner hash rather than wrapped in a fingerprint.
    Missing this costs exactly one path in a real closure, which is how it
    survived a hand-written corpus. *)
let probe_fetched_rec () =
  derive_exn
    (base
       "fetched-rec"
       ~args:["-c"; "mkdir $out"]
       ~fixed_output:
         (Edsl.fixed
            ~mode:Edsl.Recursive
            ~algo:Edsl.Sha256
            (String.make 64 '1'))
       ())

(** The probe itself: four input edges covering every scheme above, several
    outputs, env declared out of order, and a value containing the characters
    that defeat pattern matching. *)
let probe () =
  let dep = probe_dep "dep-a" "a" in
  let dep2 = probe_dep "dep-b" "b" in
  let fetched = probe_fetched () in
  let fetched_rec = probe_fetched_rec () in
  derive_exn
    (base
       "probe"
       ~args:
         [
           "-c";
           Printf.sprintf
             "cat %s %s %s %s > $out"
             (output_exn dep "out")
             (output_exn dep2 "out")
             (output_exn fetched "out")
             (output_exn fetched_rec "out");
         ]
       ~input_drvs:
         [
           needs_exn dep;
           needs_exn dep2;
           needs_exn fetched;
           needs_exn fetched_rec;
         ]
       ~outputs:[name_exn "out"; name_exn "dev"; name_exn "lib"]
       ~env:
         [
           ("zzz", Json.String "last");
           ("aaa", Json.String "first");
           ("mmm", Json.String "middle");
           (* No trailing newline: the probe writes this as a ONE-LINE indented
              string, and an indented string that does not end in a newline
              does not gain one. Adding it here was the first thing the live
              oracle caught, which is the point of having one. *)
           ( "nasty",
             Json.String
               "a \"quoted\" \\ backslash, a ],[ sequence, and a tab:\tdone" );
         ]
       ())

(** Every derivation the probe closure contains. *)
let probe_corpus () =
  [
    probe_dep "dep-a" "a";
    probe_dep "dep-b" "b";
    probe_fetched ();
    probe_fetched_rec ();
    probe ();
  ]
