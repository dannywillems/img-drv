(** The OCaml test suite, under Alcotest.

    Three groups, mirroring the other three implementations:

    - [sha256]: the published FIPS 180-4 vectors, checked BEFORE anything
      downstream trusts the hash. This implementation writes its own sha256, so
      these are the foundation the store paths stand on, and they are what
      caught the operator-precedence bug in the first version;
    - [golden]: real derivations produced by real Nix, round-tripped and
      re-hashed;
    - [edsl] and [laws]: describe the same ten intents as Python, Rust and Go,
      and the same laws, stated over generated intents rather than examples. *)

open Img_drv
open Types

(* dune SANDBOXES the test, so a path relative to the source tree does not
   resolve, and the golden files live outside this dune project's root so they
   cannot be declared as deps either. The runner passes an absolute path. *)
let golden_dir =
  match Sys.getenv_opt "IMG_DRV_GOLDEN" with
  | Some d -> d
  | None -> failwith "IMG_DRV_GOLDEN is not set; see scripts/ml-check.sh"

let read_file path =
  let ic = open_in_bin path in
  let n = in_channel_length ic in
  let s = really_input_string ic n in
  close_in ic ;
  s

let golden_files () =
  Sys.readdir golden_dir |> Array.to_list
  |> List.filter (fun f -> Filename.check_suffix f ".drv")
  |> List.sort String.compare

let golden name = String.trim (read_file (Filename.concat golden_dir name))

(* ------------------------------------------------------------------ *)
(* sha256                                                              *)
(* ------------------------------------------------------------------ *)

