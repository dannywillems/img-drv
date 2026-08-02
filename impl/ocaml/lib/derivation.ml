(** The derivation types.

    Note what OCaml gives away for free that the other three had to build:
    [env] is a list of PAIRS, because OCaml has tuples, where Go needed a named
    [EnvEntry] struct; [fixed_output] returns an [option], which is a real sum
    rather than Go's [(value, bool)] convention; and structural equality is
    just [=], where Go needed a hand-written [Equal] per type.

    [hash_algo] is a [string] and not the {!Edsl.hash_algo} variant, on purpose:
    parsing has to be TOTAL over whatever real Nix wrote, so the wire type stays
    permissive and strictness lives on the construction side. A type system can
    only make illegal states unrepresentable where you are the one constructing
    them. *)

open Types

type output = {
  name : Output_name.t;
  path : Store_path.t;
  hash_algo : string;
  hash : string;
}

type input_drv = {path : Store_path.t; outputs : Output_name.t list}

type t = {
  outputs : output list;
  input_drvs : input_drv list;
  input_srcs : Store_path.t list;
  system : string;
  builder : string;
  args : string list;
  env : (string * string) list;
}

let empty =
  {
    outputs = [];
    input_drvs = [];
    input_srcs = [];
    system = "";
    builder = "";
    args = [];
    env = [];
  }

(** Whether this output declares its content hash in advance. *)
let is_fixed (o : output) = not (String.equal o.hash_algo "")

(** The names of this derivation's own outputs.

    Used when masking: an env entry is blanked when its KEY is one of these,
    never when an output path merely appears inside some value. *)
let output_names (d : t) =
  List.map (fun (o : output) -> Output_name.to_string o.name) d.outputs

(** The fixed output, if this is a fixed-output derivation. *)
let fixed_output (d : t) = List.find_opt is_fixed d.outputs

(** The derivation name, from the [name] environment variable. *)
let name (d : t) =
  match List.assoc_opt "name" d.env with Some v -> v | None -> ""
