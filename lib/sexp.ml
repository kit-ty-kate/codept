type one = private Atomic
type n = private N
type z = private Z

type atomic = z * one
type many = z * n
type one_and_many = one * n

type 'kind kind =
  | Atomic: atomic kind
  | Many: many kind
  | One_and_many: one_and_many kind

type 'kind t =
  | Atom: string -> atomic t
  | List: any list -> many t
  | Keyed_list: string * any list -> one_and_many t
and any = Any: 'any t -> any

let rec any: type a. a t -> any = function
  | List (Any (Atom s) :: ( _ :: _ as l) ) -> any @@ Keyed_list(s,l)
  | List [Any (Atom _ as sexp)] -> any sexp
  | sexp ->  Any sexp

let rec pp: type any. Format.formatter -> any t -> unit =
  fun ppf -> function
  | Atom s -> Pp.string ppf s
  | List l -> Pp.( decorate "(" ")" @@ list ~sep:(s " ") @@ pp_any ) ppf l
  | Keyed_list (a,l) ->
    Pp.( decorate "(" ")" @@ list ~sep:(s " ") @@ pp_any ) ppf (Any (Atom a) :: l)
and pp_any ppf (Any s) = pp ppf s

let parse_atom: type any. any t -> string option =
  function
  | List _ -> None
  | Keyed_list _ -> None
  | Atom s -> Some s

let extract_atom (Atom s) = s
let atom s = Atom s

let parse_list: type some. some t -> any list option = function
  | Keyed_list (a,l) -> Some ( Any(Atom a) :: l )
  | List l -> Some l
  | Atom _ -> None


let extract_list: type k. (k * n) t -> any list =
  function
  | List l -> l
  | Keyed_list (s, l ) -> Any(Atom s) :: l


let forget_key (Keyed_list (s,q)) =
  List (Any( Atom s) :: q )

let extract_kl: type k. k t -> (string * any list) option =
  function
  | Keyed_list (s,q) -> Some (s,q)
  | List (Any(Atom s) :: q) -> Some (s,q)
  | Atom n -> Some(n,[])
  | List( Any (List _) :: _ ) -> None
  | List( Any (Keyed_list _) :: _ ) -> None
  | List [] -> None

let some x = Some x
let list' l = List l

let list'' = function
  | [Any(Keyed_list _ as k)] -> forget_key k
  | [Any(List _ as l)] -> l
  | sexp -> List sexp


type ('a,'b) impl = {
  embed: 'a -> 'b t;
  parse: 'b t -> 'a option;
  witness: 'b kind
}

