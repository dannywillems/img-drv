(** The global scope, and the builtins an expression can reach.

    [derivation] lives in {!Derivation_primop}, which is where the language
    meets the IR. It is the only primop that can PRODUCE a store path, so it is
    the only one whose correctness is checkable byte for byte against real Nix.
    Everything here is ordinary, and that is the point: this file is breadth,
    not design.

    {1 Two things that are easy to get wrong and are not obvious}

    CONTEXT PROPAGATION. Every builtin that returns a string built out of other
    strings must carry their contexts along, because the context is what
    becomes a dependency edge ([value.ml]). [substring], [concatStringsSep],
    [replaceStrings] and [toJSON] all do. A builtin that quietly drops it
    produces a derivation of the right shape whose [inputDrvs] is missing an
    entry, which is the exact failure [docs/spec/store-paths.md] warns about,
    and it would be invisible to any test that only inspected the value.

    PARTIAL APPLICATION. Nix applies one argument at a time, so a two-argument
    builtin given one argument is itself a value ({!Primop_apply}). Declaring
    the wrong arity does not fail loudly; it produces a function where a value
    was expected, several frames away from the mistake.

    {1 What is deliberately absent}

    [builtins.split] and [match] need a POSIX regex engine, which OCaml's
    standard library does not have and a dependency would need approval. They
    are absent rather than approximated: a regex engine that is subtly
    different is worse than none, because [lib] uses these for version parsing
    and a wrong answer becomes a wrong store path.

    [currentSystem] and [currentTime] are impure by construction. The first is
    provided because nixpkgs cannot be evaluated without it; the second is not
    provided at all, since a reproducible IR must not be able to observe the
    clock. *)

open Value
open Img_drv

let str s = Str (s, Context.empty)

(** Read a source file. Injected for the same reason as {!Eval.add_to_store}:
    the evaluator library does not open files, so that it stays testable
    without a filesystem and the IR core stays dependency-free. *)
let read_source : (string -> string) ref =
  ref (fun p -> error "cannot read %s: no filesystem is wired up" p)

(** Does this path exist? Injected, as above. *)
let path_exists : (string -> bool) ref = ref (fun _ -> false)

(* Argument accessors. Each one names the type it wanted, because "value is a
   list while a set was expected" is the error Nix gives and the one a user can
   act on. *)

let arg n args = force (List.nth args n)

let want_string n args = fst (Eval.coerce_to_string (arg n args))

let want_string_ctx n args = Eval.coerce_to_string (arg n args)

let want_list n args =
  match arg n args with
  | Value.List l -> l
  | v -> error "value is %s while a list was expected" (type_name v)

let want_attrs n args =
  match arg n args with
  | Attrs a -> a
  | v -> error "value is %s while a set was expected" (type_name v)

let want_int n args =
  match arg n args with
  | Value.Int i -> i
  | v -> error "value is %s while an integer was expected" (type_name v)

let want_bool n args =
  match arg n args with
  | Bool b -> b
  | v -> error "value is %s while a Boolean was expected" (type_name v)

let call f arg_ = Eval.apply f arg_

let call2 f a b = Eval.apply (Eval.apply f a) b

(* Types. The nine names are the whole type universe; see
   docs/nix-internals.md. *)

let type_of_primop args = str (type_of (arg 0 args))

let is_of name args = Bool (String.equal (type_of (arg 0 args)) name)

(* Strings *)

(** [toString]. Does NOT copy a path into the store; interpolation does.

    The distinction is invisible in a value and visible in a store path:
    [toString ./x] is the bare path with no context, so it contributes no
    [inputSrcs] entry, while ["${./x}"] copies the file in and does. Having it
    backwards is how [make eval-check] failed on the builtins probe. *)
let to_string_primop args =
  let s, ctx = Eval.coerce_to_string ~copy_to_store:false (arg 0 args) in
  Str (s, ctx)

let string_length_primop args = Value.Int (String.length (want_string 0 args))

(** [substring start len s]. Nix CLAMPS rather than raising: a start past the
    end gives the empty string and an over-long length is truncated. [lib] leans
    on that, so raising here would break real code. *)
let substring_primop args =
  let start = want_int 0 args and len = want_int 1 args in
  let s, ctx = want_string_ctx 2 args in
  let n = String.length s in
  let start = max 0 start in
  if start >= n || len < 0 then Str ("", ctx)
  else Str (String.sub s start (min len (n - start)), ctx)

let concat_strings_sep_primop args =
  let sep, sctx = want_string_ctx 0 args in
  let parts =
    List.map (fun t -> Eval.coerce_to_string (force t)) (want_list 1 args)
  in
  let ctx = List.fold_left (fun acc (_, c) -> Context.union acc c) sctx parts in
  Str (String.concat sep (List.map fst parts), ctx)

