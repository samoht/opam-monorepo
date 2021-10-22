open Import
(** Utility functions to extract repository specific path and values *)

type t = Fpath.t

val local_packages :
  recurse:bool ->
  ?filter:OpamPackage.Name.t list ->
  t ->
  (Fpath.t String.Map.t, [> `Msg of string ]) result
(** Returns the locally defined opam packages as a map from package names to to
    the corresponding .opam file path. Only considers packages defined at the
    repo's root unless [recurse] is [true]. Only considers packages listed in
    [filter] if the parameter is used. *)

val dune_project : t -> Fpath.t
(** Returns the path to the dune-project file. *)

val project_name : t -> (string, [> `Msg of string ]) result
(** Returns the name of the project, as set in the dune-project. *)

val lockfile :
  ?local_packages:OpamPackage.Name.t list ->
  t ->
  (Fpath.t, [> `Msg of string ]) result
(** Returns the path to the opam-monorepo lockfile for the given repo. If the
    repo contains a single package, then it's the ["<package_name>.opam.locked"]
    file at the root of the repo. If it contains multiple packages, then it's
    the ["<project_name>.opam.locked"] file at the root of the repo. One can
    provide [local_packages] if they were already computed are if only a subset
    of the local packages must be taken into account. *)

val local_lockfiles : t -> (Fpath.t list, Rresult.R.msg) result
(** Returns all the lockfiles located at the root of the project i.e. all
    .opam.locked files. *)
