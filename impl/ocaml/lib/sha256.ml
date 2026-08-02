(** SHA-256, written out.

    OCaml's [Digest] is MD5 only, so a sha256 has to come from somewhere. The
    other implementations get it free (Python's [hashlib], Go's [crypto/sha256])
    or from one approved dependency (Rust's [sha2]); adding an OCaml dependency
    for it would need approval, and writing it keeps this implementation at zero
    runtime dependencies like Python and Go.

    Hand-writing a hash function is normally a bad idea, and the reason it is
    acceptable here is that it has no silent failure mode. This function is
    checked against the published FIPS 180-4 test vectors, and then against
    2516 real nixpkgs derivations, 12 golden store paths, and byte-equality
    with three other implementations. A wrong bit changes every store path in
    the project and every one of those gates goes red at once.

    It is NOT offered as a general-purpose hash: no streaming interface, no
    constant-time claims, and nothing here is intended for a security boundary.
    See README.md. *)

let k =
  [|
    0x428a2f98l;
    0x71374491l;
    0xb5c0fbcfl;
    0xe9b5dba5l;
    0x3956c25bl;
    0x59f111f1l;
    0x923f82a4l;
    0xab1c5ed5l;
    0xd807aa98l;
    0x12835b01l;
    0x243185bel;
    0x550c7dc3l;
    0x72be5d74l;
    0x80deb1fel;
    0x9bdc06a7l;
    0xc19bf174l;
    0xe49b69c1l;
    0xefbe4786l;
    0x0fc19dc6l;
    0x240ca1ccl;
    0x2de92c6fl;
    0x4a7484aal;
    0x5cb0a9dcl;
    0x76f988dal;
    0x983e5152l;
    0xa831c66dl;
    0xb00327c8l;
    0xbf597fc7l;
    0xc6e00bf3l;
    0xd5a79147l;
    0x06ca6351l;
    0x14292967l;
    0x27b70a85l;
    0x2e1b2138l;
    0x4d2c6dfcl;
    0x53380d13l;
    0x650a7354l;
    0x766a0abbl;
    0x81c2c92el;
    0x92722c85l;
    0xa2bfe8a1l;
    0xa81a664bl;
    0xc24b8b70l;
    0xc76c51a3l;
    0xd192e819l;
    0xd6990624l;
    0xf40e3585l;
    0x106aa070l;
    0x19a4c116l;
    0x1e376c08l;
    0x2748774cl;
    0x34b0bcb5l;
    0x391c0cb3l;
    0x4ed8aa4al;
    0x5b9cca4fl;
    0x682e6ff3l;
    0x748f82eel;
    0x78a5636fl;
    0x84c87814l;
    0x8cc70208l;
    0x90befffal;
    0xa4506cebl;
    0xbef9a3f7l;
    0xc67178f2l;
  |]

(* A custom infix operator's precedence in OCaml comes from its FIRST
   CHARACTER, not from what it does. [&%] therefore sits at the level of [&&],
   BELOW [^%], so [a &% b ^% c] parses as [a &% (b ^% c)]: the wrong tree, with
   no warning. Every use below is parenthesised for that reason.

   This produced a wrong sha256 on the first run, and the FIPS 180-4 vectors in
   the test suite caught it immediately, which is why they are there. It is the
   OCaml entry in the same family as the Rust release-only shift and the Go
   nil-slice conflation: a language-specific trap in the one function whose
   output nothing downstream can sanity-check by eye. *)
let ( +% ) = Int32.add

let ( ^% ) = Int32.logxor

let ( &% ) = Int32.logand

let rotr x n =
  Int32.logor (Int32.shift_right_logical x n) (Int32.shift_left x (32 - n))

let shr = Int32.shift_right_logical

(** The padded message: the byte [0x80], then zeros, then the length in BITS as
    a big-endian 64-bit integer, so the total is a multiple of 64 bytes. *)
let pad msg =
  let len = String.length msg in
  let m = (len + 1) mod 64 in
  let padding = if m <= 56 then 56 - m else 120 - m in
  let total = len + 1 + padding + 8 in
  let b = Bytes.make total '\000' in
  Bytes.blit_string msg 0 b 0 len ;
  Bytes.set b len '\x80' ;
  Bytes.set_int64_be b (total - 8) (Int64.of_int (len * 8)) ;
  b

(** The digest of a string, as 32 raw bytes. *)
let digest_bytes msg =
  let b = pad msg in
  let h =
    [|
      0x6a09e667l;
      0xbb67ae85l;
      0x3c6ef372l;
      0xa54ff53al;
      0x510e527fl;
      0x9b05688cl;
      0x1f83d9abl;
      0x5be0cd19l;
    |]
  in
  let w = Array.make 64 0l in
  for block = 0 to (Bytes.length b / 64) - 1 do
    let base = block * 64 in
    for t = 0 to 15 do
      w.(t) <- Bytes.get_int32_be b (base + (t * 4))
    done ;
    for t = 16 to 63 do
      let x = w.(t - 15) and y = w.(t - 2) in
      let s0 = rotr x 7 ^% rotr x 18 ^% shr x 3 in
      let s1 = rotr y 17 ^% rotr y 19 ^% shr y 10 in
      w.(t) <- w.(t - 16) +% s0 +% w.(t - 7) +% s1
    done ;
    let a = ref h.(0)
    and bb = ref h.(1)
    and c = ref h.(2)
    and d = ref h.(3)
    and e = ref h.(4)
    and f = ref h.(5)
    and g = ref h.(6)
    and hh = ref h.(7) in
    for t = 0 to 63 do
      let s1 = rotr !e 6 ^% rotr !e 11 ^% rotr !e 25 in
      let ch = (!e &% !f) ^% (Int32.lognot !e &% !g) in
      let t1 = !hh +% s1 +% ch +% k.(t) +% w.(t) in
      let s0 = rotr !a 2 ^% rotr !a 13 ^% rotr !a 22 in
      let maj = (!a &% !bb) ^% (!a &% !c) ^% (!bb &% !c) in
      let t2 = s0 +% maj in
      hh := !g ;
      g := !f ;
      f := !e ;
      e := !d +% t1 ;
      d := !c ;
      c := !bb ;
      bb := !a ;
      a := t1 +% t2
    done ;
    h.(0) <- h.(0) +% !a ;
    h.(1) <- h.(1) +% !bb ;
    h.(2) <- h.(2) +% !c ;
    h.(3) <- h.(3) +% !d ;
    h.(4) <- h.(4) +% !e ;
    h.(5) <- h.(5) +% !f ;
    h.(6) <- h.(6) +% !g ;
    h.(7) <- h.(7) +% !hh
  done ;
  let out = Bytes.make 32 '\000' in
  Array.iteri (fun i x -> Bytes.set_int32_be out (i * 4) x) h ;
  out

(** Bytes as lowercase hex. *)
let to_hex bytes =
  String.concat
    ""
    (List.map
       (fun i -> Printf.sprintf "%02x" (Char.code (Bytes.get bytes i)))
       (List.init (Bytes.length bytes) Fun.id))

(** The digest of a string, as 64 lowercase hex characters. *)
let hex msg = to_hex (digest_bytes msg)
