open Lwt

let log_file = "log.txt"
let listen_address = Unix.inet_addr_loopback
let port = 54321
let backlog = 10
let first_gap_from = 5.0
let first_gap_to = 20.0
let second_gap_from = 60.0
let second_gap_to = 120.0

(* let first_gap_from = 5.0
   let first_gap_to = 10.0
   let second_gap_from = 5.0
   let second_gap_to = 10.0 *)
let clients_oc = ref []
let count = ref 0

let format_time t =
  let tm = Unix.localtime t in
  Printf.sprintf "%d-%02d-%02d %02d:%02d:%02d" (tm.Unix.tm_year + 1900)
    (tm.Unix.tm_mon + 1) tm.Unix.tm_mday tm.Unix.tm_hour tm.Unix.tm_min
    tm.Unix.tm_sec

let client () =
  let sockaddr = Lwt_unix.ADDR_INET (listen_address, port) in
  let sock = Lwt_unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Lwt_unix.connect sock sockaddr >>= fun () ->
  let ic = Lwt_io.of_fd ~mode:Lwt_io.input sock in
  let oc = Lwt_io.of_fd ~mode:Lwt_io.output sock in
  Lwt_io.read_line ic >>= fun response ->
  Lwt_io.write_line oc (Printf.sprintf "Ok %d" @@ String.length response)
  >>= fun () ->
  Lwt_unix.sleep
    (Random.float (first_gap_to -. first_gap_from) +. first_gap_from)
  >>= fun () ->
  Lwt_io.write_line oc "I am alive!" >>= fun () ->
  Lwt_unix.sleep
    (Random.float (second_gap_to -. second_gap_from) +. second_gap_from)
  >>= fun () ->
  Lwt_unix.shutdown sock Unix.SHUTDOWN_ALL;
  return_unit

let handle_close id =
  Logs.info (fun m -> m "[id=%d] Connection closed" id);
  clients_oc := List.filter (fun (lc, _) -> lc != id) !clients_oc;
  ignore (Lwt_preemptive.detach client ())

let rec handle_connection ic oc id () =
  Lwt_io.read_line_opt ic >>= fun msg ->
  match msg with
  | Some msg ->
      Logs_lwt.info (fun m -> m "[id=%d] Received message: %s" id msg)
      >>= handle_connection ic oc id
  | None ->
      handle_close id;
      return_unit

let accept_connection conn =
  let fd, _ = conn in
  let ic = Lwt_io.of_fd ~mode:Lwt_io.Input fd in
  let oc = Lwt_io.of_fd ~mode:Lwt_io.Output fd in
  count := !count + 1;
  let local_count = !count in
  clients_oc := (local_count, oc) :: !clients_oc;
  on_failure (handle_connection ic oc local_count ()) (function
    (* in case of connection reset by peer *)
    (* this error triggers when client tries ti SHUTDOWN the connection when it have unreceived data *)
    | Unix.Unix_error (Unix.ECONNRESET, "write", "") -> handle_close local_count
    | e -> Logs.err (fun m -> m "%s" (Printexc.to_string e)));
  Logs_lwt.info (fun m -> m "[id=%d] New connection " local_count) >>= return

let create_socket () =
  let open Lwt_unix in
  let sock = socket PF_INET SOCK_STREAM 0 in
  (bind sock @@ ADDR_INET (listen_address, port) |> fun x -> ignore x);
  listen sock backlog;
  sock

let create_server sock =
  let rec serve () = Lwt_unix.accept sock >>= accept_connection >>= serve in
  serve

let broadcast_message msg =
  Logs_lwt.info (fun m -> m "Broadcasting message: %s" msg) >>= fun _ ->
  let rec send_to_all clients =
    match clients with
    | [] -> return_unit
    | (_, oc) :: rest -> Lwt_io.write_line oc msg >>= fun () -> send_to_all rest
  in
  send_to_all !clients_oc

(* for loggers combining *)
let combine r1 r2 =
  let report src level ~over k msgf =
    let v = r1.Logs.report src level ~over:(fun () -> ()) k msgf in
    r2.Logs.report src level ~over (fun () -> v) msgf
  in
  { Logs.report }

(* custom logger format *)
let reporter ppf =
  let report _ level ~over k msgf =
    let k _ =
      over ();
      k ()
    in
    let with_stamp h _ k ppf fmt =
      Format.kfprintf k ppf
        ("%a[%s] @[" ^^ fmt ^^ "@]@.")
        Logs.pp_header (level, h)
        (format_time @@ Unix.time ())
    in
    msgf @@ fun ?header ?tags fmt -> with_stamp header tags k ppf fmt
  in

  { Logs.report }

let () =
  let n = int_of_string Sys.argv.(1) in
  let file_reporter =
    let oc = open_out log_file in
    (* let oc = open_out_gen [Open_append; Open_append] 0o666 log_file in *) (* for appending *)
    let ppf = Format.formatter_of_out_channel oc in
    reporter ppf
  in
  let () =
    Logs.set_reporter @@ combine (reporter Format.std_formatter) file_reporter
  in
  let () = Logs.set_level (Some Logs.Info) in

  let sock = create_socket () in
  Logs.info (fun m -> m "Listening on port %d" port);
  let serve = create_server sock in
  for _ = 1 to n do
    ignore (Lwt_preemptive.detach client ())
  done;

  let rec read_console () =
    catch
      (fun () ->
        Lwt_io.read_line_opt Lwt_io.stdin >>= function
        | Some msg -> broadcast_message msg >>= read_console
        | None -> return_unit)
      (fun exn ->
        Lwt_io.printlf "Error: %s" (Printexc.to_string exn) >>= fun () ->
        read_console ())
  in
  async read_console;
  ignore @@ Lwt_main.run (serve ())
