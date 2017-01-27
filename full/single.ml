(** Analysis on single files *)

type t =
  | Approx_file
  | One_pass
  | M2l
  | M2l_sexp

type single = Format.formatter -> Params.t -> Common.info * string -> unit

module Pkg = Paths.Pkg
open Params
open M2l

(** Printing directly from source file *)
let to_m2l policy sig_only (k,f) =
  match Common.classic k with
  | None -> None
  | Some k ->
    match Read.file k f with
    | _name, Ok x ->
      if sig_only then Some (M2l.Sig_only.filter x) else Some x
    | _, Error (Ocaml msg) -> Fault.handle policy Standard_faults.syntaxerr msg;
      None
    | _, Error M2l -> Fault.handle policy Codept_policies.m2l_syntaxerr f; None


let approx_file ppf _param (_,f) =
  let _name, lower, upper = Approx_parser.file f in
  Pp.fp ppf  "lower bound:%a@. upper bound:%a@."
    M2l.pp lower M2l.pp upper

let one_pass ppf param ( (_,filename) as f) =
  let param = param.analyzer in
  let module Param = (val Analysis.lift param) in
  let module Sg = Interpreter.Make(Envts.Base)(Param) in
  let start = to_m2l param.policy param.sig_only f in
  match Option.( start >>| Sg.m2l (Pkg.local filename) Envts.Base.empty ) with
  | None -> ()
  | Some (Ok (_state,d)) -> Pp.fp ppf "Computation finished:\n %a@." Module.Sig.pp d
  | Some (Error h) -> Pp.fp ppf "Computation halted at:\n %a@." M2l.pp h

let m2l ppf param f =
  let param = param.analyzer in
  let start = to_m2l param.policy param.sig_only f in
  let open Option in
  start
  >>| Normalize.all
  >>| snd
  >>| Pp.fp ppf  "%a@." M2l.pp
  >< ()

let m2l_sexp ppf param f =
  let param = param.analyzer in
  let start = to_m2l param.policy param.sig_only f in
  let open Option in
  start
  >>| Normalize.all
  >>| snd
  >>| M2l.sexp.embed
  >>| Pp.fp ppf  "%a@." Sexp.pp
  >< ()


let eval = function
  | Approx_file -> approx_file
  | One_pass -> one_pass
  | M2l -> m2l
  | M2l_sexp -> m2l_sexp
