(** The ATerm reader and writer.

    A hand-written recursive-descent parser, and NOT a regex, for the reason
    recorded in AGENTS.md: a regex-based reader of derivations passed 12 of 12
    hand-written examples and then failed 323 of 403 real ones. *)

open Types

exception Parse_error of string * int

type cursor = {text : string; mutable pos : int}

let fail c what = raise (Parse_error (what, c.pos))

let peek c = if c.pos >= String.length c.text then None else Some c.text.[c.pos]

let expect c ch =
  match peek c with
  | Some x when Char.equal x ch -> c.pos <- c.pos + 1
  | _ -> fail c (Printf.sprintf "%C" ch)

let literal c s =
  let n = String.length s in
  if
    c.pos + n <= String.length c.text
    && String.equal (String.sub c.text c.pos n) s
  then c.pos <- c.pos + n
  else fail c s

(** A double-quoted string, undoing exactly the five escapes.

    Every other byte is taken literally, INCLUDING other control characters. An
    implementation that also decodes [\uXXXX], as JSON does, reads a different
    language. *)
let string_lit c =
  expect c '"' ;
  let b = Buffer.create 32 in
  let rec go () =
    match peek c with
    | None -> fail c "closing quote"
    | Some '"' -> c.pos <- c.pos + 1
    | Some '\\' -> (
        c.pos <- c.pos + 1 ;
        match peek c with
        | None -> fail c "escape character"
        | Some e ->
            c.pos <- c.pos + 1 ;
            Buffer.add_char
              b
              (match e with 'n' -> '\n' | 'r' -> '\r' | 't' -> '\t' | x -> x) ;
            go ())
    | Some x ->
        c.pos <- c.pos + 1 ;
        Buffer.add_char b x ;
        go ()
  in
  go () ;
  Buffer.contents b

let list_of c item =
  expect c '[' ;
  match peek c with
  | Some ']' ->
      c.pos <- c.pos + 1 ;
      []
  | _ ->
      let rec go acc =
        let v = item c in
        match peek c with
        | Some ',' ->
            c.pos <- c.pos + 1 ;
            go (v :: acc)
        | Some ']' ->
            c.pos <- c.pos + 1 ;
            List.rev (v :: acc)
        | _ -> fail c "',' or ']'"
      in
      go []

let output c =
  expect c '(' ;
  let name = Output_name.v (string_lit c) in
  expect c ',' ;
  let path = Store_path.v (string_lit c) in
  expect c ',' ;
  let hash_algo = string_lit c in
  expect c ',' ;
  let hash = string_lit c in
  expect c ')' ;
  {Derivation.name; path; hash_algo; hash}

let input_drv c =
  expect c '(' ;
  let path = Store_path.v (string_lit c) in
  expect c ',' ;
  let outputs = list_of c (fun q -> Output_name.v (string_lit q)) in
  expect c ')' ;
  {Derivation.path; outputs}

let env_entry c =
  expect c '(' ;
  let k = string_lit c in
  expect c ',' ;
  let v = string_lit c in
  expect c ')' ;
  (k, v)

(** Read a derivation from its ATerm text.

    A trailing newline is tolerated, because a [.drv] checked into a repository
    has one and the store object does not. *)
let parse text =
  let c = {text = String.trim text; pos = 0} in
  try
    literal c "Derive(" ;
    let outputs = list_of c output in
    expect c ',' ;
    let input_drvs = list_of c input_drv in
    expect c ',' ;
    let input_srcs = list_of c (fun q -> Store_path.v (string_lit q)) in
    expect c ',' ;
    let system = string_lit c in
    expect c ',' ;
    let builder = string_lit c in
    expect c ',' ;
    let args = list_of c string_lit in
    expect c ',' ;
    let env = list_of c env_entry in
    expect c ')' ;
    Ok {Derivation.outputs; input_drvs; input_srcs; system; builder; args; env}
  with Parse_error (what, at) ->
    Error (Printf.sprintf "expected %s at byte %d" what at)

(** Apply exactly the five ATerm escapes, and nothing else. *)
let escape s =
  let b = Buffer.create (String.length s) in
  String.iter
    (fun ch ->
      match ch with
      | '"' -> Buffer.add_string b "\\\""
      | '\\' -> Buffer.add_string b "\\\\"
      | '\n' -> Buffer.add_string b "\\n"
      | '\r' -> Buffer.add_string b "\\r"
      | '\t' -> Buffer.add_string b "\\t"
      | x -> Buffer.add_char b x)
    s ;
  Buffer.contents b

let quote s = "\"" ^ escape s ^ "\""

(** How to serialize: the two variants needed for hashing.

    Getting either backwards yields a syntactically perfect derivation with
    wrong paths, which is worse than an error because it looks correct. *)
type options = {
  mask_outputs : bool;
      (** Blank this derivation's own output paths, in the outputs list AND in
          the env entries whose KEY is an output name. It must NOT blank an
          output path that merely appears inside some other value. *)
  input_hashes : (Store_path.t * string) list option;
      (** Replace each input's store path with that input's own hash, and
          RE-SORT by it. The serialized [.drv] sorts inputs by PATH; the form
          that gets hashed sorts them by HASH. One derivation, two orderings. *)
}

let plain = {mask_outputs = false; input_hashes = None}

let unparse_with (d : Derivation.t) opts =
  let join = String.concat "," in
  let outs =
    List.map
      (fun (o : Derivation.output) ->
        let path =
          if opts.mask_outputs then "" else Store_path.to_string o.path
        in
        "("
        ^ join
            [
              quote (Output_name.to_string o.name);
              quote path;
              quote o.hash_algo;
              quote o.hash;
            ]
        ^ ")")
      d.outputs
  in
  let entries =
    List.map
      (fun (i : Derivation.input_drv) ->
        let key =
          match opts.input_hashes with
          | None -> Store_path.to_string i.path
          | Some m -> (
              match
                List.find_opt (fun (p, _) -> Store_path.equal p i.path) m
              with
              | Some (_, h) -> h
              | None -> Store_path.to_string i.path)
        in
        (key, i.outputs))
      d.input_drvs
  in
  let entries =
    match opts.input_hashes with
    | None -> entries
    | Some _ ->
        List.stable_sort (fun (a, _) (b, _) -> String.compare a b) entries
  in
  let ins =
    List.map
      (fun (key, names) ->
        "(" ^ quote key ^ ",["
        ^ join (List.map (fun n -> quote (Output_name.to_string n)) names)
        ^ "])")
      entries
  in
  let srcs = List.map (fun s -> quote (Store_path.to_string s)) d.input_srcs in
  let args = List.map quote d.args in
  let names = Derivation.output_names d in
  let env =
    List.map
      (fun (k, v) ->
        let blank = opts.mask_outputs && List.mem k names in
        "(" ^ quote k ^ "," ^ quote (if blank then "" else v) ^ ")")
      d.env
  in
  "Derive([" ^ join outs ^ "],[" ^ join ins ^ "],[" ^ join srcs ^ "],"
  ^ quote d.system ^ "," ^ quote d.builder ^ ",[" ^ join args ^ "],[" ^ join env
  ^ "])"

(** Serialize a derivation back to ATerm, in the plain canonical form. This is
    the inverse of {!parse} on canonical input. *)
let unparse d = unparse_with d plain
