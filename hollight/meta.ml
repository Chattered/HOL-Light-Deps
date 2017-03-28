needs "record.ml";;
needs "more-lib.ml";;

(* Automatically generate contiguous ids as needed by lookup. *)
module Identifying(Ord: Orderedtype) :
sig
  val lookup : Ord.t -> int
end =
  struct
    module Map = Batmap.Make(Ord)
    let counter = ref 0
    let map = ref Map.empty
    let lookup x =
      match Map.Exceptionless.find x !map with
      | None ->
         let id = !counter in
         incr counter;
         map := Map.add x id !map;
         id
      | Some id -> id
  end

(* Identify theorems in Ocaml syntax tree. *)
let rec get_constr t = get_constr_of_desc t.Types.desc
and get_constr_of_desc = function
  | Types.Tconstr (p,args,_) -> Some (p,args)
  | Types.Tlink t -> get_constr t
  | Types.Tsubst t -> get_constr t
  | _ -> None;;

let thm_type_path =
  !Toploop.toplevel_env
  |> Env.lookup_type (Longident.Lident "thm")
  |> fst;;

let rec get_ty_concl t = get_ty_concl_of_desc t.Types.desc
and get_ty_concl_of_desc = function
  | Types.Tconstr (p,_,_) -> Some p
  | Types.Tarrow (_, _, c, _) -> get_ty_concl c
  | Types.Tlink t -> get_ty_concl t
  | Types.Tsubst t -> get_ty_concl t
  | _ -> None;;

let is_thm d =
  d.Types.val_type
  |> get_constr
  |> Batoption.map_default (Path.same thm_type_path o fst) false;;

(* TODO: Exceptions here will be thrown in the other hook. These
   should only indicate bugs in the dependency tracking, but still,
   better error rep orting would be nice. *)
let exns = ref []
let env_diff_default s t =
  {
    Toploop.env_diff_default s t with
    Toploop.env_diff_parse_exc = (fun exn _ -> exns := exn :: !exns;
                                               Printf.printf "Exception!"; t);
    Toploop.env_diff_ident_exc = (fun exn _ -> exns := exn :: !exns;
                                               Printf.printf "Exception!"; s)
  };;

module Batstringmap =
  Batmap.Make_ext(struct type t = string let compare = compare end)
module Batintmap = Batmap.Make_ext(struct type t = int let compare = compare end)
module Identcmp =
  struct
    type t = Ident.t
    let compare id id' = compare (id.Ident.stamp) (id'.Ident.stamp)
  end
module Identmap = Batmap.Make_ext(Identcmp)
module Depmap =
  Batmap.Make_ext(struct type t = dep_info let compare = compare_dep_info end)

(* info_deps is a map from the dep_info of a theorem to that theorem's transitive
   dependencies. get_iterated_deps updates this map with the transitive dependencies
   for all depinfos that can be reached from thm. *)
