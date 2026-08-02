(** The eDSL surface: DESCRIBE a build, and get a derivation back.

    This is the TYPED REFERENCE, and the place to look for what a strong type
    system actually buys. Three things here are unavailable to the other
    implementations:

    - every finite sum is a VARIANT, so [Sha3] is not a value that exists, and
      a [match] that forgets a case does not compile. Go has to check a string
      at runtime; Python's [Literal] is erased and needs the same check;
    - [outputs] is a native [option], so the Option that Go had to encode three
      different ways is spelled once;
    - names are {!Types.Name.t}, which is ABSTRACT and validated on
      construction. The consequence is visible in {!error} below: there is no
      [Invalid_name] case, because by the time [derive] is called an invalid
      name is not a value that can exist. Python, Rust and Go all carry that
      error case. *)

open Types

(** The hash algorithms Nix accepts for a fixed-output derivation. *)
type hash_algo = Md5 | Sha1 | Sha256 | Sha512

(** How the output is ingested: a single file, or a NAR of a directory tree.

    [Recursive] is what puts the [r:] prefix on the serialized algorithm, and
    [r:sha256] selects an entirely different store-path scheme. *)
type hash_mode = Flat | Recursive

let algo_to_string = function
  | Md5 -> "md5"
  | Sha1 -> "sha1"
  | Sha256 -> "sha256"
  | Sha512 -> "sha512"

let algo_of_string = function
  | "md5" -> Some Md5
  | "sha1" -> Some Sha1
  | "sha256" -> Some Sha256
  | "sha512" -> Some Sha512
  | _ -> None

let digest_bytes = function
  | Md5 -> 16
  | Sha1 -> 20
  | Sha256 -> 32
  | Sha512 -> 64

let mode_to_string = function Flat -> "flat" | Recursive -> "recursive"

(** A description that violates an invariant in [docs/spec/signature.md].

    Note what is ABSENT: no [Invalid_name]. A name is a {!Types.Name.t}, which
    cannot be constructed unless it is valid, so that failure mode is not
    reachable from here and does not need a case. This is the concrete payoff of
    an abstract type, and it is the one row of the typing table no other
    implementation in this repository can fill. *)
type error =
  | Empty_outputs
  | Duplicate_outputs of string list
  | Fixed_needs_one_output of string list
  | Reserved_env_keys of string list
  | No_such_output of {drv : string; wanted : string; have : string list}
  | Invalid_hash of string

let error_to_string = function
  | Empty_outputs -> "outputs must not be empty"
  | Duplicate_outputs n ->
      Printf.sprintf "duplicate output names in [%s]" (String.concat "; " n)
  | Fixed_needs_one_output n ->
      Printf.sprintf
        "a fixed-output derivation has exactly one output, got [%s]"
        (String.concat "; " n)
  | Reserved_env_keys k ->
      Printf.sprintf
        "env keys [%s] are derived from the other fields; set them through \
         name/system/builder/outputs/fixed_output"
        (String.concat "; " k)
  | No_such_output {drv; wanted; have} ->
      Printf.sprintf
        "%S has no output %S; it has [%s]"
        drv
        wanted
        (String.concat "; " have)
  | Invalid_hash why -> why

(** A declared result: the derivation's identity comes from this hash.

    [hash] is kept EXACTLY as written, because that is what reaches the env,
    while the outputs tuple carries it re-encoded as hex. [algo] may be [None]
    when [hash] is SRI ([sha256-<base64>]), which already names its algorithm:
    11 of the 93 real fixed-output derivations carry no [outputHashAlgo]. *)
type fixed_output = {hash : string; algo : hash_algo option; mode : hash_mode}

let fixed ?(mode = Flat) ~algo hash = {hash; algo = Some algo; mode}

let sri ?(mode = Flat) hash = {hash; algo = None; mode}

let b64_alphabet =
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

(** Base-64 decoding, written out because OCaml's standard library has none and
    a dependency for twenty lines would need approval. *)
