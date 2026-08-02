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

(** List a directory. Injected, as above. *)
let read_dir : (string -> string list) ref = ref (fun _ -> [])

(** ["regular"] | ["directory"] | ["symlink"], as [builtins.readFileType]
    reports it. Injected, as above. *)
let file_type : (string -> string) ref = ref (fun _ -> "regular")

(** Materialise a [builtins.toFile] result on disk.

    The evaluator computes the store PATH itself, which is the part that
    affects a derivation's identity; writing the bytes is a side effect the CLI
    performs, and a caller that only wants the IR can leave it a no-op. *)
let write_to_store : (string -> string -> unit) ref = ref (fun _ _ -> ())

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

(** [substring start len s]. Three behaviours, none of which is an error.

    Nix CLAMPS rather than raising: a start past the end gives the empty string
    and an over-long length is truncated. And a NEGATIVE length means "to the
    end of the string", not "empty": [lib.removePrefix] is written as
    [substring (stringLength prefix) (-1) str], so an implementation that
    treats a negative length as empty silently turns every [removePrefix] into
    the empty string. That is how this was found, against real nixpkgs lib, and
    it is the second clamping detail in one function to matter. *)
let substring_primop args =
  let start = want_int 0 args and len = want_int 1 args in
  let s, ctx = want_string_ctx 2 args in
  let n = String.length s in
  let start = max 0 start in
  if start >= n then Str ("", ctx)
  else
    let avail = n - start in
    Str (String.sub s start (if len < 0 then avail else min len avail), ctx)

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

(* Diagnostics. Nix writes these to stderr and returns the second argument, so
   they are transparent to the value and to the store path. *)

let trace_primop args =
  prerr_endline
    ("trace: " ^ fst (Eval.coerce_to_string ~copy_to_store:false (arg 0 args))) ;
  arg 1 args

let warn_primop args =
  prerr_endline ("warning: " ^ want_string 0 args) ;
  arg 1 args

(** [addErrorContext msg e]. We do not carry an error-context stack, so this is
    the identity on the value. Recorded as a deviation rather than hidden: the
    VALUE is right and only a failure MESSAGE would be less informative, so it
    cannot move a store path. *)
let add_error_context_primop args = arg 1 args

(** [unsafeGetAttrPos]. Returns null: we do not track source positions.

    [lib] uses it only to improve error messages, and [null] is what Nix itself
    returns when the position is unknown, so this is a supported answer rather
    than a lie. *)
let unsafe_get_attr_pos_primop args =
  ignore (arg 0 args) ;
  Null

(* More lists *)

let concat_map_primop args =
  let f = arg 0 args in
  Value.List
    (List.concat_map
       (fun t ->
         match call f t with
         | Value.List l -> l
         | v -> error "value is %s while a list was expected" (type_name v))
       (want_list 1 args))

let partition_primop args =
  let f = arg 0 args in
  let yes, no =
    List.partition (fun t -> Eval.truthy (call f t)) (want_list 1 args)
  in
  Attrs
    (attrs_of_list
       [("right", lazy (Value.List yes)); ("wrong", lazy (Value.List no))])

let group_by_primop args =
  let f = arg 0 args in
  let table = Hashtbl.create 16 in
  let order = ref [] in
  List.iter
    (fun t ->
      let k = fst (Eval.coerce_to_string (call f t)) in
      if not (Hashtbl.mem table k) then order := k :: !order ;
      Hashtbl.replace
        table
        k
        (t :: Option.value (Hashtbl.find_opt table k) ~default:[]))
    (want_list 1 args) ;
  Attrs
    (attrs_of_list
       (List.map
          (fun k -> (k, lazy (Value.List (List.rev (Hashtbl.find table k)))))
          (List.rev !order)))

let zip_attrs_with_primop args =
  let f = arg 0 args in
  let sets =
    List.map
      (fun t ->
        match force t with
        | Attrs a -> a
        | v -> error "value is %s while a set was expected" (type_name v))
      (want_list 1 args)
  in
  let keys =
    List.sort_uniq String.compare (List.concat_map (List.map fst) sets)
  in
  Attrs
    (attrs_of_list
       (List.map
          (fun k ->
            let vals = List.filter_map (fun a -> attrs_find a k) sets in
            (k, lazy (call2 f (lazy (str k)) (lazy (Value.List vals)))))
          keys))

