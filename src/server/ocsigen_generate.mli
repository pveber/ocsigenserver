exception Ocsigen_upload_forbidden

val find_post_params :
  Ocsigen_http_frame.t ->
  ((string * string) * (string * string) list) option ->
  string list ref ->
  (string option * Int64.t option ->
   ((string * string) list * (string * Ocsigen_request_info.file_info) list)
   Lwt.t)
  option

val of_cohttp_request :
  address:string ->
  port:int ->
  ?receiver:Ocsigen_http_com.connection ->
  string list ref ->
  Lwt_unix.sockaddr ->
  Cohttp.Connection.t ->
  Cohttp.Request.t ->
  Cohttp_lwt_body.t -> Ocsigen_request_info.request_info Lwt.t

val to_cohttp_request :
  Ocsigen_request_info.request_info ->
  (Cohttp.Header.t * Cohttp_lwt_body.t * Cohttp.Code.meth * Uri.t)