let test_sha256_vectors () =
  (* FIPS 180-4. An implementation that writes its own hash has to earn the
     right to be trusted by the rest of the suite. *)
  let cases =
    [
      ("", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
      ("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
      ( "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
        "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1" );
      ( String.make 1000 'a',
        "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3" );
    ]
  in
  List.iter
    (fun (input, expected) ->
      Alcotest.(check string)
        (Printf.sprintf "sha256 of %d bytes" (String.length input))
        expected
        (Sha256.hex input))
    cases

let test_base32_inverts () =
  (* An inverse, not an approximation of one. *)
  for n = 1 to 40 do
    let data = Bytes.init n (fun i -> Char.chr (i * 37 land 0xff)) in
    match Store.base32_decode (Store.base32 data) n with
    | Ok back -> Alcotest.(check bytes) "round trip" data back
    | Error e -> Alcotest.fail e
  done

(* ------------------------------------------------------------------ *)
(* golden: real derivations from real Nix                              *)
(* ------------------------------------------------------------------ *)

let test_examples_present () =
  (* A corpus that silently vanished would make everything below pass. *)
  Alcotest.(check bool) "at least ten" true (List.length (golden_files ()) >= 10)

let test_round_trips () =
  (* Byte equality, not structural equality: the bytes ARE the artifact, since
     the derivation's own store path is their hash. *)
  List.iter
    (fun f ->
      let text = golden f in
      match Aterm.parse text with
      | Error e -> Alcotest.fail (f ^ ": " ^ e)
      | Ok d -> Alcotest.(check string) f text (Aterm.unparse d))
    (golden_files ())

let test_every_output_path_recomputes () =
  (* The whole specification, end to end, on vectors nobody wrote by hand. *)
  match Corpus.of_directory golden_dir with
  | Error e -> Alcotest.fail e
  | Ok c ->
      let checked, bad = Corpus.verify c in
      List.iter (fun m -> print_endline (Corpus.mismatch_to_string m)) bad ;
      Alcotest.(check int) "no mismatches" 0 (List.length bad) ;
      Alcotest.(check bool) "checked at least 12" true (checked >= 12)

let test_real_derivations_are_canonical () =
  (* If canonicalizing a real derivation changed it, our ordering rules would
     merely be self-consistent, and every claim about byte-identity across
     languages would be about our own convention rather than about Nix's. *)
  List.iter
    (fun f ->
      match Aterm.parse (golden f) with
      | Error e -> Alcotest.fail e
      | Ok d -> Alcotest.(check bool) f true (Edsl.canonical d = d))
    (golden_files ())

(* ------------------------------------------------------------------ *)
(* the eDSL, against the same ten intents as the other three           *)
(* ------------------------------------------------------------------ *)

let test_intents_reproduce_nix () =
  (* The exit test of Phase 1, in miniature. Structural equality would not do:
     the bytes are hashed to produce the derivation's own store path. *)
  List.iter
    (fun (file, drv) ->
      Alcotest.(check string) file (golden file) (Edsl.aterm drv))
    (Examples.corpus ())

let test_intents_land_at_their_own_path () =
  (* Reproducing the CONTENT while computing the wrong path would mean the
     text-kind store path rule is wrong, which nothing else here would catch. *)
  List.iter
    (fun (file, (drv : Edsl.drv)) ->
      Alcotest.(check string)
        file
        file
        (Filename.basename (Store_path.to_string drv.path)))
    (Examples.corpus ())

let test_every_golden_has_an_intent () =
  (* A golden nobody describes is a rule nobody is testing. *)
  Alcotest.(check (list string))
    "described = on disk"
    (golden_files ())
    (List.map fst (Examples.corpus ()) |> List.sort String.compare)

let test_output_paths_known_in_advance () =
  Alcotest.(check string)
    "hello"
    "/nix/store/mjs27ix6ig2bkbi3s3sm470vrv4lf7ic-hello"
    (Examples.output_exn (Examples.hello ()) "out")

let test_declaring_outputs_is_observable () =
  (* Nix emits an outputs env variable exactly when the caller DECLARED the
     attribute, so None and Some ["out"] are different derivations. 96 of the
     corpus's single-output derivations take the first, 605 the second. *)
  let name = Examples.name_exn "x" in
  let mk outputs =
    Examples.derive_exn
      (Edsl.build
         ~name
         ~system:Examples.system
         ~builder:Examples.builder
         ?outputs
         ())
  in
  let implicit = mk None and explicit = mk (Some [Examples.name_exn "out"]) in
  let contains hay needle =
    let n = String.length needle in
    let rec go i =
      i + n <= String.length hay
      && (String.equal (String.sub hay i n) needle || go (i + 1))
    in
    go 0
  in
  Alcotest.(check bool)
    "implicit emits no outputs var"
    false
    (contains (Edsl.aterm implicit) "(\"outputs\"") ;
  Alcotest.(check bool)
    "explicit emits one"
    true
    (contains (Edsl.aterm explicit) "(\"outputs\",\"out\")") ;
  Alcotest.(check bool)
    "different paths"
    false
    (Store_path.equal implicit.path explicit.path)

let test_invalid_names_are_unconstructible () =
  (* THE OCaml row of the typing table. In the other three this is a runtime
     check inside the constructor, and their error types carry a case for it.
     Here Name.t is abstract and validated, so an invalid name never becomes a
     value, and Edsl.error has no Invalid_name case at all. *)
  List.iter
    (fun bad ->
      match Name.of_string bad with
      | Ok _ -> Alcotest.fail (Printf.sprintf "%S was accepted" bad)
      | Error _ -> ())
    [""; "."; ".."; ".hidden"; "a b"; "a/b"; String.make 212 'x'] ;
  List.iter
    (fun good ->
      match Name.of_string good with Ok _ -> () | Error e -> Alcotest.fail e)
    ["hello"; "hello-1.0"; "a+b"; "x_y"; "q?"; "n=1"; String.make 211 'x']

let test_a_digest_means_the_same_however_written () =
  (* Why every fetchurl in nixpkgs can share one cache entry. The .drv path is
     NOT representation-independent, because the env keeps the hash verbatim. *)
  let digest = Bytes.init 32 (fun i -> Char.chr i) in
  let hex = Sha256.to_hex digest in
  let b64 =
    let alphabet = Edsl.b64_alphabet in
    let buf = Buffer.create 44 in
    let n = Bytes.length digest in
    let i = ref 0 in
    while !i < n do
      let b0 = Char.code (Bytes.get digest !i) in
      let b1 =
        if !i + 1 < n then Char.code (Bytes.get digest (!i + 1)) else 0
      in
      let b2 =
        if !i + 2 < n then Char.code (Bytes.get digest (!i + 2)) else 0
      in
      let acc = (b0 lsl 16) lor (b1 lsl 8) lor b2 in
      Buffer.add_char buf alphabet.[(acc lsr 18) land 0x3f] ;
      Buffer.add_char buf alphabet.[(acc lsr 12) land 0x3f] ;
      Buffer.add_char
        buf
        (if !i + 1 < n then alphabet.[(acc lsr 6) land 0x3f] else '=') ;
      Buffer.add_char buf (if !i + 2 < n then alphabet.[acc land 0x3f] else '=') ;
      i := !i + 3
    done ;
    Buffer.contents buf
  in
  let mk f =
    Examples.derive_exn
      (Edsl.build
         ~name:(Examples.name_exn "f")
         ~system:Examples.system
         ~builder:Examples.builder
         ~fixed_output:f
         ())
  in
  let a = mk (Edsl.fixed ~algo:Edsl.Sha256 hex)
  and b = mk (Edsl.fixed ~algo:Edsl.Sha256 (Store.base32 digest))
  and c = mk (Edsl.sri ("sha256-" ^ b64)) in
  let out d = Examples.output_exn d "out" in
  Alcotest.(check string) "hex = base32" (out a) (out b) ;
  Alcotest.(check string) "hex = sri" (out a) (out c) ;
  Alcotest.(check bool)
    "but the .drv paths differ"
    false
    (Store_path.equal a.path b.path)

(* ------------------------------------------------------------------ *)
(* laws, over generated intents                                        *)
(* ------------------------------------------------------------------ *)

(** A deterministic generator. The seed is pinned: a property test with an
    unpinned seed is not reproducible, which in a project about reproducibility
    would be an odd thing to ship. *)
let seeded () = Random.State.make [|20260802|]

let gen_name st =
  let alphabet = "abcdefghijklmnopqrstuvwxyz0123456789+-._?=" in
  let n = 1 + Random.State.int st 8 in
  String.init n (fun i ->
      if i = 0 then Char.chr (Char.code 'a' + Random.State.int st 26)
      else alphabet.[Random.State.int st (String.length alphabet)])

let nasty = [|'"'; '\\'; '\n'; '\r'; '\t'; '\007'; ']'; '['; ','; '/'|]

let gen_value st =
  let n = Random.State.int st 10 in
  String.init n (fun _ ->
      if Random.State.int st 5 = 0 then Char.chr (1 + Random.State.int st 126)
      else nasty.(Random.State.int st (Array.length nasty)))

type intent = {
  i_name : string;
  i_system : string;
  i_builder : string;
  i_args : string list;
  i_env : (string * string) list;
  i_outputs : string list option;
}

let gen_intent st =
  let outputs =
    if Random.State.bool st then
      Some
        (List.sort_uniq
           String.compare
           (List.init (1 + Random.State.int st 3) (fun _ -> gen_name st)))
    else None
  in
  let names = match outputs with Some l -> l | None -> ["out"] in
  let blocked =
    [
      "name";
      "system";
      "builder";
      "outputs";
      "outputHash";
      "outputHashAlgo";
      "outputHashMode";
    ]
    @ names
  in
  let env =
    List.init (Random.State.int st 5) (fun _ -> (gen_name st, gen_value st))
    |> List.filter (fun (k, _) -> not (List.mem k blocked))
    |> List.sort_uniq (fun (a, _) (b, _) -> String.compare a b)
  in
  {
    i_name = gen_name st;
    i_system = gen_value st;
    i_builder = gen_value st;
    i_args = List.init (Random.State.int st 3) (fun _ -> gen_value st);
    i_env = env;
    i_outputs = outputs;
  }

let build_intent ?(deps = []) i =
  Examples.derive_exn
    (Edsl.build
       ~name:(Examples.name_exn i.i_name)
       ~system:i.i_system
       ~builder:i.i_builder
       ~args:i.i_args
       ~env:i.i_env
       ?outputs:(Option.map (List.map Examples.name_exn) i.i_outputs)
       ~input_drvs:deps
       ())

let edge (d : Edsl.drv) =
  let first =
    Output_name.to_string (List.hd d.derivation.outputs).Derivation.name
  in
  match Edsl.needs d [first] with
  | Ok dep -> dep
  | Error e -> failwith (Edsl.error_to_string e)

let for_each_intent n f =
  let st = seeded () in
  for _ = 1 to n do
    f (gen_intent st) (gen_intent st)
  done

let law_same_intent_twice () =
  (* Serialization is a FUNCTION, not a process. *)
  for_each_intent 200 (fun i _ ->
      let a = build_intent i and b = build_intent i in
      Alcotest.(check string) "bytes" (Edsl.aterm a) (Edsl.aterm b) ;
      Alcotest.(check bool) "path" true (Store_path.equal a.path b.path))

let law_dependency_order_not_observable () =
  (* inputDrvs is a SET of edges; the .drv sorts it by store path. *)
  for_each_intent 100 (fun a b ->
      let x = edge (build_intent a) and y = edge (build_intent b) in
      let one = build_intent ~deps:[x; y] a
      and other = build_intent ~deps:[y; x] a in
      Alcotest.(check string) "bytes" (Edsl.aterm one) (Edsl.aterm other))

let law_naming_twice_is_naming_once () =
  (* Edges merge: store paths are unique in inputDrvs in 1293 of 1293 real
     derivations. *)
  for_each_intent 100 (fun i _ ->
      let d = build_intent i in
      let once = build_intent ~deps:[edge d] i
      and twice = build_intent ~deps:[edge d; edge d; edge d] i in
      Alcotest.(check string) "bytes" (Edsl.aterm once) (Edsl.aterm twice))

let law_what_it_builds_is_canonical () =
  for_each_intent 200 (fun i _ ->
      let d = (build_intent i).derivation in
      Alcotest.(check bool) "canonical" true (Edsl.canonical d = d))

let law_canonical_idempotent () =
  for_each_intent 200 (fun i _ ->
      let d = Edsl.canonical (build_intent i).derivation in
      Alcotest.(check bool) "idempotent" true (Edsl.canonical d = d))

let law_path_is_hash_of_bytes () =
  (* The store path is not metadata: it is a function of the file content. *)
  for_each_intent 200 (fun i _ ->
      let d = build_intent i in
      Alcotest.(check bool)
        "path"
        true
        (Store_path.equal d.path (Store.drv_path (Edsl.aterm d) i.i_name)))

let law_parser_reads_what_the_edsl_writes () =
  (* parse . unparse = id holds everywhere; unparse . parse = id holds only on
     CANONICAL text, which is exactly what the eDSL emits. *)
  for_each_intent 200 (fun i _ ->
      let d = build_intent i in
      let text = Edsl.aterm d in
      match Aterm.parse text with
      | Error e -> Alcotest.fail e
      | Ok read ->
          Alcotest.(check bool) "structural" true (read = d.derivation) ;
          Alcotest.(check string) "bytes" text (Aterm.unparse read))

let law_declaring_outputs_is_observable () =
  for_each_intent 200 (fun i _ ->
      let implicit = build_intent {i with i_outputs = None}
      and explicit = build_intent {i with i_outputs = Some ["out"]} in
      Alcotest.(check bool)
        "different bytes"
        false
        (String.equal (Edsl.aterm implicit) (Edsl.aterm explicit)))

let law_every_output_is_an_env_var () =
  (* Invariant 6 of spec/signature.md, for every intent rather than one. *)
  for_each_intent 200 (fun i _ ->
      let d = build_intent i in
      List.iter
        (fun (o : Derivation.output) ->
          match
            List.assoc_opt (Output_name.to_string o.name) d.derivation.env
          with
          | Some v ->
              Alcotest.(check string)
                "env holds the path"
                (Store_path.to_string o.path)
                v
          | None -> Alcotest.fail "output missing from env")
        d.derivation.outputs)

let law_input_hash_is_not_self_hash () =
  (* The asymmetry that cost this repository 145 downstream failures. *)
  for_each_intent 200 (fun i _ ->
      let d = build_intent i in
      let masked =
        Store.sha256_hex
          (Aterm.unparse_with
             d.derivation
             {Aterm.mask_outputs = true; input_hashes = None})
      in
      Alcotest.(check bool)
        "differ"
        false
        (Sha256_hex.equal d.input_hash masked))

let law_described_closure_verifies () =
  (* The strongest law available without invoking Nix: hand the eDSL's output
     to the same recursive path computation that reproduces 1259 of 1259 real
     output paths, reached by a different route. *)
  let st = seeded () in
  for _ = 1 to 20 do
    let a = gen_intent st and b = gen_intent st in
    let d1 = build_intent a in
    let d2 = build_intent ~deps:[edge d1] b in
    let dir = Filename.temp_file "img-drv-laws" "" in
    Sys.remove dir ;
    Unix.mkdir dir 0o755 ;
    ignore (Edsl.write d1 dir) ;
    ignore (Edsl.write d2 dir) ;
    (match Corpus.of_directory dir with
    | Error e -> Alcotest.fail e
    | Ok c ->
        let checked, bad = Corpus.verify c in
        List.iter (fun m -> print_endline (Corpus.mismatch_to_string m)) bad ;
        Alcotest.(check int) "no mismatches" 0 (List.length bad) ;
        Alcotest.(check bool) "checked something" true (checked >= 1)) ;
    List.iter
      (fun f -> Sys.remove (Filename.concat dir f))
      (Array.to_list (Sys.readdir dir)) ;
    Unix.rmdir dir
  done

let () =
  let case name f = Alcotest.test_case name `Quick f in
  Alcotest.run
    "img_drv"
    [
      ( "sha256",
        [
          case "published vectors" test_sha256_vectors;
          case "base32 round trip" test_base32_inverts;
        ] );
      ( "golden",
        [
          case "examples present" test_examples_present;
          case "round trips byte-identically" test_round_trips;
          case "every output path recomputes" test_every_output_path_recomputes;
          case
            "real derivations are canonical"
            test_real_derivations_are_canonical;
        ] );
      ( "edsl",
        [
          case "every golden has an intent" test_every_golden_has_an_intent;
          case "intents reproduce Nix byte for byte" test_intents_reproduce_nix;
          case
            "intents land at their own path"
            test_intents_land_at_their_own_path;
          case
            "output paths known in advance"
            test_output_paths_known_in_advance;
          case
            "declaring outputs is observable"
            test_declaring_outputs_is_observable;
          case
            "invalid names are unconstructible"
            test_invalid_names_are_unconstructible;
          case
            "a digest means the same however written"
            test_a_digest_means_the_same_however_written;
        ] );
      ( "laws",
        [
          case "same intent twice, same bytes" law_same_intent_twice;
          case
            "dependency order not observable"
            law_dependency_order_not_observable;
          case "naming twice is naming once" law_naming_twice_is_naming_once;
          case "what it builds is canonical" law_what_it_builds_is_canonical;
          case "canonical is idempotent" law_canonical_idempotent;
          case "path is the hash of the bytes" law_path_is_hash_of_bytes;
          case
            "parser reads what the eDSL writes"
            law_parser_reads_what_the_edsl_writes;
          case
            "declaring outputs is observable"
            law_declaring_outputs_is_observable;
          case "every output is an env var" law_every_output_is_an_env_var;
          case "input hash is not the self hash" law_input_hash_is_not_self_hash;
          case "a described closure verifies" law_described_closure_verifies;
        ] );
    ]
