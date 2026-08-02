(** A closure of derivations, and the recursive hashing over it.

    A real closure is a DAG with heavy sharing: a 226-derivation closure hashes
    the same bootstrap tools hundreds of times. The memo table is what makes
    verification linear in the number of edges rather than exponential in depth.

    Structurally this is a fold over a DAG, defined by WELL-FOUNDED recursion:
    the graph is finite and acyclic, so the recursion terminates and picks out
    exactly one function, which is why every conforming implementation in any
    language must produce the same digests. See [docs/abstractions.md] entry 2.
    *)

open Types

(** A store path basename is [<32 base-32 chars>-<name>]. *)
let hash_len = 32

(** The derivation name that output paths are suffixed with.

    A real store path is [<32 chars>-<name>.drv], so the hash prefix is
    stripped. When the file is not named that way, fall back to the [name]
    environment variable, which every derivation carries. *)
let name_from_path path (d : Derivation.t option) =
  let base = Filename.basename (Store_path.to_string path) in
  let base = Filename.remove_extension base in
  let stripped =
    match String.index_opt base '-' with
    | Some i when i = hash_len ->
        let head = String.sub base 0 i in
        if
          String.for_all (fun c -> String.contains Store.base32_alphabet c) head
        then Some (String.sub base (i + 1) (String.length base - i - 1))
        else None
    | _ -> None
  in
  match stripped with
  | Some t -> t
  | None -> (
      match d with
      | Some d when not (String.equal (Derivation.name d) "") ->
          Derivation.name d
      | _ -> base)

(** One output whose recomputed path differs from the recorded one. *)
type mismatch = {
  drv_name : string;
  output : Output_name.t;
  expected : Store_path.t;
  got : Store_path.t option;
}

let mismatch_to_string m =
  Printf.sprintf
    "%s:%s\n  expected %s\n  got      %s"
    m.drv_name
    (Output_name.to_string m.output)
    (Store_path.to_string m.expected)
    (match m.got with Some p -> Store_path.to_string p | None -> "<none>")

(** A set of derivations indexed by store path.

    Not every input is necessarily present: a closure exported from a store is
    complete, but a hand-assembled directory need not be. Inputs that are absent
    are left as paths, which is why an incomplete corpus produces mismatches
    rather than silence. *)
type t = {drvs : (string * Derivation.t) list}

let drv_files directory =
  Sys.readdir directory |> Array.to_list
  |> List.filter (fun f -> Filename.check_suffix f ".drv")
  |> List.sort String.compare

let read_file path =
  let ic = open_in_bin path in
  let n = in_channel_length ic in
  let s = really_input_string ic n in
  close_in ic ;
  s

(** Load every [*.drv] in a directory, keyed by its store path. *)
let of_directory directory =
  let rec go acc = function
    | [] -> Ok {drvs = List.rev acc}
    | f :: rest -> (
        match Aterm.parse (read_file (Filename.concat directory f)) with
        | Error e -> Error (Printf.sprintf "%s: %s" f e)
        | Ok d -> go ((Store.store ^ "/" ^ f, d) :: acc) rest)
  in
  go [] (drv_files directory)

let length c = List.length c.drvs

(** The hash by which a derivation is known when it is someone's INPUT.

    Outputs are NOT masked here; that is the asymmetry documented in
    {!Store.output_paths} and in [docs/theory.md] section 7. *)
let rec input_hash c memo path =
  match Hashtbl.find_opt memo path with
  | Some h -> Some h
  | None -> (
      match List.assoc_opt path c.drvs with
      | None -> None
      | Some d ->
          let h =
            match Derivation.fixed_output d with
            | Some f -> Store.fixed_output_input_hash f
            | None ->
                Store.sha256_hex
                  (Aterm.unparse_with
                     d
                     {
                       Aterm.mask_outputs = false;
                       input_hashes = Some (input_hashes_of c memo d);
                     })
          in
          Hashtbl.replace memo path h ;
          Some h)

and input_hashes_of c memo (d : Derivation.t) =
  List.filter_map
    (fun (i : Derivation.input_drv) ->
      match input_hash c memo (Store_path.to_string i.path) with
      | Some h -> Some (i.path, Sha256_hex.to_string h)
      | None -> None)
    d.input_drvs

(** Recompute every output path and compare with the recorded one.

    These are real derivations produced by real Nix, so this is a regression
    test against vectors nobody wrote by hand. *)
let verify c =
  (* One memo table for the whole corpus, not one per derivation: sharing is
     what makes this linear in edges. *)
  let memo = Hashtbl.create 512 in
  List.fold_left
    (fun (checked, bad) (path, d) ->
      let name = name_from_path (Store_path.v path) (Some d) in
      let got = Store.output_paths d name (input_hashes_of c memo d) in
      List.fold_left
        (fun (checked, bad) (o : Derivation.output) ->
          let computed = List.assoc_opt o.name got in
          if computed = Some o.path then (checked + 1, bad)
          else
            ( checked + 1,
              {
                drv_name = name;
                output = o.name;
                expected = o.path;
                got = computed;
              }
              :: bad ))
        (checked, bad)
        d.outputs)
    (0, [])
    c.drvs
  |> fun (checked, bad) -> (checked, List.rev bad)
