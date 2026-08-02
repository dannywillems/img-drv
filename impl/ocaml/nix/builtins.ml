(** The global scope, and the builtins an expression can reach.

    [derivation] lives in {!Derivation_primop}, which is where the language
    meets the IR. It is the only primop that can PRODUCE a store path, so it is
    the only one whose correctness is checkable byte for byte against real Nix.
    Everything here is ordinary. *)

open Value

let str s = Str (s, Context.empty)

let to_string_primop args =
  let s, ctx = Eval.coerce_to_string (force (List.hd args)) in
  Str (s, ctx)

let type_of_primop args = str (type_of (force (List.hd args)))

let is_null_primop args = Bool (force (List.hd args) = Null)

let length_primop args =
  match force (List.hd args) with
  | Value.List l -> Value.Int (List.length l)
  | v -> error "value is %s while a list was expected" (type_name v)

let attr_names_primop args =
  match force (List.hd args) with
  | Attrs a -> Value.List (List.map (fun (k, _) -> lazy (str k)) a)
  | v -> error "value is %s while a set was expected" (type_name v)

let primop name arity impl = (name, lazy (Primop (name, arity, impl)))

(** The environment an expression is evaluated in.

    [true], [false] and [null] are bindings rather than syntax, which is why
    the parser has no tokens for them and why they can be shadowed. *)
let global_env () : env =
  let entries =
    [
      primop "toString" 1 to_string_primop;
      primop "typeOf" 1 type_of_primop;
      primop "isNull" 1 is_null_primop;
      primop "length" 1 length_primop;
      primop "attrNames" 1 attr_names_primop;
      (* The seam. See derivation_primop.ml. *)
      primop "derivation" 1 Derivation_primop.derivation_primop;
      primop "derivationStrict" 1 Derivation_primop.derivation_primop;
      ("true", lazy (Bool true));
      ("false", lazy (Bool false));
      ("null", lazy Null);
    ]
  in
  {
    bindings =
      attrs_of_list
        (("builtins", lazy (Attrs (attrs_of_list entries))) :: entries);
    withs = [];
  }

(** Evaluate a Nix expression in the global scope.

    [base] is the directory relative paths resolve against, which Nix takes
    from the file the expression was written in. *)
let eval_file ?base ?home (src : string) : (value, string) result =
  match Nix.parse_string ?base ?home src with
  | Error e -> Error e
  | Ok ast -> (
      try Ok (Eval.eval (global_env ()) ast) with Eval_error e -> Error e)

let eval_string (src : string) : (value, string) result =
  match Nix.parse_string src with
  | Error e -> Error e
  | Ok ast -> (
      try Ok (Eval.eval (global_env ()) ast) with Eval_error e -> Error e)