(** [genericClosure]. Breadth-first reachability from a start set, deduplicated
    by a [key] attribute.

    This is the one builtin that is a genuine ALGORITHM rather than a wrapper:
    it computes the least fixed point of the operator "add everything the
    current set reaches", which is exactly Kleene iteration on the powerset
    lattice, and it terminates because that lattice has finite height once the
    key set is finite. nixpkgs uses it for dependency closures. *)
let generic_closure_primop args =
  let a = want_attrs 0 args in
  let start =
    match attrs_find a "startSet" with
    | Some t -> (
        match force t with
        | Value.List l -> l
        | v -> error "value is %s while a list was expected" (type_name v))
    | None -> error "genericClosure needs 'startSet'"
  in
  let op =
    match attrs_find a "operator" with
    | Some t -> force t
    | None -> error "genericClosure needs 'operator'"
  in
  let seen = Hashtbl.create 64 in
  let out = ref [] in
  let key t =
    match force t with
    | Attrs e -> (
        match attrs_find e "key" with
        | Some k -> Eval.to_json (force k) (ref Context.empty) |> Json.to_string
        | None -> error "a genericClosure element needs 'key'")
    | v -> error "value is %s while a set was expected" (type_name v)
  in
  let rec go queue =
    match queue with
    | [] -> ()
    | t :: rest ->
        let k = key t in
        if Hashtbl.mem seen k then go rest
        else begin
          Hashtbl.add seen k () ;
          out := t :: !out ;
          match call op t with
          | Value.List l -> go (rest @ l)
          | v -> error "value is %s while a list was expected" (type_name v)
        end
  in
  go start ;
  Value.List (List.rev !out)

(* Versions. Nix's own comparison, which is NOT lexicographic and not semver. *)

(** Split a version into its components, the way Nix does: maximal runs of
    digits and maximal runs of letters, with everything else a separator. *)
let split_version v =
  let out = ref [] and b = Buffer.create 8 in
  let kind = ref `None in
  let flush () =
    if Buffer.length b > 0 then begin
      out := Buffer.contents b :: !out ;
      Buffer.clear b
    end
  in
  String.iter
    (fun c ->
      let k =
        if c >= '0' && c <= '9' then `Digit
        else if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') then `Alpha
        else `Sep
      in
      if k <> !kind then flush () ;
      kind := k ;
      if k <> `Sep then Buffer.add_char b c)
    v ;
  flush () ;
  List.rev !out

let split_version_primop args =
  Value.List
    (List.map (fun p -> lazy (str p)) (split_version (want_string 0 args)))

(** Compare two version components. The rule that surprises people: a component
    that is PRE, RC, ALPHA, BETA or PRE sorts BELOW the empty component, so
    "1.0pre1" is older than "1.0". *)
let compare_component a b =
  let rank s =
    match String.lowercase_ascii s with
    | "pre" | "rc" | "alpha" | "beta" -> -1
    | "" -> 0
    | _ -> 1
  in
  let numeric s = s <> "" && String.for_all (fun c -> c >= '0' && c <= '9') s in
  if numeric a && numeric b then compare (int_of_string a) (int_of_string b)
  else
    let ra = if numeric a then 1 else rank a
    and rb = if numeric b then 1 else rank b in
    if ra <> rb then compare ra rb else compare a b

let compare_versions_primop args =
  let rec go a b =
    match (a, b) with
    | [], [] -> 0
    | [], y :: ys ->
        if compare_component "" y = 0 then go [] ys else compare_component "" y
    | x :: xs, [] ->
        if compare_component x "" = 0 then go xs [] else compare_component x ""
    | x :: xs, y :: ys ->
        let c = compare_component x y in
        if c <> 0 then c else go xs ys
  in
  Value.Int
    (go
       (split_version (want_string 0 args))
       (split_version (want_string 1 args)))

(** [parseDrvName]. Splits at the first dash NOT followed by a letter, which is
    how "gtk+-2.0" keeps its plus and "libfoo-1.2" does not keep its version. *)
let parse_drv_name_primop args =
  let s = want_string 0 args in
  let n = String.length s in
  let rec find i =
    if i >= n - 1 then n
    else if
      s.[i] = '-'
      && not
           ((s.[i + 1] >= 'a' && s.[i + 1] <= 'z')
           || (s.[i + 1] >= 'A' && s.[i + 1] <= 'Z'))
    then i
    else find (i + 1)
  in
  let i = find 0 in
  Attrs
    (attrs_of_list
       [
         ("name", lazy (str (String.sub s 0 i)));
         ( "version",
           lazy (str (if i >= n then "" else String.sub s (i + 1) (n - i - 1)))
         );
       ])