let get_iterated_deps info_deps thm =
  let rec iterated_deps info_deps (thm,info) =
    match Depmap.Exceptionless.find info info_deps with
    | Some (deps,trans_deps) -> deps,trans_deps,info_deps
    | None ->
       let depinfos = thm_deps thm in
       let deps,trans_deps,info_deps =
         List.fold_left f (Batintmap.empty,Batintmap.empty,info_deps) depinfos in
       deps,trans_deps,Depmap.add info (deps,trans_deps) info_deps
  and f (deps,trans_deps,info_deps) (dep,info) =
    (* We're accumulating dependencies at the same level as (dep,info). *)
    let sub_deps,sub_trans_deps,info_deps = iterated_deps info_deps (dep,info) in
    (* sub_deps and sub_trans_deps are, respectively, the dependencies and transitive
       dependencies of dep. *)
    let union = Batintmap.merge (fun _ x y -> sum_option_fst x y) in
    (* Update the deps. If dep is tracked, we add it to the accumulating deps, and
    add its own dependencies to its transitive dependency map. If dep is a duplicate,
    we leave the transitive dependency map unchanged. If the duplicate isn't a
    transitive dependency, we add the dependencies of dep to the accumulating
    deps. If the duplicate is a unique tracked transitive dependency, we add the
    tracked theorem to the accumulating deps. *)
    let deps, trans_deps =
      match get_tracking info with
      | Tracked id -> Batintmap.add id dep deps, Batintmap.add id sub_deps trans_deps
      | Duplicate ids ->
         let deps =
           match filter (C Batintmap.mem sub_trans_deps) ids with
           | [] -> union deps sub_deps
           | [dup_id] -> Batintmap.add dup_id dep deps
           | _ -> failwith "Duplicate has two proofs in the dependency graph." in
         deps, trans_deps in
    deps,trans_deps,info_deps in
  List.fold_left f (Batintmap.empty,Batintmap.empty,info_deps) (thm_deps thm)

let rec tm_consts = function
  | Var _ -> []
  | Const (c,_) -> [c]
  | Comb (s,t) -> union (tm_consts s) (tm_consts t)
  | Abs (_,body) -> tm_consts body

let rec ty_consts = function
  | Tyvar _ -> []
  | Tyapp (c,args) ->
     Batlist.fold_left (fun tys ty -> union tys (ty_consts ty))
                       [c] args

let rec tm_ty_consts = function
  | Var (_,ty) -> ty_consts ty
  | Const (_,ty) -> ty_consts ty
  | Comb (s,t) -> union (tm_ty_consts s) (tm_ty_consts t)
  | Abs (Var (_,vty),body) ->
     union (ty_consts vty) (tm_ty_consts body)
  | Abs (_,_) -> failwith "BUG: Abstraction must be over a var."

(* get_deps will grab the immediate tracked dependencies of its argument.
   get_trivial_duplicates thm will return any tracked theorem that is a duplicate of
   thm and appears in thm's dependency graph.  *)
let get_deps, get_trivial_duplicates =
  let (dep_resolve : (thm Batintmap.t * thm Batintmap.t Batintmap.t) Depmap.t ref) =
    ref Depmap.empty in
  let get_deps thm =
    let deps, trans_deps, the_dep_resolve = get_iterated_deps !dep_resolve thm in
    dep_resolve := the_dep_resolve;
    match map_option (fun (id,_) -> Batintmap.Exceptionless.find id trans_deps)
                     (find_duplicates thm) with
    | [] -> deps |> Batintmap.to_list
    | [deps] -> deps |> Batintmap.to_list
    | _ -> failwith "Duplicate has two proofs in the dependency graph." in
  let get_trivial_duplicates thm =
    let deps, trans_deps, the_dep_resolve = get_iterated_deps !dep_resolve thm in
    dep_resolve := the_dep_resolve;
    filter (fun (id,thm) -> Batintmap.mem id trans_deps or Batintmap.mem id deps)
           (find_duplicates thm) in
  get_deps,get_trivial_duplicates

let new_consts thm =
  let const_subdeps =
    let deps = get_deps thm in
    Batlist.fold_left
      (fun consts (_,thm) -> union consts (const_deps thm)) [] deps in
  List.filter (not o C List.mem const_subdeps) (const_deps thm);;

let new_ty_consts thm =
  let ty_const_subdeps =
    let deps = get_deps thm in
    Batlist.fold_left (fun tys (_,thm) -> union tys (ty_const_deps thm))
                      []
                      deps in
  List.filter (not o C List.mem ty_const_subdeps) (ty_const_deps thm);;

module Meta =
  struct
    include Meta
    type origination = Toplevel | Conjunct of int
    type t =
      {
        tracking_id          : int;
        source               : unit srced;
        originates_as        : origination;
        tactic_proofs        : tac_tree list;
        tracked_dependencies : (int * thm) list;
        constants            : string list;
        type_constants       : string list;
        source_code_theorem_dependencies
          : ((int * thm) list * thm) srced list;
        source_code_tactic_dependencies
          : (unit srced * ((int * thm) list * thm) srced list) list;
      }
  end

(* Construct meta datastructure of a theorem, source information, origin and
identifier. *)
let meta_of_thm id thm src thm_origin dep_source_thms dep_source_tactics =
  let tac_proofs =
    let _,tac_proofs = get_meta thm in
    Tacset.to_list tac_proofs in
  {
    Meta.tracking_id = id;
    Meta.source = src;
    Meta.originates_as = thm_origin;
    Meta.tracked_dependencies = get_deps thm;
    Meta.tactic_proofs = tac_proofs;
    Meta.constants = const_deps thm;
    Meta.type_constants = ty_const_deps thm;
    Meta.source_code_theorem_dependencies = dep_source_thms;
    Meta.source_code_tactic_dependencies = dep_source_tactics
  };;

(* Turn iterators into folds. *)
let (mk_fold : (('a -> unit) -> 't -> unit)
               -> ('b -> 'a -> 'b) -> 'b -> 't -> 'b) =
  fun iter f b t ->
  let b' = ref b in
  iter (fun x -> b' := f !b' x) t;
  !b';;

(* Fold over the identifiers of an Ocaml AST structure and an expression. *)
let fold_ident_str, fold_ident_expr =
  let folds f =
    let module Ident_iterator =
      Typedtreeiter.Makeiterator(
          struct
            include Typedtreeiter.Defaultiteratorargument
            let enter_expression exp =
              match exp.Typedtree.exp_desc with
              | Typedtree.Texp_ident (Path.Pident ident,_,_) -> f ident
              | _ -> ()
          end) in
    Ident_iterator.iter_structure,
    Ident_iterator.iter_expression in
  (fun f b t -> mk_fold (fst o folds) f b t),
  (fun f b t -> mk_fold (snd o folds) f b t);;

(* Construct an ident map to data generated by of_src. *)
let mk_src_fns () =
  let (from_ident_map : 'a Meta.srced Identmap.t ref) = ref Identmap.empty in
  let src_counter = ref 0 in
  let register_ident ident loc x =
    let src_id = !src_counter in
    incr src_counter;
    let src = { Meta.source_id = src_id;
                Meta.source_ident = ident;
                Meta.location = loc;
                Meta.src_obj = ()
              } in
    let src_x = { src with Meta.src_obj = x } in
    from_ident_map := Identmap.add ident src_x !from_ident_map;
    src in
  let from_ident ident =
    Identmap.Exceptionless.find ident !from_ident_map in
  let all_srcs () = Identmap.values !from_ident_map |> Batenum.to_list |> rev in
  register_ident, from_ident, all_srcs;;

(* Registration of thm identifiers. *)
let register_thm_ident, find_thm_src, get_thm_srcs =
  let reg, find_from_ident, get_thm_srcs = mk_src_fns () in
  (fun ident vd -> reg ident (vd.Types.val_loc)),
  find_from_ident,
  get_thm_srcs;;

(* Add tracking info to a thm and return true, or else return existing tracking info
if duplicate and false. *)
let with_tracking_nodup thm =
  match Batoption.map get_tracking (get_dep_info thm) with
  | Some (Tracked id) -> id,thm,true
  | _ ->
     match get_trivial_duplicates thm with
     | [] -> let id,thm = with_tracking thm in id,thm,true
     | [idthm] -> let id,thm = idthm in id,thm,false
     | _ -> failwith "Theorem has two duplicates in its dependency graph."

let register_thm_meta, get_thm_metas =
  let (thms : (thm * Meta.t) list ref) = ref [] in
  (fun thm meta -> thms := (thm,meta) :: !thms),
  fun () -> rev !thms;;

let (meta_diff_hook : (unit,'a list) Toploop.env_diff_hooks) =
  let register_toplevel_thm ident vd dep_src_thms thm =
    let src = register_thm_ident ident vd ([],thm) in
    let id,thm,is_new = with_tracking_nodup thm in
    Toploop.setvalue (Ident.name ident) (Obj.repr thm);
    if is_new then
      let meta = meta_of_thm id thm src Meta.Toplevel dep_src_thms [] in
      register_thm_meta thm meta in
  let f ident_map ident =
    match find_thm_src ident with
    | Some meta -> Identmap.add ident meta ident_map
    | None -> ident_map in
  {
    (env_diff_default () []) with
    Toploop.env_diff_parse =
      (fun tree _ _ () -> fold_ident_str f Identmap.empty tree
                          |> Identmap.to_list
                          |> map snd);
    Toploop.env_diff_ident =
      (fun ident vd dep_src_thms ->
       if is_thm vd then
         begin
           let thm = Obj.obj (Toploop.getvalue (Ident.name ident)) in
           register_toplevel_thm ident vd dep_src_thms thm
         end;
       [])
  };;

let restore_hook = Toploop.set_env_diff_hook () meta_diff_hook;;
