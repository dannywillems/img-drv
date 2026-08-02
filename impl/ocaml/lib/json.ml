(** A JSON value, and the canonical serialization [__structuredAttrs] uses.

    This is the first RECURSIVE type in the signature. Everything else is a
    product of primitives and lists of them, which is what [docs/theory.md]
    section 1 restricts the signature to; a JSON value is an inductive
    datatype, a fixed point of a polynomial functor. Still first-order and
    still algebraic, so the Lawvere argument survives, but it is a genuine
    extension.

    It is also the cheapest thing in this file to write in OCaml and the most
    expensive in Go. A seven-case recursive sum is what variants are FOR: the
    definition below is seven lines and the compiler checks that every match
    over it is exhaustive. Go needs a struct with a discriminant and one field
    per case, where a value of an invalid shape is representable. That contrast
    is the clearest single measurement the four implementations have produced.

    Written out rather than taking a JSON dependency, for the same reason
    sha256 is: the output is hashed into store paths, so its exact byte form is
    part of this library's contract and is better owned here than inherited. *)

type t =
  | Null
  | Bool of bool
  | Int of int
  | Float of float
  | String of string
  | Array of t list
  | Object of (string * t) list

(** The common case: an array of strings. *)
let strings items = Array (List.map (fun s -> String s) items)

(** JSON string escaping.

    The five shorthand escapes plus [\b] and [\f], [\u00XX] for the remaining
    control characters, and every other byte RAW including non-ASCII. Escaping
    non-ASCII would produce different bytes and therefore a different store
    path. *)
let escape s =
  let b = Buffer.create (String.length s + 2) in
  Buffer.add_char b '"' ;
  String.iter
    (fun c ->
      match c with
      | '"' -> Buffer.add_string b "\\\""
      | '\\' -> Buffer.add_string b "\\\\"
      | '\n' -> Buffer.add_string b "\\n"
      | '\r' -> Buffer.add_string b "\\r"
      | '\t' -> Buffer.add_string b "\\t"
      | '\b' -> Buffer.add_string b "\\b"
      | '\012' -> Buffer.add_string b "\\f"
      | c when Char.code c < 0x20 ->
          Buffer.add_string b (Printf.sprintf "\\u%04x" (Char.code c))
      | c -> Buffer.add_char b c)
    s ;
  Buffer.add_char b '"' ;
  Buffer.contents b

(** The canonical serialization: sorted keys, compact separators, and non-ASCII
    emitted raw. All three hold on 456 of 456 structured derivations in a real
    closure. *)
let rec to_string (v : t) : string =
  match v with
  | Null -> "null"
  | Bool true -> "true"
  | Bool false -> "false"
  | Int i -> string_of_int i
  | Float f ->
      if Float.is_integer f then Printf.sprintf "%.1f" f
      else Printf.sprintf "%.17g" f
  | String s -> escape s
  | Array items -> "[" ^ String.concat "," (List.map to_string items) ^ "]"
  | Object fields ->
      let sorted =
        List.stable_sort (fun (a, _) (b, _) -> String.compare a b) fields
      in
      "{"
      ^ String.concat
          ","
          (List.map (fun (k, v) -> escape k ^ ":" ^ to_string v) sorted)
      ^ "}"

(** Whether this value is a JSON string.

    The flat env encoding can only carry strings, so a build without
    [structured_attrs] has to refuse anything else. *)
let is_string = function String _ -> true | _ -> false