(* String context, as data *)

let has_context_primop args =
  Bool (not (Context.is_empty (snd (want_string_ctx 0 args))))

(** [getContext]. Exposes the context as an attribute set, which is the one
    place the three-case variant of [value.ml] becomes visible to a Nix
    expression. Nix keys it by store path with [path]/[allOutputs]/[outputs]
    flags; we report the same shape. *)
let get_context_primop args =
  let ctx = snd (want_string_ctx 0 args) in
  let table = Hashtbl.create 8 in
  Context.iter
    (fun e ->
      let path, entry =
        match e with
        | Opaque p -> (p, ("path", lazy (Bool true)))
        | Drv_deep d -> (d, ("allOutputs", lazy (Bool true)))
        | Built (o, d) -> (d, ("outputs", lazy (Value.List [lazy (str o)])))
      in
      Hashtbl.replace
        table
        path
        (entry :: Option.value (Hashtbl.find_opt table path) ~default:[]))
    ctx ;
  Attrs
    (attrs_of_list
       (Hashtbl.fold
          (fun k v acc -> (k, lazy (Attrs (attrs_of_list v))) :: acc)
          table
          []))

(* The store, and the filesystem *)

(** [toFile name text]. Writes a file into the store and returns its path.

    The SECOND thing in the language that can produce a store path, after
    [derivation], and it uses the [text] kind rather than [source]: the content
    is hashed directly, with no NAR, and the references come from the string's
    own context. Sharing that references rule with a `.drv` path is why one bug
    in [makeType] was two bugs (docs/spec/store-paths.md). *)
let to_file_primop args =
  let name = want_string 0 args in
  let text, ctx = want_string_ctx 1 args in
  let refs =
    Context.fold
      (fun e acc ->
        match e with
        | Opaque p -> p :: acc
        | Built (_, d) | Drv_deep d -> d :: acc)
      ctx
      []
    |> List.sort_uniq String.compare
  in
  let kind = if refs = [] then "text" else "text:" ^ String.concat ":" refs in
  let path =
    Store.store_path ~kind ~inner:(Types.Sha256_hex.v (Sha256.hex text)) ~name
    |> Types.Store_path.to_string
  in
  !write_to_store path text ;
  Str (path, Context.singleton (Opaque path))

let read_file_primop args =
  let s = !read_source (no_copy 0 args) in
  Str (s, Context.empty)

let read_dir_primop args =
  let d = no_copy 0 args in
  Attrs
    (attrs_of_list
       (List.map
          (fun name -> (name, lazy (str (!file_type (Filename.concat d name)))))
          (!read_dir d)))

let read_file_type_primop args = str (!file_type (no_copy 0 args))

