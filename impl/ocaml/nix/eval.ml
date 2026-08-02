(** The evaluator.

    Call-by-need over {!Value.thunk}, which is [Lazy.t]; see the header of
    [value.ml] for why that is the right primitive rather than a hand-rolled
    one. *)

open Ast
open Value
open Img_drv

let rec lookup (env : env) (x : string) : thunk =
  match attrs_find env.bindings x with
  | Some t -> t
  | None -> lookup_with env.withs x

(* A `with` scope is consulted ONLY when a name is not statically bound, and
   inner scopes beat outer ones. Keeping them in a separate list is what makes
   `let x = 1; in with { x = 2; }; x` evaluate to 1, as Nix does: a static
   binding always wins. *)
and lookup_with withs x =
  match withs with
  | [] -> error "undefined variable '%s'" x
  | scope :: rest -> (
      match force scope with
      | Attrs a -> (
          match attrs_find a x with Some t -> t | None -> lookup_with rest x)
      | v -> error "value is %s while a set was expected" (type_name v))

(** How a path literal becomes a store path.

    Injected rather than called directly: the copy needs a filesystem walk, and
    keeping it behind a reference is what lets the evaluator stay testable
    without one and the library stay dependency-free. The default is an error
    rather than a silent identity, because silently treating [./x] as the
    string [./x] would produce a derivation of the right shape with the wrong
    inputSrcs, which is the failure mode docs/spec/store-paths.md warns about.

    The CLI sets it to the real thing, using {!Img_drv.Nar}. *)
let add_to_store : (string -> string * Context.t) ref =
  ref (fun p -> error "cannot add %s to the store: no store is wired up" p)

(** Coerce to a string the way an attribute of a derivation is coerced.

    Nix's rules, and they are not obvious: a Boolean becomes ["1"] or the empty
    string rather than ["true"]/["false"], null becomes empty, and a list is
    coerced elementwise and joined with spaces. Getting any of these wrong
    changes the env and therefore the store path. *)
let rec coerce_to_string ?(list_ok = true) ?(copy_to_store = true) (v : value) :
    string * Context.t =
  let coerce = coerce_to_string ~copy_to_store in
  match v with
  | Str (s, ctx) -> (s, ctx)
  | Int n -> (string_of_int n, Context.empty)
  | Float f -> (Printf.sprintf "%g" f, Context.empty)
  | Bool true -> ("1", Context.empty)
  | Bool false -> ("", Context.empty)
  | Null -> ("", Context.empty)
  | Path p ->
      (* A path literal coerced to a string is COPIED INTO THE STORE, and the
         resulting string carries that store path in its context, which is what
         puts it in inputSrcs. The copy needs NAR and a filesystem, and this
         library has neither on purpose (the OCaml IR core has zero
         dependencies and the walk lives in the CLI), so it is injected.

         [copy_to_store] is FALSE for `builtins.toString`, and that is a real
         semantic distinction rather than an optimisation: `"${./x}"` copies
         and yields a context, `toString ./x` yields the bare path with none.
         Getting it backwards puts a phantom entry in inputSrcs and moves the
         store path, which is how this was found. *)
      if copy_to_store then !add_to_store p else (p, Context.empty)
  | List items when list_ok ->
      let parts = List.map (fun t -> coerce ~list_ok:false (force t)) items in
      ( String.concat " " (List.map fst parts),
        List.fold_left
          (fun acc (_, c) -> Context.union acc c)
          Context.empty
          parts )
  | Attrs a -> (
      (* A derivation coerces to its outPath, and that is where the dependency
         edge comes from: the resulting string carries the drv path in its
         context. *)
      match attrs_find a "outPath" with
      | Some t -> coerce ~list_ok (force t)
      | None -> error "cannot coerce a set to a string")
  | v -> error "cannot coerce %s to a string" (type_name v)

