(* Copyright (c) 2018 Anil Madhavapeddy <anil@recoil.org>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *
 *)

open Bos
open Rresult
open Astring

let rec iter fn l =
  match l with hd :: tl -> fn hd >>= fun () -> iter fn tl | [] -> Ok ()

let err_log = OS.Cmd.err_file ~append:true Config.duniverse_log

let run_and_log_s ?(ignore_error = false) cmd =
  OS.File.tmp "duniverse-run-%s.stderr" >>= fun tmp_file ->
  let err = OS.Cmd.err_file tmp_file in
  let res = OS.Cmd.(run_out ~err cmd |> out_string) in
  match ignore_error with
  | true -> (
      match res with
      | Ok (stdout, _) -> Ok stdout
      | Error (`Msg _) -> OS.File.read tmp_file >>= fun stderr -> Ok stderr)
  | false -> (
      match res with
      | Ok (stdout, (_, `Exited 0)) -> Ok stdout
      | Ok (stdout, _) ->
          OS.File.read tmp_file >>= fun stderr ->
          Logs.err (fun l ->
              l "%a failed. Output was:@.%a%a"
                Fmt.(styled `Cyan Cmd.pp)
                cmd
                Fmt.(styled `Red text)
                stderr Fmt.text (String.trim stdout));
          Error (`Msg "Command execution failed")
      | Error (`Msg m) -> Error (`Msg m))

let run_and_log ?ignore_error cmd =
  run_and_log_s ?ignore_error cmd >>= fun _ -> Ok ()

let run_and_log_l ?ignore_error cmd =
  run_and_log_s ?ignore_error cmd >>= fun out ->
  R.ok (String.cuts ~sep:"\n" out |> List.map String.trim)

let map fn l =
  List.map fn l
  |> List.fold_left
       (fun acc b ->
         match (acc, b) with
         | Ok acc, Ok v -> Ok (v :: acc)
         | Ok _acc, Error v -> Error v
         | (Error _ as e), _ -> e)
       (Ok [])
  |> function
  | Ok v -> Ok (List.rev v)
  | e -> e

let opam_version () =
  match run_and_log_s ~ignore_error:false Cmd.(v "opam" % "--version") with
  | Ok v -> Ok v
  | Error (`Msg _) -> Error (`Msg "opam not installed on system")

let ocaml_version ?ocamlc () =
  let oc =
    match ocamlc with None -> Cmd.v "ocamlc" | Some x -> Cmd.(v @@ p x)
  in
  match run_and_log_s ~ignore_error:false Cmd.(oc % "-version") with
  | Ok s -> (
      match Ocaml_version.of_string s with
      | Ok v -> Ok v
      | Error (`Msg _) ->
          Error (`Msg "unable to parse OCaml string from ocamlc"))
  | Error (`Msg _) -> Error (`Msg "unable to find an installed ocamlc")

let install_ocaml_to ~prefix ~src () =
  OS.Dir.with_current src
    (fun () ->
      run_and_log Cmd.(v "./configure" % "--prefix" % p prefix) >>= fun () ->
      run_and_log Cmd.(v "make" % "-j" % "world.opt") >>= fun () ->
      run_and_log Cmd.(v "make" % "install"))
    ()
  >>= fun x -> x

let install_dune_to ~prefix ~src () =
  OS.Dir.with_current src
    (fun () ->
      OS.File.write Fpath.(v "dune-workspace") "(lang dune 1.0)" >>= fun () ->
      run_and_log Cmd.(v "ocaml" % "configure.ml" % "--libdir" % p prefix)
      >>= fun () ->
      run_and_log Cmd.(v "ocaml" % "bootstrap.ml") >>= fun () ->
      run_and_log
        Cmd.(
          v "./dune.exe"
          % "build"
          % "-p"
          % "dune"
          % "--profile"
          % "dune-bootstrap")
      >>= fun () ->
      run_and_log
        Cmd.(
          v "./dune.exe"
          % "install"
          % "--root"
          % p src
          % "--prefix"
          % p prefix
          % "dune"))
    ()
  >>= fun x -> x

let run_git ?(ignore_error = false) ~repo args =
  run_and_log ~ignore_error Cmd.(v "git" % "-C" % p repo %% args)

let dune_version () =
  match run_and_log_s ~ignore_error:false Cmd.(v "dune" % "--version") with
  | Ok v -> Ok v
  | Error _ -> Error (`Msg "unable to find an installed dune")

let dune_build ~root ?profile targets =
  let parg =
    match profile with
    | None -> Cmd.empty
    | Some "release" ->
        Cmd.(v "--profile=release" % "--ignore-promoted-rules" % "--no-config")
    | Some x -> Cmd.(v ("--profile=" ^ x))
  in
  run_and_log
    Cmd.(v "dune" % "build" % "--root" % p root %% parg %% of_list targets)

let dune_install ~root ~prefix ~sections targets =
  let sections = String.concat ~sep:"," sections in
  run_and_log
    Cmd.(
      v "dune"
      % "install"
      % "--root"
      % p root
      % "--prefix"
      % p prefix
      % "--sections"
      % sections
      %% of_list targets)

let is_git_repo_clean ~repo () =
  let cmd = Cmd.(v "git" % "-C" % p repo % "diff" % "--quiet") in
  match OS.Cmd.(run_out ~err:err_log cmd |> to_string) with
  | Ok _ -> Ok true
  | Error _ -> Ok false

