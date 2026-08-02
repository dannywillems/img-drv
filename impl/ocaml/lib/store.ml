(** Store path computation.

    Verified against real derivations: 1259 of 1259 output paths across 805 real
    nixpkgs derivations, plus 12 of 12 golden examples. The rules are in
    [docs/spec/store-paths.md], and the structure behind them (output paths
    FACTOR through masking rather than solving a fixed point) in
    [docs/theory.md] section 7. *)

open Types

(** The store root every fingerprint is built against. *)
let store = "/nix/store"

(** Nix's own base-32 alphabet.

    Note the omissions: [e], [o], [u] and [t] are absent, so that no store path
    can accidentally spell a word. *)
let base32_alphabet = "0123456789abcdfghijklmnpqrsvwxyz"

(** How many base-32 digits encode [size] bytes. *)
let base32_length size = (((size * 8) - 1) / 5) + 1

(** Nix base-32: least significant digit first, five bits at a time.

    Not RFC 4648. Digits are emitted from the END of the buffer backwards, which
    is why a stock base-32 library produces a different string. This is the
    first thing to check when a path is close but wrong. *)
let base32 (data : Bytes.t) =
  let len = Bytes.length data in
  let n = base32_length len in
  let out = Bytes.make n '0' in
  for i = n - 1 downto 0 do
    let bit = i * 5 in
    let idx = bit / 8 and offset = bit mod 8 in
    let c = Char.code (Bytes.get data idx) lsr offset in
    let c =
      if idx + 1 < len && offset <> 0 then
        c lor (Char.code (Bytes.get data (idx + 1)) lsl (8 - offset))
      else c
    in
    Bytes.set out (n - 1 - i) base32_alphabet.[c land 0x1f]
  done ;
  Bytes.to_string out

(** The inverse of {!base32}.

    Needed because real fixed-output derivations write their hash in base-32 (or
    SRI) while the outputs tuple carries it as hex, so an implementation that
    cannot decode cannot reproduce the bytes. [size] is the expected digest
    length, which the encoding does not carry. *)
let base32_decode text size =
  if String.length text <> base32_length size then
    Error
      (Printf.sprintf
         "expected %d digits, got %d"
         (base32_length size)
         (String.length text))
  else begin
    let out = Bytes.make size '\000' in
    let bad = ref None in
    String.iteri
      (fun i ch ->
        let n = String.length text - 1 - i in
        match String.index_opt base32_alphabet ch with
        | None -> bad := Some (Printf.sprintf "not a Nix base-32 digit: %C" ch)
        | Some digit ->
            let bit = n * 5 in
            let idx = bit / 8 and offset = bit mod 8 in
            let cur = Char.code (Bytes.get out idx) in
            Bytes.set out idx (Char.chr (cur lor (digit lsl offset) land 0xff)) ;
            let carry = digit lsr (8 - offset) in
            if idx + 1 < size then begin
              let nxt = Char.code (Bytes.get out (idx + 1)) in
              Bytes.set out (idx + 1) (Char.chr (nxt lor carry land 0xff))
            end
            else if carry <> 0 then
              bad := Some "base-32 digits overflow the digest length")
      text ;
    match !bad with Some e -> Error e | None -> Ok out
  end

(** XOR-fold a digest down to [size] bytes.

    A store path carries 20 bytes, not 32, and the sha256 is folded rather than
    truncated: byte [i] of the digest is XORed into byte [i mod size].
    Truncating gives a plausible-looking path that is wrong. *)
let compress (h : Bytes.t) size =
  let out = Bytes.make size '\000' in
  Bytes.iteri
    (fun i b ->
      let j = i mod size in
      Bytes.set out j (Char.chr (Char.code (Bytes.get out j) lxor Char.code b)))
    h ;
  out

(** The sha256 of a string, as 64 lowercase hex characters. *)
let sha256_hex s = Sha256_hex.v (Sha256.hex s)