(** [replaceStrings from to s]. Longest-match-at-position is NOT the rule; Nix
    tries the patterns IN ORDER and takes the first that matches, so the order
    of the lists is load-bearing. *)
let replace_strings_primop args =
  let froms =
    List.map (fun t -> fst (Eval.coerce_to_string (force t))) (want_list 0 args)
  in
  let tos =
    List.map (fun t -> Eval.coerce_to_string (force t)) (want_list 1 args)
  in
  let s, ctx = want_string_ctx 2 args in
  let ctx = ref ctx in
  let b = Buffer.create (String.length s) in
  let n = String.length s in
  let starts_at i pat =
    let l = String.length pat in
    l <= n - i && String.equal (String.sub s i l) pat
  in
  let rec go i =
    if i >= n then ()
    else
      let rec try_pats fs ts =
        match (fs, ts) with
        | [], _ | _, [] ->
            Buffer.add_char b s.[i] ;
            go (i + 1)
        | f :: fs', (t, tc) :: ts' ->
            if starts_at i f then begin
              Buffer.add_string b t ;
              ctx := Context.union !ctx tc ;
              (* An empty pattern matches everywhere and must still advance,
                 or this loops forever. *)
              if String.length f = 0 then begin
                if i < n then Buffer.add_char b s.[i] ;
                go (i + 1)
              end
              else go (i + String.length f)
            end
            else try_pats fs' ts'
      in
      try_pats froms tos
  in
  go 0 ;
  Str (Buffer.contents b, !ctx)

let unsafe_discard_context_primop args = str (want_string 0 args)

(* Lists *)

let length_primop args = Value.Int (List.length (want_list 0 args))

let head_primop args =
  match want_list 0 args with
  | [] -> error "list index 0 is out of bounds"
  | t :: _ -> force t

let tail_primop args =
  match want_list 0 args with
  | [] -> error "'tail' called on an empty list"
  | _ :: rest -> Value.List rest

let elem_at_primop args =
  let l = want_list 0 args and i = want_int 1 args in
  match List.nth_opt l i with
  | Some t -> force t
  | None -> error "list index %d is out of bounds" i

let map_primop args =
  let f = arg 0 args in
  Value.List (List.map (fun t -> lazy (call f t)) (want_list 1 args))

let filter_primop args =
  let f = arg 0 args in
  Value.List
    (List.filter
       (fun t ->
         match call f t with
         | Bool b -> b
         | v -> error "value is %s while a Boolean was expected" (type_name v))
       (want_list 1 args))

