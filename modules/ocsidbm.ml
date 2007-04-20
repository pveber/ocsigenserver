(* Ocsigen
 * http://www.ocsigen.org
 * Module ocsidbm.ml
 * Copyright (C) 2007 Vincent Balat
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation, with linking exception; 
 * either version 2.1 of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.
 *)


(** Module Ocsidbm: persistent data server for Ocsigen *)
   
open Dbm
open Ocsidbmtypes
open Lwt

let directory = Sys.argv.(1)

let _ =  
  if (Array.length Sys.argv) > 2
  then 
    let spid = (string_of_int (Unix.getpid ()))^"\n" in
    let len = String.length spid in
    let f =
      Unix.openfile
        Sys.argv.(2)
        [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_APPEND] 0o640 in
    ignore (Unix.write f spid 0 len);
    Unix.close f


exception Ocsidbm_error

let socketname = "socket"
let suffix = ".otbl"


(*****************************************************************************)
(** Internal functions: storage in files using DBM *)

module Tableoftables = Map.Make(struct 
  type t = string
  let compare = compare
end)

let tableoftables = ref Tableoftables.empty
    
let list_tables () =
  let d = Unix.opendir directory in
  let rec aux () =
    try
      let n = Unix.readdir d in
      if Filename.check_suffix n suffix
      then (Filename.chop_extension n)::(aux ())
      else aux ()
    with End_of_file -> Unix.closedir d; []
  in aux ()

(* try to create the directory if it does not exist *)
let _ =
  try
    Unix.access directory [Unix.R_OK; Unix.W_OK; Unix.X_OK; Unix.F_OK]
  with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> Unix.mkdir directory 0o700

let open_db name =
  let t = opendbm (directory^"/"^name^suffix) [Dbm_rdwr; Dbm_create] 0o644 in
  tableoftables := Tableoftables.add name t !tableoftables;
  t

(* open all files and register them in the table of tables *)
let _ = List.iter (fun a -> ignore (open_db a)) (list_tables ())

let find_create_table name =
  try
    Tableoftables.find name !tableoftables
  with Not_found -> open_db name

let db_get store name =
  find (Tableoftables.find store !tableoftables) name
    (* raises Not_found if the table does not exist *)

let db_remove store name =
  try
    remove (Tableoftables.find store !tableoftables) name
  with _ -> ()

let db_replace store name value = 
  replace (find_create_table store) name value

let db_firstkey t = Dbm.firstkey (Tableoftables.find t !tableoftables)

let db_nextkey t = Dbm.nextkey (Tableoftables.find t !tableoftables)

let db_length t = 
  let table = Tableoftables.find t !tableoftables in
  let rec aux f n = 
    catch
      (fun () ->
        ignore (f table);
        Lwt_unix.yield () >>=
        (fun () -> aux Dbm.nextkey (n+1)))
      (function
        | Not_found -> return n
        | e -> fail e)
  in
  aux Dbm.firstkey 0 
(* Because of Dbm implementation, the result may be less than the expected
   result in some case *)

(*****************************************************************************)
(* signals *)
let close_all _ =
  Unix.unlink (directory^"/"^socketname);
  Tableoftables.iter (fun k t -> Dbm.close t) !tableoftables;
  exit 0

open Sys
let sigs = [sigabrt;sigalrm;sigfpe;sighup;sigill;sigint;
            sigpipe;sigquit;sigsegv;sigterm;sigusr1;sigusr2;
            sigchld;sigcont;sigtstp;sigttin;sigttou;sigvtalrm;sigprof]

let _ = 
  List.iter (fun s -> 
    Sys.set_signal s (Signal_handle close_all)) sigs

(*****************************************************************************)
(** Communication functions: *)

let send outch v =
  Lwt_unix.output_value outch v >>= 
  (fun () -> Lwt_unix.flush outch)

let execute outch = function
  | Get (t, k) -> 
      (try 
        send outch (Value (db_get t k))
      with _ -> send outch Dbm_not_found)
  | Remove (t, k) -> db_remove t k; send outch Ok
  | Replace (t, k, v) -> db_replace t k v; send outch Ok
  | Firstkey t -> 
      (try send outch (Key (db_firstkey t))
      with _ -> send outch End)
  | Nextkey t -> 
      (try send outch (Key (db_nextkey t))
      with _ -> send outch End)
  | Length t -> 
      catch
        (fun () ->
          db_length t >>=
          (fun i -> send outch (Value (Marshal.to_string i []))))
        (fun _ -> send outch Dbm_not_found)

let rec listen_client inch outch =
  Lwt_unix.input_value inch >>=
  (fun v -> execute outch v) >>=
  (fun () -> listen_client inch outch)

let rec loop socket =
  Lwt_unix.accept socket >>=
  (fun (indescr, _) ->
    ignore (
    let inch = Lwt_unix.in_channel_of_descr indescr in
    let outch = Lwt_unix.out_channel_of_descr indescr in
    listen_client inch outch);
    loop socket)

let _ = Lwt_unix.run 
    (Lwt_unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 >>=
     (fun socket ->
       (try
         Unix.bind socket (Unix.ADDR_UNIX (directory^"/"^socketname))
       with _ -> prerr_endline ("Ocsidbm error: please make sure that no other ocsidbm process is running on the same directory. If not, remove the file "^(directory^"/"^socketname)); exit 1);
       Unix.listen socket 20;
       loop (Lwt_unix.Plain socket)))

(*****************************************************************************)
(** Garbage collection of expired data *)
(* Experimental

exception Exn1
let dbm_fold f t beg =
  let rec aux nextkey beg =
    try
      let k = try nextkey t with Not_found -> raise Exn1 in
      let v = try Dbm.find k t with Not_found -> raise Exn1 in
      aux Dbm.nextkey (f k v beg)
    with Exn1 -> beg
  in
  aux Dbm.firstkey beg

let _ =
  match sessiongcfrequency with
    None -> () (* No garbage collection *)
  | Some t ->
      let rec f () = 
        Lwt_unix.sleep t >>= 
        (fun () ->
          let now = Unix.time () in
          print_endline "GC of persistent data";
          Tableoftables.fold
            (fun name t thr ->
              thr >>=
              (fun () ->
                dbm_fold
                  (fun k v thr ->
                    thr >>=
                    (fun () ->
                      (match fst (Marshal.from_string v 0) with
                      | Some exp when exp < now ->
                          try 
                            Dbm.remove t k
                          with _ -> ());
                      Lwt_unix.yield ()
                    )
                  )
                  t
                  (return ()))
            )
            !tableoftables
            (return ())
        ) >>=
        f
      in ignore (f ())

*)

