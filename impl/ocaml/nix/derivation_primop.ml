(** [derivation]: the seam between the Nix language and the IR.

    This is the arrow the project existed to build. Everything else either
    describes derivations directly (the four eDSLs) or moves syntax around (the
    parser, the printer, the transpiler). This is the map

    {v EXPR  --eval-->  DRV v}

    and it is the only one that is not structural.

    {1 Why it cannot be a catamorphism}

    NAR was a catamorphism ([docs/abstractions.md] entry 17): the unique
    homomorphism out of an initial algebra, hence no freedom, hence four
    implementations agreeing on the first run. Evaluation cannot be that.
    [Ast.t] has BINDERS, so it is not the initial algebra of a polynomial
    functor over sets; it is initial in a presheaf category (Fiore, Plotkin and
    Turi 1999), which is to say it presents a SECOND-ORDER algebraic theory.

    The signature in [docs/spec/signature.md] has no binders at all. So [eval]
    is the map that QUOTIENTS the second-order theory down to the first-order
    one, and this file is where that collapse happens: everything about
    variables, scope, laziness and functions has to be gone by the time a value
    reaches [Edsl.derive].

    {1 The dependency edges are not read, they are COMPUTED}

    The one mechanism worth naming. In the eDSLs the caller passes [input_drvs]
    by hand: the edge is data the user supplies, and a user who forgets it gets
    a derivation that is well formed and wrong. Here nobody supplies it. A
    string carries a CONTEXT ([value.ml]), context is a monoid homomorphism
    over concatenation, and this function is the join-semilattice homomorphism
    out of it:

    {v P_fin(ctx_elem)  -->  inputSrcs x inputDrvs v}

    partitioning by the constructor. Interpolating a derivation into any
    attribute of another, however deeply nested inside a list or a
    concatenation, therefore produces the edge, because a homomorphism cannot
    lose what it is defined on.

    {1 Where this deviates from real Nix, and why}

    Real Nix splits this in two: a primop [derivationStrict] that does the work
    below, and a Nix-language wrapper in [corepkgs/derivation.nix] that adds
    [type], [all], [outputName] and the per-output attribute sets. We do both
    here in one primop.

    The split exists in Nix so the wrapper can be written in Nix. It buys us
    nothing yet and would cost an evaluator complete enough to run the wrapper
    (it needs [listToAttrs], [getAttr], [map] and [//] over generated names).
    When the builtins are there, moving the wrapper into Nix source is a
    faithfulness improvement worth making, and it is recorded here rather than
    silently skipped.

    Real Nix also reads a dependency's [.drv] back OUT OF THE STORE to recover
    the input hash it needs. We have no store on disk during evaluation, so
    {!store} keeps the derivations this evaluator has built. Same information,
    obtained without a filesystem. *)

open Value
open Img_drv
open Img_drv.Types

(** The derivations this evaluator has produced, keyed by their store path.

    Stands in for the real store during evaluation. A dependency's input hash
    is needed to build the referring derivation's own fingerprint, and real Nix
    gets it by reading the [.drv] file back; we remember it instead. *)
let store : (string, Edsl.drv) Hashtbl.t = Hashtbl.create 64

let reset () = Hashtbl.reset store

(** Split a context into the two fields it becomes.

    The join-semilattice homomorphism of the header comment, written out. Note
    that it is TOTAL: every constructor has a case, so no context element can
    be silently dropped, which is the failure that would produce a derivation
    of the right shape with the wrong identity. *)
let partition_context (ctx : Context.t) =
  let srcs = ref [] and drvs = ref [] in
  Context.iter
    (fun elem ->
      match elem with
      | Opaque p -> srcs := p :: !srcs
      | Built (output, drv) -> drvs := (drv, output) :: !drvs
      | Drv_deep drv -> (
          (* The derivation and its whole closure. We depend on every output it
             declares, which is what "deep" means here. *)
          match Hashtbl.find_opt store drv with
          | Some d ->
              List.iter
                (fun (o : Derivation.output) ->
                  drvs := (drv, Output_name.to_string o.name) :: !drvs)
                d.Edsl.derivation.Derivation.outputs
          | None -> srcs := drv :: !srcs))
    ctx ;
  (!srcs, !drvs)

(** Group [(drv, output)] pairs into one [Edsl.dep] per derivation.

    A derivation depending on two outputs of the same input is ONE edge naming
    two outputs, not two edges. Getting this wrong changes the fingerprint. *)
let deps_of_pairs pairs =
  let table = Hashtbl.create 8 in
  List.iter
    (fun (drv, output) ->
      let prev = Option.value (Hashtbl.find_opt table drv) ~default:[] in
      if not (List.mem output prev) then
        Hashtbl.replace table drv (output :: prev))
    pairs ;
  Hashtbl.fold
    (fun drv outputs acc ->
      match Hashtbl.find_opt store drv with
      | None -> error "unknown derivation %s in a string context" drv
      | Some d ->
          {
            Edsl.dep_path = Store_path.v drv;
            dep_input_hash = d.Edsl.input_hash;
            dep_outputs =
              List.sort_uniq String.compare outputs |> List.map Output_name.v;
          }
          :: acc)
    table
    []

(** Nix writes the algorithm as a plain string; the IR wants the variant. *)
let algo_of_string = function
  | "md5" -> Edsl.Md5
  | "sha1" -> Edsl.Sha1
  | "sha256" -> Edsl.Sha256
  | "sha512" -> Edsl.Sha512
  | a -> error "unknown hash algorithm %s" a

(** Validate a name, turning the IR's [result] into an evaluation error.

    The IR refuses to build a [Name.t] that a store path could not carry, which
    is the invariant [types.ml] exists to enforce. Here that refusal has to
    become a Nix error rather than a pattern-match failure. *)
let name_of (s : string) =
  match Name.of_string s with
  | Ok n -> n
  | Error e -> error "invalid derivation name %S: %s" s e

let get (a : attrs) (k : string) = attrs_find a k

let get_string (a : attrs) (k : string) =
  match get a k with
  | None -> None
  | Some t -> Some (fst (Eval.coerce_to_string (force t)))

let require_string (a : attrs) (k : string) =
  match get_string a k with
  | Some s -> s
  | None -> error "required attribute %s missing in a derivation" k

(** Attributes the IR DERIVES rather than accepts as environment entries.

    Nix's environment does contain [name], [system], [builder], [outputs] and
    the [outputHash*] triple; the difference is where they come from. In the IR
    they are FIELDS, and {!Edsl.derive} synthesizes the env entries from them,
    refusing any caller that also passes them as env (see [reserved_keys]
    there, and [docs/spec/canonical.md] section 1.7). So the filter here is not
    "these are not env vars"; it is "the IR already knows".

    That refusal is a good invariant and it caught the first version of this
    file, which passed them twice. *)
let derived =
  [
    "name";
    "system";
    "builder";
    "args";
    "outputs";
    "outputHash";
    "outputHashAlgo";
    "outputHashMode";
    "__structuredAttrs";
  ]

let derivation_primop (args : thunk list) : value =
  let a =
    match force (List.hd args) with
    | Attrs a -> a
    | v -> error "value is %s while a set was expected" (type_name v)
  in
  let name = require_string a "name" in
  let system = require_string a "system" in
  let builder = require_string a "builder" in
  let ctx = ref Context.empty in
  let add c = ctx := Context.union !ctx c in
  (* Every attribute is coerced, and every coercion contributes its context.
     The env vars and the dependency edges therefore come from ONE traversal;
     they are two projections of the same fold, which is why an attribute
     cannot appear in the environment without its edge appearing too. *)
  let coerce t =
    let s, c = Eval.coerce_to_string (force t) in
    add c ;
    s
  in
  let arg_list =
    match get a "args" with
    | None -> []
    | Some t -> (
        match force t with
        | Value.List items -> List.map coerce items
        | v -> error "value is %s while a list was expected" (type_name v))
  in
  let outputs =
    match get a "outputs" with
    | None -> None
    | Some t -> (
        match force t with
        | Value.List items ->
            Some (List.map (fun i -> name_of (coerce i)) items)
        | v -> error "value is %s while a list was expected" (type_name v))
  in
  let structured_attrs =
    match get a "__structuredAttrs" with
    | Some t -> ( match force t with Bool b -> b | _ -> false)
    | None -> false
  in
  (* The two env encodings, and the whole difference between them.
     [docs/spec/canonical.md] section 1.8.

     WITHOUT structured attributes, every value is COERCED to a string, so an
     integer becomes "42" and a nested set is an error. WITH them, every value
     keeps its type and the whole thing is carried as one JSON document, so an
     implementation that coerces regardless produces valid output that hashes
     differently.

     Both paths accumulate context into the same accumulator, so the dependency
     edges do not depend on which encoding is in use. That is the property
     worth stating: the graph is a function of the VALUES, not of how they are
     serialized. *)
  let env =
    List.filter_map
      (fun (k, t) ->
        if List.mem k derived then None
        else if structured_attrs then Some (k, Eval.to_json (force t) ctx)
        else Some (k, Json.String (coerce t)))
      a
  in
  let fixed_output =
    match (get_string a "outputHash", get_string a "outputHashAlgo") with
    | Some hash, algo ->
        let mode =
          match get_string a "outputHashMode" with
          | Some "recursive" -> Edsl.Recursive
          | _ -> Edsl.Flat
        in
        Some
          (* SRI (sha256-<base64>) names its own algorithm, so an absent
             outputHashAlgo is not a defect: 11 of 93 real fixed-output
             derivations carry none. *)
          (match algo with
          | None -> Edsl.sri ~mode hash
          | Some a -> Edsl.fixed ~mode ~algo:(algo_of_string a) hash)
    | None, _ -> None
  in
  let srcs, drv_pairs = partition_context !ctx in
  let build =
    Edsl.build
      ~name:(name_of name)
      ~system
      ~builder
      ~args:arg_list
      ~env
      ~structured_attrs
      ?outputs
      ~input_drvs:(deps_of_pairs drv_pairs)
      ~input_srcs:(List.sort_uniq String.compare srcs |> List.map Store_path.v)
      ?fixed_output
      ()
  in
  match Edsl.derive build with
  | Error e -> error "%s" (Edsl.error_to_string e)
  | Ok d ->
      let path = Store_path.to_string d.Edsl.path in
      Hashtbl.replace store path d ;
      (* The returned set is what a Nix expression sees. The two interesting
         entries are the STRINGS WITH CONTEXT: interpolating [outPath]
         anywhere downstream is what creates the next edge, and no further
         bookkeeping is needed because the homomorphism does it. *)
      let outs = d.Edsl.derivation.Derivation.outputs in
      let out_names =
        List.map
          (fun (o : Derivation.output) -> Output_name.to_string o.name)
          outs
      in
      let output_attr (o : Derivation.output) =
        let n = Output_name.to_string o.name in
        ( n,
          lazy
            (Str
               (Store_path.to_string o.path, Context.singleton (Built (n, path))))
        )
      in
      let primary = List.hd out_names in
      let extra =
        [
          ("type", lazy (Str ("derivation", Context.empty)));
          ("drvPath", lazy (Str (path, Context.singleton (Drv_deep path))));
          ("outputName", lazy (Str (primary, Context.empty)));
          ( "outputs",
            lazy
              (Value.List
                 (List.map (fun n -> lazy (Str (n, Context.empty))) out_names))
          );
          ("outPath", snd (output_attr (List.hd outs)));
        ]
        @ List.map output_attr outs
      in
      (* Nix's [//]: the computed attributes win over the caller's. *)
      Attrs (attrs_of_list (extra @ a))
