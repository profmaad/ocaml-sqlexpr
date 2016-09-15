open Ast_helper
open Asttypes
open Parsetree

module AC = Ast_convenience

let new_id =
  let n = ref 0 in
  fun () ->
    incr n;
    Printf.sprintf "__ppx_sql_%d" !n

let gen_stmt ~cacheable sql inp =
  let mkapply fn args = AC.app (AC.evar fn) args in

  let k = new_id () in
  let st = new_id () in
  let id =
    let signature =
      Printf.sprintf "%d-%f-%d-%S"
        Unix.(getpid ()) (Unix.gettimeofday ()) (Random.int 0x3FFFFFF) sql
    in Digest.to_hex (Digest.string signature) in
  let stmt_id =
    if cacheable
    then [%expr Some [%e AC.str id ]]
    else [%expr None] in
  let exp = List.fold_right (fun elem dir ->
    let typ = Sqlexpr_parser.in_type2str elem in
    [%expr [%e mkapply typ [dir]]])
    inp
    [%expr [%e AC.evar k]] in
    let dir = [%expr fun [%p AC.pvar k] -> fun [%p AC.pvar st] ->
      let open Sqlexpr.Directives in [%e exp] [%e AC.evar st]
    ] in
  [%expr {
    Sqlexpr.sql_statement = [%e AC.str sql];
    stmt_id = [%e stmt_id];
    directive = [%e dir];
  }]

let gen_expr ~cacheable sql inp outp =
  let stmt = gen_stmt ~cacheable sql inp in
  let id = new_id () in
  let conv s = Longident.(Ldot (Ldot (Lident "Sqlexpr", "Conversion"), s)) in
  let conv_exprs = List.mapi (fun i elem ->
    let txt = conv (Sqlexpr_parser.out_type2str elem) in
    let fn = Exp.ident {txt; loc=(!default_loc)} in
    let args = [%expr Array.get [%e AC.evar id] [%e AC.int i]] in
    AC.app fn [args]) outp in
  let tuple_func =
    let e = match conv_exprs with
        [] -> assert false
      | [x] -> x
      | hd::tl -> Exp.tuple conv_exprs in
    [%expr fun [%p AC.pvar id] -> [%e e]] in
  [%expr {
    Sqlexpr.statement = [%e stmt];
    get_data = ([%e AC.int (List.length outp)], [%e tuple_func]);
  }]

let stmts = ref []
let init_stmts = ref []

let gen_sql ?(init=false) ?(cacheable=false) str =
  let (sql, inp, outp) = Sqlexpr_parser.parse str in

  (* accumulate statements *)
  if init
  then init_stmts := sql :: !init_stmts
  else stmts := sql :: !stmts;

  if [] = outp
  then gen_stmt ~cacheable sql inp
  else gen_expr ~cacheable sql inp outp

let sqlcheck_sqlite () =
#if OCAML_VERSION >= (4, 3, 0)
  let mkstr s = Exp.constant (Pconst_string (s, None)) in
#else
  let mkstr s = Exp.constant (Const_string (s, None)) in
#endif
  let statement_check = [%expr
    try ignore(Sqlite3.prepare db stmt)
    with Sqlite3.Error s ->
      ret := false;
      Format.fprintf fmt "Error in statement %S: %s\n" stmt s
  ] in
  let stmt_expr_f acc elem = [%expr [%e mkstr elem] :: [%e acc]] in
  let stmt_exprs = List.fold_left stmt_expr_f [%expr []] !stmts in
  let init_exprs = List.fold_left stmt_expr_f [%expr []] !init_stmts in
  let check_db_expr = [%expr fun db fmt ->
    let ret = ref true in
    List.iter (fun stmt -> [%e statement_check]) [%e stmt_exprs];
    !ret
  ] in
  let init_db_expr = [%expr fun db fmt ->
    let ret = ref true in
    List.iter (fun stmt -> match Sqlite3.exec db stmt with
      | Sqlite3.Rc.OK -> ()
      | rc -> begin
        ret := false;
        Format.fprintf fmt "Error in init. SQL statement (%s)@ %S@\n"
          (Sqlite3.errmsg db) stmt
      end) [%e init_exprs];
      !ret
  ] in
  let in_mem_check_expr = [%expr fun fmt ->
    let db = Sqlite3.db_open ":memory:" in
    init_db db fmt && check_db db fmt
  ] in
  [%expr
    let init_db = [%e init_db_expr] in
    let check_db = [%e check_db_expr] in
    let in_mem_check = [%e in_mem_check_expr] in
    (init_db, check_db, in_mem_check)
  ]

let call fn loc = function
  | PStr [ {pstr_desc = Pstr_eval (
#if OCAML_VERSION >= (4, 3, 0)
    { pexp_desc = Pexp_constant(Pconst_string(sym, _))}, _)} ] ->
#else
    { pexp_desc = Pexp_constant(Const_string(sym, _))}, _)} ] ->
#endif
      with_default_loc loc (fun () -> fn sym)
  | _ -> raise (Location.Error(Location.error ~loc (
    "sqlexpr extension accepts a string")))

let call_sqlcheck loc = function
  | PStr [ {pstr_desc = Pstr_eval ({ pexp_desc =
#if OCAML_VERSION >= (4, 3, 0)
    Pexp_constant(Pconst_string("sqlite", None))}, _)}] ->
#else
    Pexp_constant(Const_string("sqlite", None))}, _)}] ->
#endif
      with_default_loc loc sqlcheck_sqlite
  | _ -> raise (Location.Error(Location.error ~loc (
    "sqlcheck extension accepts \"sqlite\"")))

open Ppx_core.Std

let sql =
  Extension.V2.declare
    "sql"
    Extension.Context.expression
    Ast_pattern.(pstr ((pstr_eval (pexp_constant (pconst_string __ __)) __) ^:: nil))
    (fun ~loc ~path:_ sym _ _ ->
      Ast_helper.with_default_loc loc (fun () -> gen_sql sym)
    )
;;

let sqlc =
  Extension.V2.declare
    "sqlc"
    Extension.Context.expression
    Ast_pattern.(pstr ((pstr_eval (pexp_constant (pconst_string __ __)) __) ^:: nil))
    (fun ~loc ~path:_ sym _ _ ->
      Ast_helper.with_default_loc loc (fun () -> gen_sql ~cacheable:true sym)
    )
;;

let sqlinit =
  Extension.V2.declare
    "sqlinit"
    Extension.Context.expression
    Ast_pattern.(pstr ((pstr_eval (pexp_constant (pconst_string __ __)) __) ^:: nil))
    (fun ~loc ~path:_ sym _ _ ->
      Ast_helper.with_default_loc loc (fun () -> gen_sql ~init:true sym)
    )
;;

let sqlcheck =
  Extension.V2.declare
    "sqlcheck"
    Extension.Context.expression
    Ast_pattern.(pstr ((pstr_eval (pexp_constant (pconst_string __ __)) __) ^:: nil))
    (fun ~loc ~path:_ sym _ _ ->
      match sym with
      | "sqlite" ->
         Ast_helper.with_default_loc loc sqlcheck_sqlite
      | _ ->
         raise (Location.Error (Location.error ~loc "sqlcheck extension accepts \"sqlite\""))
    )
;;

let () =
  Random.self_init ();
  Ppx_driver.register_transformation
    "sqlexpr"
    ~extensions:[sql; sqlc; sqlinit; sqlcheck]
;;

(* vim: set ft=ocaml: *)