module U = struct

 type _ witness = ..

  module type key = sig
    val name: string
    type elt
    type atomicity
    type _ witness += T: (elt * atomicity) witness
    val kind: atomicity kind
    val default: elt
  end

  type ('a,'b) key = (module key with type elt = 'a and type atomicity = 'b )

  let key (type e k) kind name default: (e,k) key =
    let module M = struct
      type elt = e
      type atomicity = k
      let name = name
      let default = default
      let kind = kind
      type _ witness += T: (elt * k) witness
    end in
    (module M)

  let witness (type a k) (key: (a,k) key) =
      let module K = (val key) in K.T

  let name (type a k) (key: (a,k) key) =
    let module K = (val key) in K.name

  let default (type a k) (key: (a,k) key) =
    let module K = (val key) in K.default

  type elt = E: { key: ('a * 'b) witness; value:'a } -> elt
  type mapper = M: { key: ('a,'b) key; value: ('a, 'b) impl } -> mapper

  let extract (type a k) (key: (a,k) key ) (E elt): a =
    let module M = (val key) in
    match elt.key with
    | M.T -> elt.value
    | _ -> M.default

  let extract_opt (type a b) (key: (a,b) key) (E elt): a option =
    let module M = (val key) in
    match elt.key with
    | M.T -> Some elt.value
    | _ -> None

    let extract_mapper (type a b) (key: (a,b) key ) (M m): (a,b) impl option =
      let module M = (val key) in
      let module K = (val m.key) in
      match K.T with
      | M.T ->  Some m.value
      | _ -> None

  module M = struct
    module I =Map.Make(struct type t = string let compare = compare end)
    type t = elt I.t
    type m = mapper I.t

    let empty:t = I.empty

    let find_opt key m =
      match I.find (name key) m with
      | exception Not_found -> None
      | x -> extract_opt key x

    let find key m =
      match I.find (name key) m with
      | exception Not_found -> default key
      | x -> extract key x

    let find_mapper key m =
      match I.find (name key) m with
      | exception Not_found -> None
      | x -> extract_mapper key x

    let add key value (m:t): t =
      I.add (name key) (E { key=witness key; value}) m

    let add_mapper key value m =
      I.add (name key) (M {key; value}) m

  end

end

let field key impl = U.M.add_mapper key impl
let definition =
  List.fold_left (|>) U.M.I.empty

module Record = struct
  let create = List.fold_left (|>) U.M.empty
  let field key value = U.M.add key value
  let get key r = U.M.find key r
end


open Option
let (%) f g x = f (g x)
let (%>) f g x = g (f x)


let reforge_kl m =
  m |> extract_kl >>| fun(s,n) -> Keyed_list(s,n)

let any_parse: type i. ('a,i) impl -> (any -> 'a option) =
  fun impl sexp ->
  match impl.witness, sexp with
  | Atomic, Any (Atom _ as sexp) -> impl.parse sexp
  | Atomic, Any (List _ ) -> None
  | Atomic, Any (Keyed_list _) -> None
  | Many, Any (List _ as sexp) -> impl.parse sexp
  | Many, ( Any(Atom _ ) as sexp) -> impl.parse (List [sexp])
  | Many, Any (Keyed_list _ as k) -> impl.parse (forget_key k)
  | One_and_many, Any m -> m |> reforge_kl >>= impl.parse


let atomic show parse =
  { parse = (fun s -> s |> extract_atom |> parse );
    embed = atom % show;
    witness = Atomic
  }

let list impl =
  let parse sexp =
    sexp |> extract_list |> List.map (any_parse impl) |> list_join in
  { parse;
    embed = list' % List.map (any % impl.embed);
    witness = Many;
  }


let map (impl_map: U.M.m) =
  let rec parse: type k. ( k * n ) t -> U.M.t option = function
    | List [] -> Some U.M.empty
    | List ( Any(Atom s) :: q ) -> parse @@ Keyed_list(s,q)
    | Keyed_list _ as kl -> parse @@ List [Any kl]
    | List( Any h :: q ) ->
      h |> extract_kl >>= fun (name,l) ->
      parse_elt name l >>= fun e ->
      List q |> parse >>= fun map ->
      some @@ U.M.I.add name e map
  and parse_elt: string -> any list -> U.elt option = fun a q ->
      match U.M.I.find a impl_map with
      | exception Not_found -> None
      | U.M {key;value} ->
        let module K = (val key) in
        match K.kind, q with
        | Atomic, [Any(Atom s)] ->
          Atom s |> value.parse >>| fun value ->
          U.E { key = U.witness key; value}
        | Many, q ->
          List q |> value.parse >>| fun value ->
          U.E { key = U.witness key; value}
        | One_and_many, Any(Atom s) :: q ->
          Keyed_list (s,q) |> value.parse >>| fun value ->
          U.E { key = U.witness key; value}
        | One_and_many, [] -> None
        | One_and_many, Any(List _) :: _ -> None
        | One_and_many, Any(Keyed_list _) :: _ -> None
        | Atomic, ([] | _ ::_ :: _)  -> None
        | Atomic, [Any(List _) ] -> None
        | Atomic, [Any(Keyed_list _) ] -> None
  in
  let embed_elt: type a k. string -> (a,k) impl -> a -> one_and_many t =
    fun name impl x ->
    match impl.witness with
    | Many ->
      let (List l) = impl.embed x in
      Keyed_list(name, l)
    | Atomic ->
      Keyed_list (name, [Any (impl.embed x) ])
    | One_and_many ->
      let (Keyed_list(s,l)) = impl.embed x in
      Keyed_list(name, Any (Atom s) :: l )
  in
  let embed_key univ sexp (_name, U.M {key; value} ) =
    match U.M.find_opt key univ with
    | None -> sexp
    | Some x ->
      if x <> U.default key then
        (any @@ embed_elt (U.name key) value x) :: sexp
      else
        sexp
  in
  let embed univ =
    list'' @@ List.rev @@
    List.fold_left (embed_key univ) [] (U.M.I.bindings impl_map)
  in
  {parse;embed;witness = Many }

let record l = map @@ definition l

let keyed_list key impl =
  let parse = function
    | List [] -> None
    | List ( Any (Atom a) :: q) when a = key ->
      q |> List.map (any_parse impl) |> list_join
    | List (_ :: _) -> None
  in
  let embed s = list' @@ Any (Atom key) :: ( List.map (any % impl.embed) s ) in
  {parse; embed; witness = Many}

type ('a,'b) bij = { f: 'a -> 'b; fr:'b -> 'a }

let id = { f = (fun x -> x); fr = (fun x -> x) }


type 'a constr =
  | C: {
      name:Name.t;
      proj:'a -> 'b option;
      inj: 'b -> 'a;
      impl: ('b, 'kind) impl;
      default: 'b option
    } -> 'a constr
  | Cs : { name:Name.t; value:'a} -> 'a constr

let cname = function
  | C c -> c.name
  | Cs c -> c.name

let sum l =
  let fold acc c=  Name.Map.add (cname c) c  acc in
  let m = List.fold_left fold Name.Map.empty l
       in
  let parse = function
    | Keyed_list (_, _ :: _ :: _ )-> None
    | Keyed_list (n, [b]) ->
      begin
        match Name.Map.find n m with
        | exception Not_found -> None
        | C cnstr -> (any_parse cnstr.impl b) >>| cnstr.inj
        | Cs _ -> None
      end
    | Keyed_list (n, []) ->
       match Name.Map.find n m with
        | exception Not_found -> None
        | C ({ default = Some value;_ } as c) -> Some (c.inj value)
        | C _ -> None
        | Cs c -> Some c.value
  in
  let embed x =
    let find c = match c with
      | C c -> c.proj x <> None
      | Cs c -> c.value = x in
    match List.find find l with
    | Cs c -> Keyed_list(c.name, [])
    | C cnstr ->
      match cnstr.proj x with
      | None -> raise (Invalid_argument "Sexp.sum")
      | Some inner ->
        match cnstr.default with
        | Some y when inner = y ->
          Keyed_list(cnstr.name,[])
        | _ ->
          Keyed_list (cnstr.name, [any (cnstr.impl.embed inner)]) in
  {parse;embed;witness=One_and_many}


let pair l r =
  let parse = function
    | List ([]| [_] |  _ :: _  :: _ :: _ ) -> None
    | List [a; b] -> any_parse l a && any_parse r b in
  let embed (a,b) = list' [any (l.embed a); any (r.embed b)] in
  {parse;embed; witness = Many }

let conv bij impl =
  let parse x =
    x |> impl.parse >>| bij.f in
  let embed s =
    s |> bij.fr |> impl.embed in
  {parse; embed; witness = impl.witness }

let convr impl f fr = conv {f;fr} impl

let opt: 'a 'b. ('a,'b) impl -> ('a option, many) impl =
  fun impl ->
  let parse = function
    | List [] -> Some None
    | List [a] -> any_parse impl a >>| some
    | List _ -> None
  in
  let embed = function
    | None -> List []
    | Some x -> List [ any (impl.embed x) ] in
  {parse;embed; witness = Many }


let cons l r =
  let parse = function
    | List [] -> None
    | List (a :: b) ->
      (any_parse l a && r.parse (List b)) >>| fun (a, b) -> a :: b
  in
  let embed list  =
    match list with
    | []  -> raise (Invalid_argument "Not enough arg in Sexp.cons")
    | a :: b ->
    let a' = l.embed a in
    match r.embed b with
    | List l -> List( any a' :: l ) in
  {parse;embed; witness = Many}

let pair' atom r =
  let parse = function
    | List [] -> None
    | List (a :: b) ->
      (any_parse atom a && r.parse (List b))
  in
  let embed (a,b)  =
    let a = atom.embed a in
    match r.embed b with
    | List l -> List( any a :: l ) in
  {parse;embed; witness = Many}

let major_minor major default minor =
  let parse = function
    | List [] -> None
    | List [a] -> any_parse major a && Some default
    | List [a; b] ->
      (any_parse major a && any_parse minor b)
    | List _ -> None
  in
  let embed (a,b)  =
    let a = major.embed a in
    if b = default then
      List [ any a ]
    else
      List [ any a; any @@ minor.embed b ] in
  {parse; embed; witness = Many }


let empty =
  let parse = function
    | List [] -> Some []
    | List (_ :: _) -> None in
  let embed _ =
    List [] in
  {parse; embed; witness = Many}

let singleton impl =
  let parse = function
    | List [a] -> any_parse impl a >>| fun x -> [x]
    | _ -> None in
  let embed a =
    match a with
    | [] | _ :: _ :: _ ->
      raise (Invalid_argument "Sexp.singleton: wrong number of elements")
    | [a] ->
    List [any (impl.embed a)] in
  {parse; embed; witness = Many}

let fix0 witness impl =
  let parse s = (impl()).parse s  in
  let embed o = (impl()).embed o in
  {witness;parse;embed}

let fix x = fix0 Many x
let fix' x = fix0 One_and_many x



let int0 s =
  try Some ( int_of_string s ) with
    Failure _ -> None

let int = atomic string_of_int int0
let string =
  let id x = x in
  atomic id some

let unit = {
  parse = (function List [] -> Some () | _ -> None);
  embed = (fun () -> List []);
  witness = Many
}

let simple_constr name value =
  Cs { name; value }