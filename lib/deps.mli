
(** Edge type for qualifying dependencies *)
module Edge: sig
  type t =
    | Normal (**standard dependency *)
    | Epsilon (** immediate dependency *)
  val max: t -> t -> t
  val min: t -> t -> t
  val sch: t Schematic.t
end

type t
val empty: t
val sch: t Schematic.t


(** Add a new path to a dependency map or
    promote the type of an existing path to {!Edge.Epsilon} *)
val update: Paths.P.t -> Edge.t -> Paths.S.t -> t -> t
val make: Paths.P.t -> Edge.t -> Paths.S.t -> t

val merge: t -> t -> t
val (+) : t -> t -> t

val pp: Format.formatter -> t -> unit

val find: Paths.P.t -> t -> (Edge.t * Paths.S.t) option
val fold: (Paths.P.t -> Edge.t -> Paths.S.t -> 'acc -> 'acc) -> t -> 'acc -> 'acc

val of_list: (Paths.P.t * Edge.t * Paths.S.t ) list -> t

(** Forget edge type and go back to a simpler data structure *)
module Forget: sig
  val to_set: t -> Paths.P.set
  val to_list: t -> (Paths.P.t * Paths.S.t) list
end