let b64_decode text =
  let n = String.length text in
  if n = 0 || n mod 4 <> 0 then Error (Printf.sprintf "not base-64: %S" text)
  else
    let buf = Buffer.create (n / 4 * 3) in
    let bad = ref false in
    let i = ref 0 in
    while (not !bad) && !i < n do
      let acc = ref 0 and pad = ref 0 in
      for j = 0 to 3 do
        let c = text.[!i + j] in
        acc := !acc lsl 6 ;
        if Char.equal c '=' then incr pad
        else
          match String.index_opt b64_alphabet c with
          | Some v when !pad = 0 -> acc := !acc lor v
          | _ -> bad := true
      done ;
      if (not !bad) && !pad <= 2 then begin
        Buffer.add_char buf (Char.chr ((!acc lsr 16) land 0xff)) ;
        if !pad < 2 then Buffer.add_char buf (Char.chr ((!acc lsr 8) land 0xff)) ;
        if !pad < 1 then Buffer.add_char buf (Char.chr (!acc land 0xff))
      end
      else bad := true ;
      i := !i + 4
    done ;
    if !bad then Error (Printf.sprintf "not base-64: %S" text)
    else Ok (Buffer.to_bytes buf)

let hex_decode text =
  let n = String.length text in
  if n mod 2 <> 0 then Error (Printf.sprintf "not hex: %S" text)
  else
    try
      Ok
        (Bytes.init (n / 2) (fun i ->
             Char.chr (int_of_string ("0x" ^ String.sub text (i * 2) 2))))
    with _ -> Error (Printf.sprintf "not hex: %S" text)

(** [(algorithm, hex digest)], decoded from whatever representation was written.

    Accepts hex, Nix base-32, base-64 and SRI. The corpus contains SRI and
    base-32 and no hex at all, so an implementation that accepts only hex parses
    nothing real. *)
let resolve f =
  let ( let* ) = Result.bind in
  let decoded =
    match String.index_opt f.hash '-' with
    | Some i ->
        let prefix = String.sub f.hash 0 i in
        let body = String.sub f.hash (i + 1) (String.length f.hash - i - 1) in
        let* algo =
          match algo_of_string prefix with
          | Some a -> Ok a
          | None -> Error (Printf.sprintf "unknown hash algorithm %S" prefix)
        in
        let* () =
          match f.algo with
          | Some declared when declared <> algo ->
              Error
                (Printf.sprintf
                   "algo=%s contradicts the SRI prefix %S"
                   (algo_to_string declared)
                   prefix)
          | _ -> Ok ()
        in
        let* raw = b64_decode body in
        Ok (algo, raw)
    | None ->
        let* algo =
          match f.algo with
          | Some a -> Ok a
          | None -> Error "algo is required unless the hash is SRI (sha256-...)"
        in
        let size = digest_bytes algo in
        let* raw =
          if String.length f.hash = size * 2 then hex_decode f.hash
          else if String.length f.hash = Store.base32_length size then
            Store.base32_decode f.hash size
          else b64_decode f.hash
        in
        Ok (algo, raw)
  in
  match decoded with
  | Error e -> Error (Invalid_hash e)
  | Ok (algo, raw) ->
      if Bytes.length raw <> digest_bytes algo then
        Error
          (Invalid_hash
             (Printf.sprintf
                "%s needs %d bytes, got %d"
                (algo_to_string algo)
                (digest_bytes algo)
                (Bytes.length raw)))
      else Ok (algo, Sha256.to_hex raw)

let hash_algo_field f =
  Result.map
    (fun (algo, _) ->
      match f.mode with
      | Recursive -> "r:" ^ algo_to_string algo
      | Flat -> algo_to_string algo)
    (resolve f)

(** The env entries Nix synthesizes for a fixed-output derivation.

    [outputHashAlgo] is omitted for an SRI hash, matching what real Nix emits;
    writing it anyway would change the bytes. *)
let fixed_env f =
  [("outputHash", f.hash); ("outputHashMode", mode_to_string f.mode)]
  @
  match f.algo with
  | Some a -> [("outputHashAlgo", algo_to_string a)]
  | None -> []

(** An edge: a derivation, and the outputs of it actually needed. *)
type dep = {
  dep_path : Store_path.t;
  dep_input_hash : Sha256_hex.t;
  dep_outputs : Output_name.t list;
}