(** [getEnv]. Impure by construction, and it returns the empty string for an
    unset variable rather than failing, which is what lets [lib] use it for
    optional configuration. We report everything as unset: a reproducible IR
    must not depend on the caller's environment. *)
let get_env_primop args =
  ignore (want_string 0 args) ;
  str ""

(* Regular expressions.

   Nix specifies POSIX ERE: `builtins.match` and `split` are implemented with
   std::regex under `std::regex::extended`, and the manual links the POSIX.1
   ERE chapter. So the engine has to agree on SYNTAX and on leftmost-longest
   SUBMATCH selection, and the second is the part that is easy to get wrong.

   Re.Posix.compile is the only correct entry point, and this is a real
   footgun rather than a style note: `Re.compile (Re.Posix.re s)` parses ERE
   syntax while keeping Re's own non-POSIX match semantics. Only
   `Re.Posix.compile` applies `Re.longest`. See
   docs/decisions/2026-08-02-ocaml-re-posix-regex.md.

   Compiled patterns are CACHED. Nix caches too, and it matters here for a
   second reason: re builds its DFA lazily, so a pattern reused across a
   thousand list elements amortises the automaton instead of rebuilding it. *)

let regex_cache : (bool * string, Re.re) Hashtbl.t = Hashtbl.create 64

(** [whole] anchors the pattern to the entire string.

    Note what it is NOT: wrapping the source in [^(?:...)$]. POSIX ERE has no
    non-capturing group, so that string does not even parse as ERE, and a
    plain [^(...)$] would shift every capture index by one. [Re.whole_string]
    is the combinator that anchors without touching the group numbering. *)
let compiled ~whole pattern =
  match Hashtbl.find_opt regex_cache (whole, pattern) with
  | Some r -> r
  | None ->
      let r =
        try
          let parsed = Re.Posix.re pattern in
          Re.Posix.compile (if whole then Re.whole_string parsed else parsed)
        with _ -> error "invalid regular expression %S" pattern
      in
      Hashtbl.add regex_cache (whole, pattern) r ;
      r

(** A group that did not participate becomes [null], not the empty string.

    [lib] branches on that distinction, so collapsing the two would give
    plausible strings and wrong answers. *)
let group_value g i =
  match Re.Group.get_opt g i with Some s -> str s | None -> Null

(** [match regex str]. Returns the capture groups, or null.

    Matches the WHOLE string, not a substring: Nix uses [std::regex_match]
    rather than [regex_search], so ["b"] does not match ["abc"]. An
    implementation that searches instead passes every positive test and fails
    every negative one. *)
let match_primop args =
  let pattern = want_string 0 args in
  let s, ctx = want_string_ctx 1 args in
  ignore ctx ;
  match Re.exec_opt (compiled ~whole:true pattern) s with
  | None -> Null
  | Some g ->
      Value.List
        (List.init
           (Re.Group.nb_groups g - 1)
           (fun i -> lazy (group_value g (i + 1))))

(** [split regex str]. Non-matching pieces interleaved with the group lists.

    The shape is the surprise: the result ALTERNATES strings and lists, always
    starts and ends with a string, and therefore always has an odd length. A
    zero-width match still produces its pair, which is why the position must
    advance past an empty match or this does not terminate. *)
let split_primop args =
  let pattern = want_string 0 args in
  let s, _ = want_string_ctx 1 args in
  let re = compiled ~whole:false pattern in
  let n = String.length s in
  let out = ref [] in
  let emit v = out := v :: !out in
  let last = ref 0 in
  let rec collect pos =
    if pos > n then ()
    else
      match Re.exec_opt ~pos re s with
      | None -> ()
      | Some g ->
          let a, b = Re.Group.offset g 0 in
          (* Cut the piece EAGERLY. The obvious [lazy (String.sub s !last ...)]
             reads the mutable cursor when the thunk is FORCED, by which time it
             has advanced past [a] and the length is negative. Laziness over
             mutable state captures the REFERENCE, not the value, and this is
             the one place in the evaluator where those two are in the same
             scope. *)
          let piece = String.sub s !last (a - !last) in
          let groups =
            List.init
              (Re.Group.nb_groups g - 1)
              (fun i -> lazy (group_value g (i + 1)))
          in
          emit (lazy (str piece)) ;
          emit (lazy (Value.List groups)) ;
          last := b ;
          if b = a then collect (a + 1) else collect b
  in
  collect 0 ;
  let tail = String.sub s !last (n - !last) in
  emit (lazy (str tail)) ;
  Value.List (List.rev !out)

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
      primop "match" 2 match_primop;
      primop "split" 2 split_primop;
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
      primop "concatMap" 2 concat_map_primop;
      primop "partition" 2 partition_primop;
      primop "groupBy" 2 group_by_primop;
      primop "genericClosure" 1 generic_closure_primop;
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
      primop "zipAttrsWith" 2 zip_attrs_with_primop;
      primop "unsafeGetAttrPos" 2 unsafe_get_attr_pos_primop;
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
      primop "trace" 2 trace_primop;
      primop "warn" 2 warn_primop;
      primop "addErrorContext" 2 add_error_context_primop;
      primop "deepSeq" 2 seq_primop;
      (* paths *)
      primop "baseNameOf" 1 base_name_of_primop;
      primop "dirOf" 1 dir_of_primop;
      primop "pathExists" 1 path_exists_primop;
      primop "import" 1 import_primop;
      primop "readFile" 1 read_file_primop;
      primop "readDir" 1 read_dir_primop;
      primop "readFileType" 1 read_file_type_primop;
      primop "getEnv" 1 get_env_primop;
      primop "toFile" 2 to_file_primop;
      (* JSON *)
      primop "toJSON" 1 to_json_primop;
      (* versions and names *)
      primop "splitVersion" 1 split_version_primop;
      primop "compareVersions" 2 compare_versions_primop;
      primop "parseDrvName" 1 parse_drv_name_primop;
      (* string context, as data *)
      primop "hasContext" 1 has_context_primop;
      primop "getContext" 1 get_context_primop;
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
      ("storeDir", lazy (str "/nix/store"));
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
