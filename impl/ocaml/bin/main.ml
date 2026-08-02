(** Command line entry points, so CI and a laptop run the same code.

    {v
    img-drv verify <dir>      recompute every store path
    img-drv roundtrip <dir>   parse then re-serialize, byte for byte
    img-drv canonical <dir>   canonicalizing must change nothing
    img-drv examples <dir>    emit the conformance corpus
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

let () =
  match Sys.argv with
  | [|_; command; directory|] ->
      let needs_dir = not (String.equal command "examples") in
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
        | other ->
            Printf.eprintf "unknown command: %s\n" other ;
            exit 2
      in
      exit code
  | _ ->
      prerr_endline
        "usage: img-drv [verify|roundtrip|canonical|examples] <directory>" ;
      exit 2
