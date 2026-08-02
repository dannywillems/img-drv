(** The carrier types.

    This module is where the OCaml implementation earns the label "typed
    reference", and it does it in two different ways that are worth telling
    apart.

    {1 Distinctness, by generative functor}

    [Store_path], [Sha256_hex] and [Output_name] are all strings underneath,
    and confusing them is the class of bug this project has already paid for
    once: a derivation's own path and the hash by which it is known as an input
    are both 64-character strings, and swapping them yields a plausible wrong
    answer rather than an error.

    Applying a {e generative} functor three times produces three types that
    share an implementation and are nevertheless incompatible. Rust needs three
    newtype declarations and Go three defined types; here it is one functor and
    three applications, and the compiler treats them as unrelated.

    {1 Validity, by abstraction}

    [Name] is the interesting one, and it is the one thing no other
    implementation in this repository can do. A store path name has to satisfy
    a predicate, and in Python, Rust and Go that predicate is a function called
    at construction time which returns an error. Here the type is ABSTRACT and
    the only way in is {!Name.of_string}, which validates. There is no value of
    type [Name.t] that is not a valid name, so the check does not have to be
    repeated and cannot be forgotten.

    That moves one row of the typing table from "runtime check" to
    "unrepresentable", which is precisely what `docs/spec/signature.md` means
    by an invariant a type system can make unrepresentable. *)

module type ID = sig
  type t

  (** Wrap a string. Deliberately explicit: this is the one place the
      distinction between these types can be lost. *)
  val v : string -> t

  val to_string : t -> string

  val equal : t -> t -> bool

  val compare : t -> t -> int
end

(** A generative functor: every application produces a FRESH type. Applying it
    three times is what makes the three identifiers incompatible. *)
module Make_id () : ID = struct
  type t = string

  let v s = s

  let to_string s = s

  let equal = String.equal

  let compare = String.compare
end

(** An absolute path in the store, e.g. [/nix/store/<32 chars>-hello]. *)
module Store_path =
Make_id ()

(** A sha256 digest as 64 lowercase hex characters. *)
module Sha256_hex =
Make_id ()

(** The name of one output of a derivation: [out], [dev], [lib], ... *)
module Output_name =
Make_id ()

(** A validated store path name.

    Abstract, so an invalid name is unconstructible rather than merely
    rejected. *)
module Name : sig
  type t

  (** Validate and wrap. The only way to build a [t]. *)
  val of_string : string -> (t, string) result

  val to_string : t -> string

  (** Exposed so callers can check before committing to an error path, and so
      the predicate itself can be property-tested. *)
  val is_valid : string -> bool

  val equal : t -> t -> bool

  val compare : t -> t -> int
end = struct
  type t = string

  (** Nix's store-name length cap. *)
  let max_length = 211

  let is_allowed c =
    match c with
    | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' -> true
    | '+' | '-' | '.' | '_' | '?' | '=' -> true
    | _ -> false

  let is_valid s =
    let n = String.length s in
    n > 0 && n <= max_length
    && (not (String.equal s "."))
    && (not (String.equal s ".."))
    && s.[0] <> '.'
    && String.for_all is_allowed s

  let of_string s =
    if is_valid s then Ok s
    else Error (Printf.sprintf "%S is not a valid store path name" s)

  let to_string s = s

  let equal = String.equal

  let compare = String.compare
end