let rec eval (env : env) (e : t) : value =
  match e with
  | Int n -> Value.Int n
  | Float f -> Value.Float f
  | Var "true" when attrs_find env.bindings "true" = None -> Bool true
  | Var "false" when attrs_find env.bindings "false" = None -> Bool false
  | Var "null" when attrs_find env.bindings "null" = None -> Null
  | Var x -> force (lookup env x)
  | Path p -> Value.Path p
  | Search_path p -> error "<%s> needs a search path, which is not wired up" p
  | Uri u -> Str (u, Context.empty)
  | Str parts | Ind_str parts ->
      let s, ctx = eval_parts env parts in
      Str (s, ctx)
  (* An interpolated path concatenates to a PATH, not a string: its first part
     is the already-resolved prefix, so the result is still a location. *)
  | Path_interp parts -> Value.Path (fst (eval_parts env parts))
  | Not e -> (
      match eval env e with
      | Bool b -> Bool (not b)
      | v -> error "value is %s while a Boolean was expected" (type_name v))
  | Neg e -> (
      match eval env e with
      | Value.Int n -> Value.Int (-n)
      | Value.Float f -> Value.Float (-.f)
      | v -> error "value is %s while a number was expected" (type_name v))
  | Op (o, a, b) -> eval_op env o a b
  | If (c, t, f) -> if truthy (eval env c) then eval env t else eval env f
  | Assert (c, body) ->
      if truthy (eval env c) then eval env body else error "assertion failed"
  | Lambda (p, body) -> Value.Lambda (env, p, body)
  | Apply (f, a) -> apply (eval env f) (lazy (eval env a))
  | List items -> Value.List (List.map (fun i -> lazy (eval env i)) items)
  | With (scope, body) ->
      let t = lazy (eval env scope) in
      eval {env with withs = t :: env.withs} body
  | Attr_set {recursive; binds} -> Attrs (eval_binds env recursive binds)
  | Let (binds, body) ->
      let a = eval_binds env true binds in
      eval {env with bindings = merge_bindings env.bindings a} body
  | Has_attr (e, path) ->
      Bool (Option.is_some (select_opt env (eval env e) path))
  | Select (e, path, dflt) -> (
      match (select_opt env (eval env e) path, dflt) with
      | Some t, _ -> force t
      | None, Some d -> eval env d
      | None, None -> error "attribute missing")

and truthy = function
  | Bool b -> b
  | v -> error "value is %s while a Boolean was expected" (type_name v)

and merge_bindings outer inner =
  attrs_of_list
    (inner @ List.filter (fun (k, _) -> not (List.mem_assoc k inner)) outer)

and eval_parts env parts =
  List.fold_left
    (fun (acc, ctx) p ->
      match p with
      | Lit s -> (acc ^ s, ctx)
      | Anti e ->
          let s, c = coerce_to_string (eval env e) in
          (acc ^ s, Context.union ctx c))
    ("", Context.empty)
    parts

(* `rec { ... }` and `let` bind their own names, so a binding is evaluated in
   an environment that refers to the very set being built.

   The knot is tied on the NAMES, which are statically known, rather than on
   the values. Forcing [attrs] builds only the list of (name, thunk) pairs and
   evaluates nothing, so it completes before any value thunk is forced; by the
   time a binding actually looks a sibling up, the list exists. Tying it on the
   values instead would force [attrs] while [attrs] was being forced, which is
   the cycle [Lazy] reports as "infinite recursion encountered". *)
and static_names binds =
  let of_attr = function
    | Aid n -> Some n
    | Astr [Lit n] -> Some n
    | Adyn (Str [Lit n]) -> Some n
    | _ -> None
  in
  List.concat_map
    (fun bind ->
      match bind with
      | Bind (a :: _, _) -> Option.to_list (of_attr a)
      | Bind ([], _) -> []
      | Inherit (_, names) -> List.filter_map of_attr names)
    binds