(** A described derivation, and everything derivable from it. *)
type drv = {
  derivation : Derivation.t;
  path : Store_path.t;
  input_hash : Sha256_hex.t;
}

let output d name =
  match
    List.find_opt
      (fun (o : Derivation.output) ->
        String.equal (Output_name.to_string o.name) name)
      d.derivation.outputs
  with
  | Some o -> Ok o.path
  | None ->
      Error
        (No_such_output
           {
             drv = Derivation.name d.derivation;
             wanted = name;
             have = Derivation.output_names d.derivation;
           })

(** An edge to this derivation, needing [outputs] (empty means [out]). *)
let needs d outputs =
  let wanted = if outputs = [] then ["out"] else outputs in
  let rec go acc = function
    | [] -> Ok (List.sort_uniq String.compare (List.rev acc))
    | n :: rest -> (
        match output d n with Error e -> Error e | Ok _ -> go (n :: acc) rest)
  in
  Result.map
    (fun names ->
      {
        dep_path = d.path;
        dep_input_hash = d.input_hash;
        dep_outputs = List.map Output_name.v names;
      })
    (go [] wanted)

(** The canonical bytes. These ARE the artifact: [path] is their hash. *)
let aterm d = Aterm.unparse d.derivation

let write d directory =
  let base = Filename.basename (Store_path.to_string d.path) in
  let target = Filename.concat directory base in
  let oc = open_out_bin target in
  output_string oc (aterm d) ;
  close_out oc ;
  target

(** Put a derivation into canonical form.

    The orderings, all load-bearing ([spec/canonical.md]): outputs by name, env
    by key, [inputDrvs] by store path with each inner name list sorted,
    [inputSrcs] ascending. [args] keeps its order, because there it is the
    meaning. *)
let canonical (d : Derivation.t) : Derivation.t =
  let by f a b = compare (f a) (f b) in
  {
    d with
    outputs =
      List.stable_sort
        (by (fun (o : Derivation.output) -> Output_name.to_string o.name))
        d.outputs;
    input_drvs =
      List.stable_sort
        (by (fun (i : Derivation.input_drv) -> Store_path.to_string i.path))
        (List.map
           (fun (i : Derivation.input_drv) ->
             {
               i with
               Derivation.outputs =
                 List.sort_uniq
                   (fun a b ->
                     String.compare
                       (Output_name.to_string a)
                       (Output_name.to_string b))
                   i.outputs;
             })
           d.input_drvs);
    input_srcs =
      List.sort_uniq
        (fun a b ->
          String.compare (Store_path.to_string a) (Store_path.to_string b))
        d.input_srcs;
    env = List.stable_sort compare d.env;
  }

(** A build description: the first-order signature, as a product.

    [outputs] is [None] when undeclared, which is a DIFFERENT derivation from
    [Some [out]]: Nix emits an [outputs] env variable exactly when the caller
    declared the attribute, and both occur in real nixpkgs. See
    [spec/canonical.md] section 1.7. *)
type build = {
  name : Name.t;
  system : string;
  builder : string;
  args : string list;
  env : (string * string) list;
  outputs : Name.t list option;
  input_drvs : dep list;
  input_srcs : Store_path.t list;
  fixed_output : fixed_output option;
}

let build ?(args = []) ?(env = []) ?outputs ?(input_drvs = [])
    ?(input_srcs = []) ?fixed_output ~name ~system ~builder () =
  {
    name;
    system;
    builder;
    args;
    env;
    outputs;
    input_drvs;
    input_srcs;
    fixed_output;
  }

let reserved_keys =
  [
    "name";
    "system";
    "builder";
    "outputs";
    "outputHash";
    "outputHashAlgo";
    "outputHashMode";
  ]

