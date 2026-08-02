(** NAR: the Nix Archive format, and the store path of a source.

    The last unspecified corner of the format ([docs/spec/canonical.md] section
    3), and the one half of the `.drv` references rule that nothing we produced
    could exercise: a derivation's fingerprint lists its [inputDrvs] AND its
    [inputSrcs], and until now every derivation we built had an empty
    [inputSrcs].

    {1 The format}

    NAR is a CANONICAL serialization of a filesystem object, and canonical is
    the whole point: two directories with the same contents serialize to the
    same bytes regardless of inode order, mtimes, ownership, or permissions
    beyond one bit. Everything a filesystem records that is not content is
    deliberately discarded.

    The grammar, from the Nix thesis (Dolstra 2006, figure 5.2):

    {v
    serialise(fso)  = str("nix-archive-1") ++ node(fso)
    node(fso)       = str("(") ++ body(fso) ++ str(")")

    body(Regular)   = str("type") str("regular")
                      [ str("executable") str("") ]
                      str("contents") str(contents)
    body(Symlink)   = str("type") str("symlink") str("target") str(target)
    body(Directory) = str("type") str("directory") entry*

    entry           = str("entry") str("(") str("name") str(name)
                      str("node") node str(")")

    str(s)          = int(len s) ++ s ++ zero padding to a multiple of 8
    int(n)          = 8 bytes, little endian
    v}

    Three details decide whether an implementation is right, and all three are
    invisible in a happy-path test:

    - directory entries are sorted by name BYTE-wise, not by locale;
    - the executable BIT is the only permission preserved, and it is encoded as
      the PRESENCE of a field rather than as a value;
    - padding is to eight bytes with zeroes, so a length already a multiple of
      eight adds NOTHING rather than a full block.

    {1 The store path}

    A source added to the store is the [source] kind of
    [docs/spec/store-paths.md], with the NAR's sha256 as the inner hash:

    {v source_path = store_path("source", sha256(nar(fso)), name) v}

    and it takes the SAME references treatment as a `.drv`: the kind becomes
    [source:<ref>:<ref>:...] when the object refers to other store paths. That
    is [makeType] in Nix, shared by both, which is why getting it wrong for
    [text] got it wrong for [source] too.

    {1 Why this file takes a TREE and not a path}

    A filesystem object is an inductive type, the initial algebra of

    {v F(X) = (contents x executable) + target + (name x X)* v}

    and NAR is the unique homomorphism out of it into strings: a CATAMORPHISM.
    Writing it that way rather than as a directory walk keeps the library pure
    (no [unix], so the zero-dependency promise holds), makes the serializer
    testable without a filesystem, and puts the interesting part where it can be
    read. Materialising the tree from a real directory is the CLI's job. *)

open Types

(** A filesystem object, as NAR understands one.

    Note what is absent: mtimes, ownership, and every permission bit except the
    executable one. NAR does not discard them as an optimisation; a format that
    kept them could not be canonical. *)
type fso =
  | Regular of {executable : bool; contents : string}
  | Symlink of string
  | Directory of (string * fso) list

let buf_add = Buffer.add_string

(** Zero-pad to a multiple of eight, adding NOTHING when already aligned. *)
let pad b len =
  let remainder = len mod 8 in
  if remainder <> 0 then buf_add b (String.make (8 - remainder) '\000')

let int64_le n =
  let b = Bytes.create 8 in
  for i = 0 to 7 do
    Bytes.set b i (Char.chr ((n lsr (i * 8)) land 0xff))
  done ;
  Bytes.to_string b

let str b s =
  buf_add b (int64_le (String.length s)) ;
  buf_add b s ;
  pad b (String.length s)

let rec node b fso =
  str b "(" ;
  (match fso with
  | Symlink target ->
      str b "type" ;
      str b "symlink" ;
      str b "target" ;
      str b target
  | Directory entries ->
      str b "type" ;
      str b "directory" ;
      (* Sorted BY BYTES. A locale-aware sort produces a different archive, and
         therefore a different store path, for the same directory. *)
      List.iter
        (fun (name, child) ->
          str b "entry" ;
          str b "(" ;
          str b "name" ;
          str b name ;
          str b "node" ;
          node b child ;
          str b ")")
        (List.sort (fun (a, _) (c, _) -> String.compare a c) entries)
  | Regular {executable; contents} ->
      str b "type" ;
      str b "regular" ;
      (* The executable bit is the ONLY permission NAR keeps, and it is encoded
         as a present-or-absent FIELD rather than as a value. *)
      if executable then begin
        str b "executable" ;
        str b ""
      end ;
      str b "contents" ;
      str b contents) ;
  str b ")"

(** A filesystem object, serialized to its canonical NAR bytes. *)
let nar fso =
  let b = Buffer.create 4096 in
  str b "nix-archive-1" ;
  node b fso ;
  Buffer.contents b

(** The sha256 of the NAR, as 64 lowercase hex characters. *)
let nar_hash fso = Sha256.hex (nar fso)

(** The store path a source lands at, as [nix-store --add] computes it.

    [references] take the same treatment as a `.drv`'s: sorted, joined with
    colons, and appended to the kind. Shared with the [text] kind through Nix's
    [makeType], which is why one bug in that rule was two bugs. *)
let source_path ?(references = []) ~name fso =
  let refs = List.sort_uniq String.compare references in
  let kind =
    if refs = [] then "source" else "source:" ^ String.concat ":" refs
  in
  Store.store_path ~kind ~inner:(Sha256_hex.v (nar_hash fso)) ~name