(** The outer step, shared by every kind of store path.

    [fingerprint = "<kind>:sha256:<inner hex>:<store dir>:<name>"] and the path
    is [<store dir>/<base32(compress(sha256(fingerprint)))>-<name>].

    Only [kind] and [inner] vary: [text] for a [.drv] file, [output:<name>] for
    a build output, [source] for a file added directly to the store. *)
let store_path ~kind ~inner ~name =
  let fingerprint =
    Printf.sprintf
      "%s:sha256:%s:%s:%s"
      kind
      (Sha256_hex.to_string inner)
      store
      name
  in
  let digest = Sha256.digest_bytes fingerprint in
  Store_path.v
    (Printf.sprintf "%s/%s-%s" store (base32 (compress digest 20)) name)

(** The store path of a fixed-output derivation.

    TWO schemes, selected by the ingestion method encoded in the algo field:
    [r:sha256] (recursive NAR ingestion with sha256) takes the [source] kind and
    uses the declared hash DIRECTLY as the inner hash; everything else builds
    the usual [fixed:out:] fingerprint first.

    Missing the first case costs exactly one path in a 226-derivation closure,
    which is how it survived a corpus written by hand. *)
let fixed_output_path (o : Derivation.output) drv_name =
  if String.equal o.hash_algo "r:sha256" then
    store_path ~kind:"source" ~inner:(Sha256_hex.v o.hash) ~name:drv_name
  else
    let inner =
      sha256_hex (Printf.sprintf "fixed:out:%s:%s:" o.hash_algo o.hash)
    in
    store_path ~kind:"output:out" ~inner ~name:drv_name

(** The hash by which a fixed-output derivation is known AS AN INPUT.

    Note the trailing store path. This is NOT the string used to compute the
    path itself, which ends at the colon; including the path there would be
    circular.

    Confusing the two is invisible until something DEPENDS on a fixed-output
    derivation, because the derivation's own path still comes out right. It
    accounted for every one of the 145 downstream failures in the first real
    corpus. *)
let fixed_output_input_hash (o : Derivation.output) =
  sha256_hex
    (Printf.sprintf
       "fixed:out:%s:%s:%s"
       o.hash_algo
       o.hash
       (Store_path.to_string o.path))

(** [out] keeps the plain name; every other output is suffixed. *)
let output_store_name drv_name output =
  let o = Output_name.to_string output in
  if String.equal o "out" then drv_name else drv_name ^ "-" ^ o

(** Every output path of a derivation.

    The asymmetry that matters: mask MY outputs, because they are what is being
    computed; do not mask my inputs'. *)
let output_paths (d : Derivation.t) drv_name input_hashes =
  match Derivation.fixed_output d with
  | Some fixed -> [(fixed.name, fixed_output_path fixed drv_name)]
  | None ->
      let inner =
        sha256_hex
          (Aterm.unparse_with
             d
             {Aterm.mask_outputs = true; input_hashes = Some input_hashes})
      in
      List.map
        (fun (o : Derivation.output) ->
          ( o.name,
            store_path
              ~kind:("output:" ^ Output_name.to_string o.name)
              ~inner
              ~name:(output_store_name drv_name o.name) ))
        d.outputs

(** The path of the [.drv] file itself: a [text] store object.

    [references] are the store paths the file MENTIONS: its [inputDrvs] and its
    [inputSrcs]. They are part of the fingerprint, sorted and inserted after
    the [text] kind:

    {v text:<ref>:<ref>:...:sha256:<inner>:<store dir>:<name> v}

    Omitting them is right for a derivation with no inputs and wrong for
    everything else. Verified against 1458 real nixpkgs [.drv] files, which are
    named by real Nix: 1458 of 1458 with references, 149 of 1458 without. *)
let drv_path ?(references = []) aterm drv_name =
  let refs = List.sort_uniq String.compare references in
  let kind = if refs = [] then "text" else "text:" ^ String.concat ":" refs in
  store_path ~kind ~inner:(sha256_hex aterm) ~name:(drv_name ^ ".drv")