let git_shallow_clone ~output_dir ~remote ~ref () =
  let cmd =
    Cmd.(
      v "git"
      % "clone"
      % "--recurse-submodules"
      % "--depth=1"
      % "-b"
      % ref
      % remote
      % p output_dir)
  in
  run_and_log cmd

let git_rev_parse ~repo ~ref () =
  let cmd = Cmd.(v "git" % "-C" % p repo % "rev-parse" % ref) in
  run_and_log_s cmd

let git_unshallow ~repo () = run_git ~repo Cmd.(v "fetch" % "--unshallow")

let git_default_branch ~remote () =
  let cmd = Cmd.(v "git" % "ls-remote" % "--symref" % remote % "HEAD") in
  run_and_log_l cmd >>= fun l ->
  match Git.Ls_remote.branch_of_symref ~symref:"HEAD" l with
  | Ok branch -> Ok branch
  | Error `Not_a_symref ->
      R.error_msg
        (Fmt.str
           "unable to parse `git ls-remote --symref %s HEAD` output: not a \
            symref."
           remote)
  | Error (`Msg _) as err -> err

let git_checkout ?(args = Cmd.empty) ~repo branch =
  run_git ~repo Cmd.(v "checkout" %% args % branch)

let git_checkout_or_branch ~repo branch =
  match git_checkout ~repo branch with
  | Ok () -> Ok ()
  | Error (`Msg _) -> git_checkout ~args:(Cmd.v "-b") ~repo branch

let git_add_and_commit ~repo ~message files =
  run_git ~ignore_error:true ~repo Cmd.(v "add" %% files) >>= fun () ->
  run_git ~ignore_error:true ~repo Cmd.(v "commit" % "-m" % message %% files)

let git_add_all_and_commit ~repo ~message () =
  run_git ~ignore_error:true ~repo Cmd.(v "commit" % "-a" % "-m" % message)

let git_merge ?(args = Cmd.empty) ~from ~repo () =
  run_git ~repo Cmd.(v "merge" %% args % from)

let git_resolve ~remote ~ref =
  run_and_log_l
    Cmd.(v "git" % "ls-remote" % remote %% Git.Ls_remote.ref_arg ref)
  >>= fun output ->
  match Git.Ls_remote.commit_pointed_by ~ref output with
  | Ok commit -> Ok { Git.Ref.t = ref; commit }
  | Error `No_such_ref ->
      Rresult.R.error_msgf "No %a ref for %s" Git.Ref.pp ref remote
  | Error `Multiple_such_refs ->
      Rresult.R.error_msgf
        "A branch and a tag share the name %a on the remote %s" Git.Ref.pp ref
        remote
  | Error (`Msg _) as err -> err

let git_branch ~repo ~ref ~branch_name =
  run_git ~ignore_error:false ~repo Cmd.(v "branch" % branch_name % ref)

let git_remote_add ~repo ~remote_url ~remote_name =
  run_git ~repo Cmd.(v "remote" % "add" % remote_name % remote_url)

let git_remote_remove ~repo ~remote_name =
  run_git ~repo Cmd.(v "remote" % "remove" % remote_name)

let git_fetch_to ~repo ~remote_name ~ref ~branch ?(force = false) () =
  run_git ~repo Cmd.(v "fetch" % remote_name % ref) >>= fun () ->
  run_git ~repo Cmd.(v "branch" %% on force (v "-f") % branch % "FETCH_HEAD")

let git_submodule_add ~repo ~remote_name ~ref ~branch ~target_path
    ?(force = false) () =
  run_git ~repo
    Cmd.(
      v "submodule"
      % "add"
      %% on force (v "-f")
      % "-b"
      % branch
      % "--name"
      % remote_name
      % "--"
      % ref
      % target_path)

let git_update_index ~repo ?(add = false) ~cacheinfo () =
  let mode, hash, path = cacheinfo in
  run_git ~repo
    Cmd.(
      v "update-index"
      %% on add (v "--add")
      % "--cacheinfo"
      % string_of_int mode
      % hash
      % p path)

let git_init_bare ~repo = run_and_log Cmd.(v "git" % "init" % "--bare" % p repo)

let git_clone ~branch ~remote ~output_dir =
  run_and_log
    Cmd.(
      v "git"
      % "clone"
      % "--recurse-submodules"
      % "--depth"
      % "1"
      % "--branch"
      % branch
      % remote
      % p output_dir)

let git_clone_or_pull ~branch ~remote ~output_dir =
  OS.Dir.exists output_dir >>= function
  | false -> git_clone ~branch ~remote ~output_dir
  | true ->
      run_and_log Cmd.(v "git" % "-C" % p output_dir % "fetch" % "origin")
      >>= fun () ->
      run_and_log
        Cmd.(
          v "git"
          % "-C"
          % p output_dir
          % "reset"
          % "--hard"
          % ("origin/" ^ branch))

let git_rename_branch_to ~repo ~branch =
  run_git ~repo Cmd.(v "branch" % "-m" % branch)

let git_remotes ~repo =
  let cmd = Cmd.(v "git" % "-C" % p repo % "remote") in
  run_and_log_l cmd

let git_branch_exists ~repo ~branch =
  match
    OS.Cmd.run_status ~quiet:true
      Cmd.(v "git" % "-C" % p repo % "rev-parse" % "--verify" % branch)
  with
  | Ok (`Exited 0) -> true
  | _ -> false
