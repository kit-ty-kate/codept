
type format = Json | Sexp

type (_,_) eq = Eq : ('a,'a) eq
type void = (int,float) eq

module L = struct
  type 'a t = 'a list =
    | [  ]
    | (::) of 'a * 'a t
end
module S = Name.Set

module Tuple = struct
  type 'a tuple =
    | []: void tuple
    | (::): 'a * 'b tuple -> ('a * 'b) tuple
  type 'a t = 'a tuple
end
open Tuple

module type label = sig type t val l:string end
type 'a label = (module label with type t = 'a)
module Label(X:sig val l:string end) =
struct
  type t
  type s = t
  include X
  module M = struct type t = s let l = l end
  let l: t label = (module M)
end

let show (type a) ((module X):a label) = X.l

type required = private Required
type optional = private Optional

type (_,_,_) modal =
  | Opt:(optional,'a,'a option) modal
  | Req:(required,'a,'a) modal

(*
type ('m,'a) elt =
  | Just: 'a -> ('any,'a) elt
  | Nothing: (optional,'any) elt
*)


module Record = struct
  type 'a record =
    | []: void record
    | (::): ( 'a label * 'elt) * 'c record ->
      ('a * 'elt * 'c) record
  type 'a t = 'a record
end
open Record

type ('a,'b) bijection = { fwd:'a->'b;rev:'b -> 'a}

type 'hole t =
  | Float: float t
  | Int: int t
  | Bool: bool t
  | String: string t
  | Void: void t
  | Array: 'hole t -> 'hole list t
  | (::) : 'a t * 'b tuple t -> ('a * 'b) tuple t
  | []: void tuple t
  | Obj:'a record_declaration -> 'a record t
  | Custom: ('a,'b) custom -> 'a t
  | Sum: 'a sum_decl -> 'a sum t

and ('a,'b) custom = { fwd:'a -> 'b; rev:'b -> 'a; sch:'b t; id:string }
and 'a record_declaration =
  | []: void record_declaration
  | (::): ( ('m,'x,'fx) modal * 'a label * 'x t) * 'c record_declaration
    -> (  'a * 'fx * 'c ) record_declaration

and 'a sum_decl =
    | [] : void sum_decl
    | (::): (string * 'a t) * 'b sum_decl -> ('a * 'b) sum_decl

and (_,_) cons =
  | Z: 'a -> ('a * 'any,'a) cons
  | E: (void * 'any,'a) cons
  | S: ('a, 'n ) cons -> ('any * 'a, 'n) cons

and 'a sum = C: ('a, 'elt ) cons -> 'a sum

(*
type ('m,'a,'b) field = 'a name * ('m, 'b) elt*)

type 'a s = {
  title: string;
  description: string;
  sch: 'a t;
}

let k ppf name = Pp.fp ppf {|"%s"|} name
let p ppf (key,data)=
  Pp.fp ppf {|@[%a@ :@ "%s"@]|} k key data

let ty ppf data = p ppf ("type",data)

let rec json_type: type a. Format.formatter -> a t -> unit =
  fun ppf -> function
    | Float -> ty ppf "number"
    | Int -> ty ppf "number"
    | String -> ty ppf "string"
    | Bool -> ty ppf "string"
    | Void -> ()
    | Array t -> Pp.fp ppf
                   "%a,@;@[<hov 2>%a : {@ %a@ }@]"
                   ty "array" k "items" json_type t
    | [] -> ()
    | _ :: _ as l ->
      Pp.fp ppf "%a,@; @[<hov 2>%a :[@ %a@ ]@]" ty "array" k "items"
        json_schema_tuple l
    | Obj r ->
      Pp.fp ppf "%a,@;@[<v 2>%a : {@ %a@ }@],@;@[<hov 2>%a@ :@ [@ %a@ ]@]"
        ty "object"
        k "properties"
        json_properties r
        k "required"
        (json_required true) r
    | Custom { id ; _ }->
      Pp.fp ppf "@[<hov 2>%a@ :@ \"#/definitions/%s\"@]" k "$ref" id
    | Sum decl ->
      Pp.fp ppf "@[<hov 2>%a :[%a]@]"
        k "oneOf" (json_sum true 0) decl
and json_schema_tuple: type a. Format.formatter -> a tuple t -> unit =
  fun ppf -> function
    | [] -> ()
    | [a] -> Pp.fp ppf {|@[<hov 2>{@ %a@ }@]|}
               json_type a
    | a :: q ->
      Pp.fp ppf {|@[<hov 2>{@ %a@ }@],@; %a|}
        json_type a json_schema_tuple q
    | Custom _ -> assert false
and json_properties: type a. Format.formatter -> a record_declaration -> unit =
  fun ppf -> function
  | [] -> ()
  | [_, n, a] -> Pp.fp ppf {|@[<hov 2>"%s" : {@ %a@ }@]|}
      (show n) json_type a
  | (_, n, a) :: q ->
     Pp.fp ppf {|@[<hov 2>"%s" : {@ %a@ }@],@;%a|}
       (show n) json_type a json_properties q
and json_required: type a. bool ->Format.formatter -> a record_declaration
  -> unit =
  fun first ppf -> function
  | [] -> ()
  | (Req, n, _) :: q ->
    Pp.fp ppf {|%t"%s"%a|}
      (fun ppf -> if not first then Pp.fp ppf ",@ " else ())
      (show n)
      (json_required false) q
  | _ :: q -> json_required first ppf q
and json_sum: type a. bool -> int -> Format.formatter -> a sum_decl -> unit =
  fun first n ppf -> function
    | [] -> ()
    | (s, Void) :: q  ->
      if not first then Pp.fp ppf ",@,";
      Pp.fp ppf "@[{%a@ :@ [\"%s\"]}@]%a" k "enum" s (json_sum false @@ n + 1) q
    | (s,a)::q ->
      if not first then Pp.fp ppf ",@,";
      let module N = Label(struct let l = s end) in
      Pp.fp ppf "{%a}%a" json_type (Obj[Req,N.l,a]) (json_sum false @@ n + 1) q

let json_definitions ppf sch =
  let rec json_definitions:
    type a.  bool * S.t -> Format.formatter -> a t ->  bool * S.t =
    fun (first,set as st) ppf -> function
      | Float -> st | Int -> st | String -> st | Bool -> st | Void -> st
      | Array t -> json_definitions st ppf t
      | Obj [] -> st
      | Obj ( (_,_,x) :: q ) ->
        let st = json_definitions st ppf x in
        json_definitions st ppf (Obj q)
      | [] -> st
      | a :: q ->
        let st = json_definitions st ppf a in
        json_definitions st ppf q
      | Sum [] -> st
      | Sum ((_,a) :: q) ->
        let st = json_definitions st ppf a in
        json_definitions st ppf (Sum q)
      | Custom{id; _ } when S.mem id set -> st
      | Custom{id; sch; _ } ->
        if not first then Pp.fp ppf ",@,";
        Pp.fp ppf "@[<hov 2>%a@ :{@;%a@;}@]" k id json_type sch;
        let set = S.add id set in
        json_definitions (false,set) ppf sch
  in
  ignore @@ json_definitions (true,S.empty) ppf sch

let rec json: type a. a t -> Format.formatter -> a -> unit =
  fun sch ppf x -> match sch, x with
    | Int, n -> Pp.fp ppf "%d" n
    | Float, f -> Pp.fp ppf "%f" f
    | String, s -> Pp.estring ppf s
    | Bool, b -> Pp.fp ppf "%b" b
    | Void, _ -> .
    | Array k, l ->
      Pp.fp ppf "@[<hov>[%a]@]"
        (Pp.list ~sep:(Pp.s ",@ ") @@ json k) l
    | [], [] -> ()
    | _ :: _ as sch , l -> Pp.fp ppf "@[<hov>[%a]@]" (json_tuple sch) l
    | Obj sch, x -> Pp.fp ppf "@[<hv>{@ %a@ }@]" (json_obj false sch) x
    | Custom c, x -> json c.sch ppf (c.fwd x)
    | Sum q, x -> json_sum 0 q ppf x
and json_sum: type a. int -> a sum_decl -> Format.formatter -> a sum -> unit =
  fun n sch ppf x -> match sch, x with
    | (n,a) :: _ , C Z x ->
      let module N = Label(struct let l=n end) in
      json (Obj [Req, N.l, a]) ppf (Record.[N.l, x])
    | (n,_) :: _ , C E ->
      json String ppf n
    | _ :: q, C S c -> json_sum (n+1) q ppf (C c)
    | [], _ -> .

and json_tuple: type a. a tuple t -> Format.formatter -> a tuple -> unit =
  fun sch ppf x -> match sch, x with
    | [], [] -> ()
    | [a], [x] -> json a ppf x
    | a :: q, x :: xs -> Pp.fp ppf "%a,@ %a" (json a) x (json_tuple q) xs
    | Custom _, _ -> assert false

and json_obj: type a.
  bool -> a record_declaration -> Format.formatter -> a record -> unit =
  fun not_first sch ppf x -> match sch, x with
    | [], [] -> ()
    | (Req, name,sch) :: q ,   (_, x) :: xs ->
      if not_first then Pp.fp ppf ",@ ";
      Pp.fp ppf {|@[<hov 2>"%s"@ :@ %a@]|} (show name) (json sch) x;
      Pp.fp ppf "%a" (json_obj true q) xs
    | (Opt,name,sch) :: q, (_,Some x) :: xs ->
      if not_first then Pp.fp ppf ",@ ";
      Pp.fp ppf {|@[<hov 2>"%s"@ :@ %a@]|} (show name) (json sch) x;
      Pp.fp ppf "%a" (json_obj true q) xs
    | (Opt,_,_) :: q, (_, None ) :: xs ->
      json_obj not_first q ppf xs

let json s = json s.sch
let json_schema ppf s =
  Pp.fp ppf
    "@[<v 2>{@ \
     %a,@;\
     %a,@;\
     %a,@;\
     @[%a :@ {%a},@]@;\
     %a\
      @ }@]@."
     p ("$schema", "http://json-schema.org/schema#")
     p ("title", s.title)
     p ("description", s.description)
     k "definitions" json_definitions s.sch
     json_type s.sch

let cstring ppf s =
  begin try
      ignore(String.index s ' ');
      Pp.estring ppf s
    with
      Not_found -> Pp.string ppf s
  end

let rec sexp: type a. a t -> Format.formatter -> a -> unit =
  fun sch ppf x -> match sch, x with
    | Int, n -> Pp.fp ppf "%d" n
    | Float, f -> Pp.fp ppf "%f" f
    | Bool, b -> Pp.fp ppf "%b" b
    | String, s -> cstring ppf s
    | Void, _ -> .
    | Array k, l ->
      Pp.fp ppf "@[<hov>(%a)@]"
        (Pp.list ~sep:(Pp.s "@ ") @@ sexp k) l
    | Obj sch, x -> Pp.fp ppf "@[<hov>(@;<1 2>%a@;<1 2>)@]" (sexp_obj sch) x
    | [], [] -> ()
    | _ :: _ as tu, t -> Pp.fp ppf "@[<hov>(@;%a@;)@]" (sexp_tuple tu) t
    | Custom r, x -> sexp r.sch ppf (r.fwd x)
    | Sum s, x -> sexp_sum 0 s ppf x
and sexp_tuple: type a. a Tuple.t t -> Format.formatter -> a Tuple.t -> unit =
  fun ty ppf t -> match ty, t with
    | [], [] -> ()
    | [a], [x] -> sexp a ppf x
    | a :: q, x :: xs -> Pp.fp ppf "%a@ %a" (sexp a) x (sexp_tuple q) xs
    | Custom _, _ -> assert false
and sexp_sum: type a. int -> a sum_decl -> Format.formatter -> a sum -> unit =
  fun n decl ppf x -> match decl, x with
    | (n,a) :: _ , C Z x -> sexp [String;a] ppf Tuple.[n;x]
    | (n,_) :: _ , C E -> sexp String ppf n
    | _ :: q, C S c -> sexp_sum (n+1) q ppf (C c)
    | [] , _ -> .
and sexp_obj: type a.
  a record_declaration -> Format.formatter -> a record -> unit =
  fun sch ppf x -> match sch, x with
    | [], [] -> ()
    | (Req, name,sch) :: q ,   (_, x) :: xs ->
      Pp.fp ppf {|(%a@ %a)|} cstring (show name) (sexp sch) x;
      begin match q, xs  with
        | [], [] -> ()
        | _ -> Pp.fp ppf "@ %a" (sexp_obj q) xs
      end
    | (Opt, name,sch) :: q ,   (_, Some x) :: xs ->
      Pp.fp ppf {|(%a@ %a)|} cstring (show name) (sexp sch) x;
      begin match q, xs  with
        | [], [] -> ()
        | _ -> Pp.fp ppf "@ %a" (sexp_obj q) xs
      end

    | (Opt,_,_) :: q, (_, None ) :: xs -> sexp_obj q ppf xs

let sexp x = sexp x.sch

let ($=) field x = field, x
let skip name = name, None

let ($=?) field x = match x with
  | Some x -> field $= Some x
  | None -> skip field

let obj (x:_ record)= x
let custom id sch fwd rev = Custom {fwd;rev; sch; id}

module Untyped = struct
type t =
  | Array of t list
  | List of t list
  | Atom of string
  | Obj of (string * t) list
type untyped = t
end
type untyped = Untyped.t =
  | Array of untyped list
  | List of untyped list
  | Atom of string
  | Obj of (string * untyped) list

let promote_to_obj l =
  let promote_pair = function List [Atom x;y] -> Some(x,y) | _ -> None in
  Option.List'.map promote_pair l

let rec retype: type a. a t -> untyped -> a option =
  let open Option in
  fun sch u -> match sch, u with
    | Int, Atom u -> int_of_string_opt u
    | Float, Atom u -> float_of_string_opt u
    | Bool, Atom u -> bool_of_string_opt u
    | String, Atom s -> Some s
    | Array t, (Array ul | List ul) ->
      Option.List'.map (retype t) ul
    |  [], Array [] -> Some []
    | (a::q), (Array(ua :: uq) | List(ua :: uq)) ->
        retype a ua >>= fun h ->
        retype q (Array uq) >>| fun q ->
        Tuple.(h :: q)
    | Obj r, Obj ur ->
      retype_obj r ur
    | Obj r, List ur ->
      promote_to_obj ur >>= fun obj ->
      retype_obj r obj
    | Custom r, x -> retype r.sch x >>| r.rev
    | Sum s, Atom x ->
      retype_const_sum s x
    | Sum s, (Obj[x,y]|List[Atom x;y]) ->
      retype_sum s x y
    | _ -> None
and retype_obj: type a. a record_declaration -> (string * untyped) list ->
  a record option = fun sch x ->
  let open Option in
  match sch, x with
  | [], [] -> Some []
  | (Req, field, t) :: q , (ufield, u) :: uq when show field = ufield ->
    retype t u >>= fun h ->
    retype_obj q uq >>| fun l ->
    Record.( (field $= h) :: l )
  | (Opt, field, t) :: q , (ufield, u) :: uq when show field = ufield ->
    retype t u >>= fun h ->
    retype_obj q uq >>| fun l ->
    Record.( (field $=? Some h) :: l )
  | (Opt,field,_) :: q , l ->
    retype_obj q l >>| fun l ->
    Record.( skip field :: l )
  | _ -> None

and retype_sum: type a. a sum_decl -> string -> untyped -> a sum option =
  let open Option in
  fun decl n u ->
    match decl with
    | (s,a) :: _  when s = n ->
      retype a u >>| fun a -> C(Z a)
    | [] -> None
    |  _ :: q ->
      retype_sum q n u >>| fun (C c) -> (C (S c))

and retype_const_sum: type a. a sum_decl -> string -> a sum option =
  let open Option in
  fun decl n -> match decl with
    | ( (s, Void) :: _ ) when s = n -> Some (C E)
    | [] -> None
    | _ :: q ->
      retype_const_sum q n >>| fun (C c) -> (C (S c))

let minify ppf =
  let f = Format.pp_get_formatter_out_functions ppf () in
  let space_needed = ref false in
  let out_string s start stop =
    let special c =
      match c with
      | '(' | ',' |'{' | '"' |'[' | ')'| ']'| '}' -> true
      | _ -> false in
    if !space_needed && not (special s.[start]) then
      f.out_string " " 0 1;
    f.out_string s start stop;
    space_needed := not (special s.[stop-1]) in
  let basic =
    { f with Format.out_newline = (fun () -> ());
             out_spaces = (fun _ -> ());
             out_string } in
  Format.pp_set_formatter_out_functions ppf basic;
  Format.kfprintf (fun _ -> Format.pp_set_formatter_out_functions ppf f;
                    Format.pp_flush_formatter ppf) ppf


let default x y = if x = y then None else Some y

let option (type a) name (sch:a t) =
  custom ("Option."^name) (Sum ["None", Void; "Some", sch])
    (function None -> C E | Some x -> C (S(Z x)))
    (function C E -> None | C S Z x -> Some x | C S E -> None |  _ -> . )