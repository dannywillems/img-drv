(** Command line entry points, so CI and a laptop run the same code.

    {v
    img-drv verify <dir>      recompute every store path
    img-drv roundtrip <dir>   parse then re-serialize, byte for byte
    img-drv canonical <dir>   canonicalizing must change nothing
    img-drv examples <dir>    emit the conformance corpus
    img-drv transpile <dir>   emit the corpus as .nix expressions
    v}

    All exit non-zero on any failure, which is what makes them usable as CI
    gates. The subcommands and their output match the other three
    implementations', so one Makefile target can drive any of them. *)

open Img_drv

let read_file path =
  let ic = open_in_bin path in
  let n = in_channel_length ic in
  let s = really_input_string ic n in
  close_in ic ;
  s

let drv_files directory =
  Sys.readdir directory |> Array.to_list
  |> List.filter (fun f -> Filename.check_suffix f ".drv")
  |> List.sort String.compare

let verify directory =
  match Corpus.of_directory directory with
  | Error e ->
      prerr_endline e ;
      2
  | Ok c ->
      let checked, bad = Corpus.verify c in
      List.iter
        (fun m -> Printf.printf "FAIL %s\n" (Corpus.mismatch_to_string m))
        bad ;
      Printf.printf
        "%d/%d output paths reproduced from %d derivations\n"
        (checked - List.length bad)
        checked
        (Corpus.length c) ;
      if bad = [] then 0 else 1

let roundtrip directory =
  let ok = ref 0 and bad = ref 0 in
  List.iter
    (fun f ->
      let text = String.trim (read_file (Filename.concat directory f)) in
      match Aterm.parse text with
      | Error e ->
          incr bad ;
          Printf.printf "PARSE ERROR %s: %s\n" f e
      | Ok d ->
          if String.equal (Aterm.unparse d) text then incr ok
          else begin
            incr bad ;
            Printf.printf "ROUND-TRIP DIFFERS: %s\n" f
          end)
    (drv_files directory) ;
  Printf.printf "%d/%d round-tripped byte-identically\n" !ok (!ok + !bad) ;
  if !bad = 0 then 0 else 1

let canonical_check directory =
  let ok = ref 0 and bad = ref 0 in
  List.iter
    (fun f ->
      match Aterm.parse (read_file (Filename.concat directory f)) with
      | Error e ->
          incr bad ;
          Printf.printf "PARSE ERROR %s: %s\n" f e
      | Ok d ->
          if Edsl.canonical d = d then incr ok
          else begin
            incr bad ;
            Printf.printf "NOT CANONICAL: %s\n" f
          end)
    (drv_files directory) ;
  Printf.printf "%d/%d real derivations are already canonical\n" !ok (!ok + !bad) ;
  if !bad = 0 then 0 else 1

(** Emit every intent in the conformance corpus, named as in the store.

    The FILENAME is the derivation's own computed store path, so a wrong hash
    shows up as a differently named file rather than as differing content, and
    [make conformance] catches both. *)
let emit_examples directory =
  let rec mkdir_p d =
    if not (Sys.file_exists d) then begin
      mkdir_p (Filename.dirname d) ;
      try Unix.mkdir d 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
    end
  in
  mkdir_p directory ;
  let corpus = Examples.corpus () in
  List.iter (fun (_, d) -> ignore (Edsl.write d directory)) corpus ;
  Printf.printf "%d derivations written to %s\n" (List.length corpus) directory ;
  0

(** Emit each conformance intent as a `.nix` EXPRESSION.

    The other direction from `examples`: instead of building the IR and
    serializing `.drv`, this builds Nix syntax for real Nix to instantiate. The
    two must meet, which is what scripts/transpile-check.sh asserts. *)
let emit_nix directory =
  let rec mkdir_p d =
    if not (Sys.file_exists d) then begin
      mkdir_p (Filename.dirname d) ;
      try Unix.mkdir d 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
    end
  in
  mkdir_p directory ;
  let corpus = Img_drv_nix.Transpile_examples.corpus () in
  List.iter
    (fun (drv_name, e) ->
      let base = Filename.remove_extension drv_name ^ ".nix" in
      let oc = open_out_bin (Filename.concat directory base) in
      output_string oc (Img_drv_nix.Surface.to_nix e) ;
      output_string oc "\n" ;
      close_out oc)
    corpus ;
  Printf.printf "%d expressions written to %s\n" (List.length corpus) directory ;
  0

(** Materialise a real directory as a {!Img_drv.Nar.fso}.

    The library keeps no filesystem dependency, so the walk lives here. This is
    the only part of NAR that touches [unix], and it is deliberately the dull
    part: everything that decides the BYTES is a pure fold in the library. *)
let rec read_fso path =
  let stat = Unix.lstat path in
  match stat.Unix.st_kind with
  | Unix.S_LNK -> Nar.Symlink (Unix.readlink path)
  | Unix.S_DIR ->
      Nar.Directory
        (Sys.readdir path |> Array.to_list
        |> List.map (fun name -> (name, read_fso (Filename.concat path name))))
  | _ ->
      Nar.Regular
        {
          executable = stat.Unix.st_perm land 0o111 <> 0;
          contents = read_file path;
        }

(** Print the store path each entry of a directory would be added at.

    The differential oracle is [nix-store --add]: real Nix computes the same
    path from the same bytes, which is what [scripts/nar-check.sh] diffs. *)
let source_paths directory =
  Sys.readdir directory |> Array.to_list |> List.sort String.compare
  |> List.iter (fun name ->
      let fso = read_fso (Filename.concat directory name) in
      Printf.printf
        "%s\t%s\n"
        name
        (Types.Store_path.to_string (Nar.source_path ~name fso))) ;
  0

(** Evaluate a real [.nix] file and write every derivation it produces.

    The arrow the project existed to build, end to end and with no eDSL
    anywhere in it: TEXT -> parse -> EXPR -> eval -> DRV -> bytes. The gate is
    scripts/eval-check.sh, which asks a live nix-instantiate for the same file
    and diffs the [.drv] files byte for byte.

    Nothing here decides anything. It wires the store hook (a path literal has
    to be COPIED to the store, which needs NAR and a filesystem, neither of
    which the evaluator library has) and then writes what evaluation produced. *)
let eval_file directory =
  let file = Sys.getenv "EVAL_FILE" in
  let base = Filename.dirname file in
  (* The one injection: a path literal becomes a store path, and the string
     that results carries it in its context, which is what puts it in
     inputSrcs. *)
  (Img_drv_nix.Eval.add_to_store :=
     fun p ->
       let path =
         Nar.source_path ~name:(Filename.basename p) (read_fso p)
         |> Types.Store_path.to_string
       in
       ( path,
         Img_drv_nix.Value.Context.singleton (Img_drv_nix.Value.Opaque path) )) ;
  (* import and pathExists need the filesystem the evaluator library refuses to
     open itself. Same reason as the store hook above. *)
  Img_drv_nix.Builtins.read_source := read_file ;
  Img_drv_nix.Builtins.path_exists := Sys.file_exists ;
  (Img_drv_nix.Builtins.read_dir :=
     fun d -> Sys.readdir d |> Array.to_list |> List.sort String.compare) ;
  (Img_drv_nix.Builtins.file_type :=
     fun p ->
       match (Unix.lstat p).Unix.st_kind with
       | Unix.S_DIR -> "directory"
       | Unix.S_LNK -> "symlink"
       | _ -> "regular") ;
  (* builtins.toFile computes its store path in the evaluator; only the bytes
     are written here, and only so a builder could later read them. *)
  (Img_drv_nix.Builtins.write_to_store :=
     fun path text ->
       try
         let oc =
           open_out_bin (Filename.concat directory (Filename.basename path))
         in
         output_string oc text ;
         close_out oc
       with Sys_error _ -> ()) ;
  (* NIX_PATH, in the one form that matters here: entries of the shape
     name=/path, so that <name/sub> resolves to /path/sub. Impure, and pinned
     by whoever sets the variable. *)
  (Img_drv_nix.Eval.resolve_search_path :=
     fun spec ->
       let root, sub =
         match String.index_opt spec '/' with
         | Some i ->
             ( String.sub spec 0 i,
               String.sub spec (i + 1) (String.length spec - i - 1) )
         | None -> (spec, "")
       in
       let entries =
         String.split_on_char
           ':'
           (Option.value (Sys.getenv_opt "NIX_PATH") ~default:"")
       in
       let found =
         List.find_map
           (fun entry ->
             match String.index_opt entry '=' with
             | Some i when String.equal (String.sub entry 0 i) root ->
                 Some (String.sub entry (i + 1) (String.length entry - i - 1))
             | _ -> None)
           entries
       in
       match found with
       | None ->
           failwith (Printf.sprintf "file '%s' was not found in NIX_PATH" root)
       | Some base -> if sub = "" then base else Filename.concat base sub) ;
  Img_drv_nix.Derivation_primop.reset () ;
  match
    Img_drv_nix.Builtins.eval_file
      ~base
      ~home:(Option.value (Sys.getenv_opt "HOME") ~default:"/root")
      (read_file file)
  with
  | Error e ->
      prerr_endline e ;
      1
  | Ok _ ->
      (* Every derivation reached during evaluation, not merely the one the
         expression returned: a dependency is a derivation too, and Nix writes
         the whole closure. *)
      let n = ref 0 in
      Hashtbl.iter
        (fun _ (d : Edsl.drv) ->
          incr n ;
          ignore (Edsl.write d directory))
        Img_drv_nix.Derivation_primop.store ;
      Printf.printf "%d derivations\n" !n ;
      0

(** Emit the derivation that depends on [scripts/probe-src.txt].

    Exercises the whole chain: NAR bytes, their hash, the [source] store path,
    the [inputSrcs] field, and the `.drv`'s own path, which must list the source
    as a reference. *)
let emit_srcdrv directory =
  let file = "/w/scripts/probe-src.txt" in
  let src =
    Nar.source_path ~name:"probe-src.txt" (read_fso file)
    |> Types.Store_path.to_string
  in
  ignore (Edsl.write (Examples.with_src src) directory) ;
  Printf.printf "source at %s\n" src ;
  0

(** Emit the differential probe's derivations, named as in the store. *)
let emit_probe directory =
  let corpus = Examples.probe_corpus () in
  List.iter (fun d -> ignore (Edsl.write d directory)) corpus ;
  Printf.printf "%d probe derivations written\n" (List.length corpus) ;
  0

(** Emit the worked example: a real package, through a real overlay. *)
let emit_worked directory =
  let rec mkdir_p d =
    if not (Sys.file_exists d) then begin
      mkdir_p (Filename.dirname d) ;
      try Unix.mkdir d 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
    end
  in
  mkdir_p directory ;
  let oc = open_out_bin (Filename.concat directory "worked-example.nix") in
  output_string
    oc
    (Img_drv_nix.Surface.to_nix (Img_drv_nix.Worked_example.term ())) ;
  output_string oc "\n" ;
  close_out oc ;
  print_endline "worked example written" ;
  0

(** Differential-test the PARSER against real Nix, on real expressions.

    [directory] holds pairs: [x.nix] is the source and [x.expected] is what the
    pinned [nix-instantiate --parse] printed for it. We parse [x.nix] and print
    in the same form; the two must match byte for byte.

    This pins tree SHAPE rather than merely "it parsed", which is the whole
    reason the oracle is [--parse] and not a plain evaluation. Two things to
    know about it, both recorded in
    [docs/decisions/2026-08-02-nix-frontend-build-not-reuse.md]: it performs
    static scope resolution and so REJECTS a file with a free variable, and it
    prints a DESUGARED tree, so our printer has to reproduce the desugaring and
    not just the parse. Files Nix itself refuses are skipped by the harness
    before they get here. *)
let parse_check directory =
  let expected =
    Sys.readdir directory |> Array.to_list
    |> List.filter (fun f -> Filename.check_suffix f ".expected")
    |> List.sort compare
  in
  let read path =
    let ic = open_in_bin path in
    let n = in_channel_length ic in
    let s = really_input_string ic n in
    close_in ic ;
    s
  in
  (* Nix expands `~` at parse time, so the harness records the oracle's HOME
     and it is replayed here; without it a tilde path resolves differently in
     the two containers. *)
  let home =
    let p = Filename.concat directory "home" in
    if Sys.file_exists p then String.trim (read p) else ""
  in
  let ok = ref 0 and bad = ref 0 in
  (* The harness names each pair by index because the pinned Nix image has no
     sed to flatten a path with, so the real path is carried alongside. *)
  let origin base =
    let p = Filename.concat directory (base ^ ".path") in
    if Sys.file_exists p then String.trim (read p) else base
  in
  List.iter
    (fun exp_file ->
      let base = Filename.remove_extension exp_file in
      let src = read (Filename.concat directory (base ^ ".nix")) in
      let want = String.trim (read (Filename.concat directory exp_file)) in
      (* Nix resolves a relative path against the directory of the file it is
         written in, so the parser has to be told where the source came from or
         every `./foo.nix` prints differently. *)
      let source_dir = Filename.dirname (origin base) in
      match Img_drv_nix.Nix.parse_and_print ~base:source_dir ~home src with
      | Ok got when String.equal (String.trim got) want -> incr ok
      | Ok got ->
          incr bad ;
          if !bad <= 5 then begin
            (* Real nixpkgs expressions print to thousands of characters, so
               showing both in full says nothing. Show the first divergence
               with a window either side, which is where the bug is. *)
            let got = String.trim got in
            let n = min (String.length want) (String.length got) in
            let rec first i =
              if i >= n then n
              else if want.[i] = got.[i] then first (i + 1)
              else i
            in
            let d = first 0 in
            let window s =
              let from = max 0 (d - 30) in
              let len = min 90 (String.length s - from) in
              String.sub s from len
            in
            Printf.printf "MISMATCH %s (at offset %d)\n" (origin base) d ;
            Printf.printf "  want ...%s...\n" (window want) ;
            Printf.printf "  got  ...%s...\n" (window got)
          end
      | Error msg ->
          incr bad ;
          if !bad <= 5 then
            Printf.printf "PARSE FAILED %s: %s\n" (origin base) msg)
    expected ;
  Printf.printf
    "%d/%d real nixpkgs expressions parse to the same tree as Nix\n"
    !ok
    (!ok + !bad) ;
  if !bad = 0 then 0 else 1

(** The RETRACTION law: parsing what we printed gives back the same tree.

    [emit] and [parse] are the two arrows between EXPR and source text, and
    until now they were never composed. Their law is

      parse (emit e) = e

    which makes [emit] a SECTION, [parse] a RETRACTION, and EXPR a RETRACT of
    text. Not an isomorphism: [emit (parse t)] loses comments and formatting,
    so [parse] is not injective. What DOES follow is that [emit . parse] is
    IDEMPOTENT, since

      (emit . parse) . (emit . parse) = emit . (parse . emit) . parse
                                      = emit . parse

    so it is a canonical-form projection on source text, structurally the same
    object as the canonical `.drv` form in [docs/abstractions.md] entry 1.

    That idempotence is what this checks, and it is why the check is nearly
    free: every file in the parser's corpus is a term to test [emit] on. The
    transpiler had been verified on ELEVEN hand-written intents while the
    parser was verified on thousands of real files, so composing them moves the
    corpus from the well-tested arrow to the under-tested one. *)
let reparse directory =
  let files =
    Sys.readdir directory |> Array.to_list
    |> List.filter (fun f -> Filename.check_suffix f ".nix")
    |> List.sort compare
  in
  let home =
    let p = Filename.concat directory "home" in
    if Sys.file_exists p then String.trim (read_file p) else ""
  in
  let origin base =
    let p = Filename.concat directory (base ^ ".path") in
    if Sys.file_exists p then String.trim (read_file p) else base
  in
  let ok = ref 0 and bad = ref 0 in
  List.iter
    (fun f ->
      let base = Filename.remove_extension f in
      let src = read_file (Filename.concat directory f) in
      let dir = Filename.dirname (origin base) in
      match Img_drv_nix.Nix.parse_string ~base:dir ~home src with
      | Error _ -> ()
      | Ok tree -> (
          let printed = Img_drv_nix.Emit.to_string tree in
          match Img_drv_nix.Nix.parse_string ~base:dir ~home printed with
          | Error msg ->
              incr bad ;
              if !bad <= 5 then
                Printf.printf
                  "EMITTED SOURCE DOES NOT PARSE %s: %s\n"
                  (origin base)
                  msg
          | Ok again ->
              let norm = Img_drv_nix.Normalize.expr in
              if norm again = norm tree then incr ok
              else begin
                incr bad ;
                if !bad <= 5 then begin
                  let a = Img_drv_nix.Printer.to_string (norm tree) in
                  let b = Img_drv_nix.Printer.to_string (norm again) in
                  let n = min (String.length a) (String.length b) in
                  let rec first i =
                    if i >= n then n
                    else if a.[i] = b.[i] then first (i + 1)
                    else i
                  in
                  let d = first 0 in
                  let window s =
                    let from = max 0 (d - 30) in
                    String.sub s from (min 90 (String.length s - from))
                  in
                  Printf.printf
                    "ROUND TRIP DIFFERS %s (at offset %d)\n"
                    (origin base)
                    d ;
                  Printf.printf "  before ...%s...\n" (window a) ;
                  Printf.printf "  after  ...%s...\n" (window b)
                end
              end))
    files ;
  Printf.printf
    "%d/%d real expressions survive emit then parse unchanged\n"
    !ok
    (!ok + !bad) ;
  if !bad = 0 then 0 else 1

let () =
  match Sys.argv with
  | [|_; command; directory|] ->
      let needs_dir =
        not
          (String.equal command "examples"
          || String.equal command "transpile"
          || String.equal command "worked")
      in
      if
        needs_dir
        && not (Sys.file_exists directory && Sys.is_directory directory)
      then begin
        Printf.eprintf "not a directory: %s\n" directory ;
        exit 2
      end ;
      let code =
        match command with
        | "verify" -> verify directory
        | "roundtrip" -> roundtrip directory
        | "canonical" -> canonical_check directory
        | "examples" -> emit_examples directory
        | "transpile" -> emit_nix directory
        | "parsecheck" -> parse_check directory
        | "reparse" -> reparse directory
        | "worked" -> emit_worked directory
        | "probe" -> emit_probe directory
        | "source" -> source_paths directory
        | "srcdrv" -> emit_srcdrv directory
        | "eval" -> eval_file directory
        | other ->
            Printf.eprintf "unknown command: %s\n" other ;
            exit 2
      in
      exit code
  | _ ->
      prerr_endline
        "usage: img-drv \
         [verify|roundtrip|canonical|examples|transpile|parsecheck|reparse|worked|probe|source|srcdrv] \
         <directory>" ;
      exit 2