let merge_edges deps =
  let tbl = Hashtbl.create 8 in
  List.iter
    (fun d ->
      let key = Store_path.to_string d.dep_path in
      match Hashtbl.find_opt tbl key with
      | Some existing ->
          Hashtbl.replace
            tbl
            key
            {existing with dep_outputs = existing.dep_outputs @ d.dep_outputs}
      | None -> Hashtbl.replace tbl key d)
    deps ;
  Hashtbl.fold (fun _ v acc -> v :: acc) tbl []
  |> List.map (fun d ->
      {
        d with
        dep_outputs =
          List.sort_uniq
            (fun a b ->
              String.compare (Output_name.to_string a) (Output_name.to_string b))
            d.dep_outputs;
      })
  |> List.stable_sort (fun a b ->
      String.compare
        (Store_path.to_string a.dep_path)
        (Store_path.to_string b.dep_path))

(** Describe a build. This is the whole eDSL. *)
let derive (b : build) : (drv, error) result =
  let ( let* ) = Result.bind in
  let names =
    match b.outputs with Some l -> List.map Name.to_string l | None -> ["out"]
  in
  let* () = if names = [] then Error Empty_outputs else Ok () in
  let* () =
    if List.length (List.sort_uniq String.compare names) <> List.length names
    then Error (Duplicate_outputs names)
    else Ok ()
  in
  let* () =
    match b.fixed_output with
    | Some _ when List.length names <> 1 -> Error (Fixed_needs_one_output names)
    | _ -> Ok ()
  in
  let blocked = reserved_keys @ names in
  let clashes =
    List.sort_uniq
      String.compare
      (List.filter (fun (k, _) -> List.mem k blocked) b.env |> List.map fst)
  in
  let* () = if clashes = [] then Ok () else Error (Reserved_env_keys clashes) in
  let* algo, digest =
    match b.fixed_output with
    | None -> Ok ("", "")
    | Some f ->
        let* a = hash_algo_field f in
        let* _, d = resolve f in
        Ok (a, d)
  in
  let name = Name.to_string b.name in
  let synthesized =
    [("name", name); ("system", b.system); ("builder", b.builder)]
    @ (match b.outputs with
      | Some _ -> [("outputs", String.concat " " names)]
      | None -> [])
    @ (match b.fixed_output with Some f -> fixed_env f | None -> [])
    (* Placeholders. The real paths are the hash of the derivation that
       contains them, so they cannot be known until the next step, and the
       masked form used to compute them blanks these anyway. *)
    @ List.map (fun n -> (n, "")) names
  in
  let env =
    List.filter (fun (k, _) -> not (List.mem_assoc k synthesized)) b.env
    @ synthesized
  in
  let edges = merge_edges b.input_drvs in
  let draft =
    canonical
      {
        Derivation.outputs =
          List.map
            (fun n ->
              {
                Derivation.name = Output_name.v n;
                path = Store_path.v "";
                hash_algo = algo;
                hash = digest;
              })
            names;
        input_drvs =
          List.map
            (fun d -> {Derivation.path = d.dep_path; outputs = d.dep_outputs})
            edges;
        input_srcs = b.input_srcs;
        system = b.system;
        builder = b.builder;
        args = b.args;
        env;
      }
  in
  let input_hashes =
    List.map
      (fun d -> (d.dep_path, Sha256_hex.to_string d.dep_input_hash))
      edges
  in
  let paths = Store.output_paths draft name input_hashes in
  let lookup n =
    List.assoc_opt n paths
    |> Option.map Store_path.to_string
    |> Option.value ~default:""
  in
  let final =
    {
      draft with
      Derivation.outputs =
        List.map
          (fun (o : Derivation.output) ->
            {o with Derivation.path = Store_path.v (lookup o.name)})
          draft.outputs;
      env =
        List.map
          (fun (k, v) ->
            match List.assoc_opt (Output_name.v k) paths with
            | Some p -> (k, Store_path.to_string p)
            | None -> (k, v))
          draft.env;
    }
  in
  let text = Aterm.unparse final in
  let input_hash =
    match Derivation.fixed_output final with
    | Some f -> Store.fixed_output_input_hash f
    | None ->
        Store.sha256_hex
          (Aterm.unparse_with
             final
             {Aterm.mask_outputs = false; input_hashes = Some input_hashes})
  in
  Ok {derivation = final; path = Store.drv_path text name; input_hash}
