(*needs "meta_tactic.ml"*)

let mk_tracked_thm =
  let split thm =
    let (asl,c) = dest_thm thm in
    let vs,thm' = splitlist SPEC_VAR thm in
    let conjs = map (itlist GEN vs) (CONJUNCTS thm') in
    let with_tracking_nodup thm =
      match get_trivial_duplicates thm with
      | [] -> let thm_id,thm = with_tracking thm in
              thm_id,thm,true
      | [thm_id,thm] -> thm_id,thm,false
      | _ -> failwith "Theorem has two duplicates in its dependency graph." in
    match conjs with
    | [_] -> let id,thm,is_new = with_tracking_nodup thm in
             thm,[id,thm,is_new]
    | _::_ ->
       let conjs = map (with_tracking_nodup) conjs in
       let snd (_,x,_) = x in
       let trivial = map (ACCEPT_TAC o SPECL vs o snd) conjs in
       TAC_PROOF ((map (fun asm -> ("",ASSUME asm)) asl, c),
                  REPEAT GEN_TAC THEN REPEAT CONJ_TAC THENL trivial),
       conjs in
  mk_tracked_thm_of_splitter split (K [])