(** [foldl' op nul list]. STRICT in the accumulator, which is the whole point
    of the prime: the lazy fold builds a thunk chain that overflows on a list
    the size of nixpkgs. *)
let foldl_strict_primop args =
  let f = arg 0 args in
  List.fold_left
    (fun acc t ->
      let v = call2 f (lazy acc) t in
      ignore (Sys.opaque_identity v) ;
      v)
    (arg 1 args)
    (want_list 2 args)

let concat_lists_primop args =
  Value.List
    (List.concat_map
       (fun t ->
         match force t with
         | Value.List l -> l
         | v -> error "value is %s while a list was expected" (type_name v))
       (want_list 0 args))

let gen_list_primop args =
  let f = arg 0 args in
  let n = want_int 1 args in
  Value.List (List.init n (fun i -> lazy (call f (lazy (Value.Int i)))))

let all_primop args =
  let f = arg 0 args in
  Bool (List.for_all (fun t -> Eval.truthy (call f t)) (want_list 1 args))

let any_primop args =
  let f = arg 0 args in
  Bool (List.exists (fun t -> Eval.truthy (call f t)) (want_list 1 args))

(** [sort cmp list]. Nix's sort is STABLE, and [lib] depends on it. *)
let sort_primop args =
  let f = arg 0 args in
  Value.List
    (List.stable_sort
       (fun a b ->
         if Eval.truthy (call2 f a b) then -1
         else if Eval.truthy (call2 f b a) then 1
         else 0)
       (want_list 1 args))

let elem_primop args =
  let x = arg 0 args in
  Bool (List.exists (fun t -> Eval.equal x (force t)) (want_list 1 args))

(* Attribute sets *)

let attr_names_primop args =
  Value.List (List.map (fun (k, _) -> lazy (str k)) (want_attrs 0 args))

let attr_values_primop args = Value.List (List.map snd (want_attrs 0 args))

let get_attr_primop args =
  let k = want_string 0 args in
  match attrs_find (want_attrs 1 args) k with
  | Some t -> force t
  | None -> error "attribute '%s' missing" k

let has_attr_primop args =
  Bool (attrs_find (want_attrs 1 args) (want_string 0 args) <> None)

let remove_attrs_primop args =
  let a = want_attrs 0 args in
  let drop =
    List.map (fun t -> fst (Eval.coerce_to_string (force t))) (want_list 1 args)
  in
  Attrs (List.filter (fun (k, _) -> not (List.mem k drop)) a)

(** [listToAttrs]. A later entry does NOT win: Nix keeps the FIRST occurrence
    of a duplicated name, which is the opposite of what [//] does and the
    opposite of what most people guess. *)
let list_to_attrs_primop args =
  let entries =
    List.filter_map
      (fun t ->
        match force t with
        | Attrs a -> (
            match (attrs_find a "name", attrs_find a "value") with
            | Some n, Some v -> Some (fst (Eval.coerce_to_string (force n)), v)
            | _ -> error "a listToAttrs element needs 'name' and 'value'")
        | v -> error "value is %s while a set was expected" (type_name v))
      (want_list 0 args)
  in
  let seen = Hashtbl.create 16 in
  Attrs
    (attrs_of_list
       (List.filter
          (fun (k, _) ->
            if Hashtbl.mem seen k then false
            else begin
              Hashtbl.add seen k () ;
              true
            end)
          entries))

let map_attrs_primop args =
  let f = arg 0 args in
  Attrs
    (List.map
       (fun (k, v) -> (k, lazy (call2 f (lazy (str k)) v)))
       (want_attrs 1 args))

let intersect_attrs_primop args =
  let a = want_attrs 0 args and b = want_attrs 1 args in
  Attrs (List.filter (fun (k, _) -> attrs_find a k <> None) b)

let cat_attrs_primop args =
  let k = want_string 0 args in
  Value.List
    (List.filter_map
       (fun t ->
         match force t with
         | Attrs a -> attrs_find a k
         | v -> error "value is %s while a set was expected" (type_name v))
       (want_list 1 args))

let function_args_primop args =
  match arg 0 args with
  | Value.Lambda (_, Ast.Pset {formals; _}, _) ->
      Attrs
        (attrs_of_list
           (List.map (fun (n, d) -> (n, lazy (Bool (d <> None)))) formals))
  | Value.Lambda _ | Primop _ -> Attrs []
  | v -> error "value is %s while a function was expected" (type_name v)

(* Arithmetic and comparison *)

let arith int_op float_op args =
  match (arg 0 args, arg 1 args) with
  | Value.Int a, Value.Int b -> Value.Int (int_op a b)
  | a, b ->
      let f = function
        | Value.Int i -> float_of_int i
        | Value.Float x -> x
        | v -> error "value is %s while a number was expected" (type_name v)
      in
      Value.Float (float_op (f a) (f b))

let less_than_primop args =
  Bool (Eval.value_compare (arg 0 args) (arg 1 args) < 0)

(* Control *)

let throw_primop args = error "%s" (want_string 0 args)

(** [tryEval]. Catches an evaluation error and reports it as data.

    Only [Eval_error] is caught, not every exception: a [Stack_overflow] or an
    [Out_of_memory] is a fact about the machine rather than about the
    expression, and swallowing it would turn a crash into a silently wrong
    answer. *)
let try_eval_primop args =
  let ok v =
    Attrs (attrs_of_list [("success", lazy (Bool true)); ("value", lazy v)])
  in
  let no () =
    Attrs
      (attrs_of_list
         [("success", lazy (Bool false)); ("value", lazy (Bool false))])
  in
  try ok (arg 0 args) with Eval_error _ -> no ()

let seq_primop args =
  ignore (arg 0 args) ;
  arg 1 args

(* Paths *)

let no_copy n args =
  fst (Eval.coerce_to_string ~copy_to_store:false (arg n args))

let base_name_of_primop args = str (Filename.basename (no_copy 0 args))

let dir_of_primop args =
  match arg 0 args with
  | Value.Path p -> Value.Path (Filename.dirname p)
  | _ -> str (Filename.dirname (no_copy 0 args))

let path_exists_primop args = Bool (!path_exists (no_copy 0 args))

(* JSON. The encoder itself lives in Eval, because derivation_primop needs it
   too for __structuredAttrs and must not depend on this file. *)

let to_json_primop args =
  let ctx = ref Context.empty in
  let j = Eval.to_json (arg 0 args) ctx in
  Str (Json.to_string j, !ctx)

let primop name arity impl = (name, lazy (Primop (name, arity, impl)))

(** The environment an expression is evaluated in.

    [true], [false] and [null] are bindings rather than syntax, which is why
    the parser has no tokens for them and why they can be shadowed.

    Everything here is ALSO reachable unqualified, because Nix's global scope
    contains the same primops as [builtins] does. That is why [map] and
    [derivation] work without a prefix. *)
let rec global_env () : env =
  let entries =
    [
      (* types *)
      primop "typeOf" 1 type_of_primop;
      primop "isNull" 1 (fun a -> Bool (arg 0 a = Null));
      primop "isList" 1 (is_of "list");
      primop "isAttrs" 1 (is_of "set");
      primop "isString" 1 (is_of "string");
      primop "isInt" 1 (is_of "int");
      primop "isFloat" 1 (is_of "float");
      primop "isBool" 1 (is_of "bool");
      primop "isPath" 1 (is_of "path");
      primop "isFunction" 1 (is_of "lambda");
      (* strings *)
      primop "toString" 1 to_string_primop;
      primop "stringLength" 1 string_length_primop;
      primop "substring" 3 substring_primop;
      primop "concatStringsSep" 2 concat_strings_sep_primop;
      primop "replaceStrings" 3 replace_strings_primop;
      primop "unsafeDiscardStringContext" 1 unsafe_discard_context_primop;
      (* lists *)
      primop "length" 1 length_primop;
      primop "head" 1 head_primop;
      primop "tail" 1 tail_primop;
      primop "elemAt" 2 elem_at_primop;
      primop "map" 2 map_primop;
      primop "filter" 2 filter_primop;
      primop "foldl'" 3 foldl_strict_primop;
      primop "concatLists" 1 concat_lists_primop;
      primop "genList" 2 gen_list_primop;
      primop "all" 2 all_primop;
      primop "any" 2 any_primop;
      primop "sort" 2 sort_primop;
      primop "elem" 2 elem_primop;
      (* sets *)
      primop "attrNames" 1 attr_names_primop;
      primop "attrValues" 1 attr_values_primop;
      primop "getAttr" 2 get_attr_primop;
      primop "hasAttr" 2 has_attr_primop;
      primop "removeAttrs" 2 remove_attrs_primop;
      primop "listToAttrs" 1 list_to_attrs_primop;
      primop "mapAttrs" 2 map_attrs_primop;
      primop "intersectAttrs" 2 intersect_attrs_primop;
      primop "catAttrs" 2 cat_attrs_primop;
      primop "functionArgs" 1 function_args_primop;
      (* arithmetic *)
      primop "add" 2 (arith ( + ) ( +. ));
      primop "sub" 2 (arith ( - ) ( -. ));
      primop "mul" 2 (arith ( * ) ( *. ));
      primop "div" 2 (fun a ->
          match (arg 0 a, arg 1 a) with
          | _, Value.Int 0 -> error "division by zero"
          | x, y -> arith ( / ) ( /. ) [lazy x; lazy y]);
      primop "lessThan" 2 less_than_primop;
      (* control *)
      primop "throw" 1 throw_primop;
      primop "abort" 1 throw_primop;
      primop "tryEval" 1 try_eval_primop;
      primop "seq" 2 seq_primop;
      primop "deepSeq" 2 seq_primop;
      (* paths *)
      primop "baseNameOf" 1 base_name_of_primop;
      primop "dirOf" 1 dir_of_primop;
      primop "pathExists" 1 path_exists_primop;
      primop "import" 1 import_primop;
      (* JSON *)
      primop "toJSON" 1 to_json_primop;
      (* the seam: see derivation_primop.ml *)
      primop "derivation" 1 Derivation_primop.derivation_primop;
      primop "derivationStrict" 1 Derivation_primop.derivation_primop;
      ("true", lazy (Bool true));
      ("false", lazy (Bool false));
      ("null", lazy Null);
      (* nixpkgs cannot be evaluated without this one, and it is impure by
         construction: the same expression means different things on different
         machines. Pinned rather than read from the host. *)
      ("currentSystem", lazy (str "x86_64-linux"));
      ("nixVersion", lazy (str "2.24.9"));
      ("langVersion", lazy (Value.Int 6));
    ]
  in
  {
    bindings =
      attrs_of_list
        (("builtins", lazy (Attrs (attrs_of_list entries))) :: entries);
    withs = [];
  }

(** [import]. Reads, parses and evaluates another file.

    Mutually recursive with {!global_env} because an imported file is evaluated
    in the SAME global scope, not in the importing file's scope: Nix's import
    is not textual inclusion, and a file that relies on its importer's [let]
    bindings is an error rather than a convenience. *)
and import_primop args =
  let path =
    match arg 0 args with
    | Value.Path p -> p
    | v -> fst (Eval.coerce_to_string v)
  in
  (* A directory imports its default.nix, which is what makes `import ./.`
     and `import <nixpkgs>` work. *)
  let path =
    if !path_exists (Filename.concat path "default.nix") then
      Filename.concat path "default.nix"
    else path
  in
  match Nix.parse_string ~base:(Filename.dirname path) (!read_source path) with
  | Error e -> error "while importing %s: %s" path e
  | Ok ast -> Eval.eval (global_env ()) ast

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