and eval_binds env recursive binds =
  let names = static_names binds in
  let rec attrs =
    lazy
      (let env' =
         if not recursive then env
         else
           let self =
             List.map
               (fun n ->
                 ( n,
                   lazy
                     (match attrs_find (Lazy.force attrs) n with
                     | Some t -> force t
                     | None -> error "undefined variable '%s'" n) ))
               names
           in
           {env with bindings = merge_bindings env.bindings self}
       in
       attrs_of_list
         (List.concat_map
            (fun bind ->
              match bind with
              | Bind (path, e) -> [bind_path env' path e]
              | Inherit (from, ns) -> inherit_names env' from ns)
            binds))
  in
  Lazy.force attrs

and bind_path env path e =
  match path with
  | [] -> error "empty attribute path"
  | [a] -> (attr_name env a, lazy (eval env e))
  | a :: rest ->
      (* `a.b = e` is `a = { b = e; }`; the printer does the same expansion. *)
      (attr_name env a, lazy (Attrs (attrs_of_list [bind_path env rest e])))

and inherit_names env from names =
  match from with
  | None ->
      List.map
        (fun a ->
          let n = attr_name env a in
          (n, lookup env n))
        names
  | Some src ->
      let s = lazy (eval env src) in
      List.map
        (fun a ->
          let n = attr_name env a in
          ( n,
            lazy
              (match force s with
              | Attrs at -> (
                  match attrs_find at n with
                  | Some t -> force t
                  | None -> error "attribute '%s' missing" n)
              | v -> error "value is %s while a set was expected" (type_name v))
          ))
        names

and attr_name env = function
  | Aid x -> x
  | Astr parts -> fst (eval_parts env parts)
  | Adyn e -> fst (eval_parts env [Anti e])

and select_opt env (v : value) (path : attrpath) : thunk option =
  match path with
  | [] -> Some (lazy v)
  | a :: rest -> (
      match v with
      | Attrs at -> (
          match attrs_find at (attr_name env a) with
          | Some t -> select_opt env (force t) rest
          | None -> None)
      | _ -> None)

and apply (f : value) (arg : thunk) : value =
  match f with
  | Value.Lambda (env, Pvar x, body) ->
      eval {env with bindings = merge_bindings env.bindings [(x, arg)]} body
  | Value.Lambda (env, Pset {formals; ellipsis; alias}, body) ->
      let actual =
        match force arg with
        | Attrs a -> a
        | v -> error "value is %s while a set was expected" (type_name v)
      in
      if not ellipsis then
        List.iter
          (fun (k, _) ->
            if not (List.exists (fun (n, _) -> String.equal n k) formals) then
              error "called with unexpected argument '%s'" k)
          actual ;
      let rec bound =
        lazy
          (List.map
             (fun (name, dflt) ->
               match (attrs_find actual name, dflt) with
               | Some t, _ -> (name, t)
               | None, Some d ->
                   (name, lazy (eval {env with bindings = Lazy.force bound} d))
               | None, None ->
                   error "called without required argument '%s'" name)
             formals
          @ (match alias with Some a -> [(a, arg)] | None -> [])
          @ env.bindings)
      in
      eval {env with bindings = Lazy.force bound} body
  | Primop (name, arity, impl) -> Primop_apply.partial name arity impl [arg]
  | v ->
      error
        "attempt to call something which is not a function but %s"
        (type_name v)

and eval_op env o a b =
  let num_op fi ff =
    match (eval env a, eval env b) with
    | Value.Int x, Value.Int y -> Value.Int (fi x y)
    | Value.Float x, Value.Float y -> Value.Float (ff x y)
    | Value.Int x, Value.Float y -> Value.Float (ff (float_of_int x) y)
    | Value.Float x, Value.Int y -> Value.Float (ff x (float_of_int y))
    | x, _ -> error "value is %s while a number was expected" (type_name x)
  in
  let cmp () = value_compare (eval env a) (eval env b) in
  match o with
  | And -> if truthy (eval env a) then eval env b else Bool false
  | Or -> if truthy (eval env a) then Bool true else eval env b
  | Impl -> if truthy (eval env a) then eval env b else Bool true
  | Add -> (
      match (eval env a, eval env b) with
      | Str (x, cx), Str (y, cy) -> Str (x ^ y, Context.union cx cy)
      | Value.Path p, Str (y, _) -> Value.Path (p ^ y)
      | _ -> num_op ( + ) ( +. ))
  | Sub -> num_op ( - ) ( -. )
  | Mul -> num_op ( * ) ( *. )
  | Div ->
      num_op
        (fun x y -> if y = 0 then error "division by zero" else x / y)
        ( /. )
  | Eq -> Bool (equal (eval env a) (eval env b))
  | Neq -> Bool (not (equal (eval env a) (eval env b)))
  | Lt -> Bool (cmp () < 0)
  | Gt -> Bool (cmp () > 0)
  | Le -> Bool (cmp () <= 0)
  | Ge -> Bool (cmp () >= 0)
  | Concat -> (
      match (eval env a, eval env b) with
      | Value.List x, Value.List y -> Value.List (x @ y)
      | x, _ -> error "value is %s while a list was expected" (type_name x))
  | Update -> (
      match (eval env a, eval env b) with
      | Attrs x, Attrs y ->
          Attrs
            (attrs_of_list
               (y @ List.filter (fun (k, _) -> not (List.mem_assoc k y)) x))
      | x, _ -> error "value is %s while a set was expected" (type_name x))

(** A value as JSON, accumulating the string contexts it passes.

    Needed twice: for [builtins.toJSON], and for [__structuredAttrs], the
    SECOND env encoding ([docs/spec/canonical.md] section 1.8) that 1223 of the
    2516 real derivations use. With it on, an attribute keeps its TYPE instead
    of becoming a string variable, so an implementation that coerces everything
    passes the ordinary probe and fails this one.

    The context accumulator is the part that is easy to omit. A derivation
    interpolated inside a structured attribute is still a dependency, and the
    edge has to survive the encoding: without the [ctx] argument the JSON would
    be right and the [inputDrvs] would be short an entry. *)
and to_json (v : value) (ctx : Context.t ref) : Json.t =
  match v with
  | Value.Int i -> Json.Int i
  | Value.Float f -> Json.Float f
  | Bool b -> Json.Bool b
  | Null -> Json.Null
  | Str (s, c) ->
      ctx := Context.union !ctx c ;
      Json.String s
  | Value.Path p -> Json.String p
  | Value.List l -> Json.Array (List.map (fun t -> to_json (force t) ctx) l)
  | Attrs a -> (
      (* A derivation serializes as its outPath, exactly as it coerces. *)
      match attrs_find a "outPath" with
      | Some t when attrs_find a "type" <> None -> to_json (force t) ctx
      | _ -> Json.Object (List.map (fun (k, t) -> (k, to_json (force t) ctx)) a)
      )
  | Lambda _ | Primop _ -> error "cannot convert a function to JSON"

(** The order [<] uses, and the one [builtins.lessThan] and [sort] expose.

    Mixed int/float comparison is by VALUE, not by widening one side and
    hoping: [1 < 1.5] is true and [1 < 1.0] is false. Strings compare by bytes
    and IGNORE context, which is right, because two strings that differ only in
    what they depend on are the same string. *)
and value_compare x y =
  match (x, y) with
  | Value.Int a, Value.Int b -> compare a b
  | Value.Float a, Value.Float b -> compare a b
  | Value.Int a, Value.Float b -> compare (float_of_int a) b
  | Value.Float a, Value.Int b -> compare a (float_of_int b)
  | Str (a, _), Str (b, _) -> compare a b
  | Value.Path a, Value.Path b -> compare a b
  | a, _ -> error "cannot compare %s" (type_name a)

and equal x y =
  match (x, y) with
  | Value.Int a, Value.Int b -> a = b
  | Value.Float a, Value.Float b -> a = b
  | Value.Int a, Value.Float b | Value.Float b, Value.Int a ->
      float_of_int a = b
  | Bool a, Bool b -> a = b
  | Str (a, _), Str (b, _) -> String.equal a b
  | Value.Path a, Value.Path b -> String.equal a b
  | Null, Null -> true
  | Value.List a, Value.List b ->
      List.length a = List.length b
      && List.for_all2 (fun p q -> equal (force p) (force q)) a b
  | Attrs a, Attrs b ->
      List.length a = List.length b
      && List.for_all2
           (fun (k, p) (l, q) -> String.equal k l && equal (force p) (force q))
           a
           b
  | _ -> false
