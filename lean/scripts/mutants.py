#!/usr/bin/env python3
"""Mutation testing for the Lean model: each mutant patches Step.lean/Model.lean once; it is KILLED if the
project no longer builds its examples (`lake build Sommelier.Examples`) or `lake exe fuzz` reports a failure.
Usage: python3 lean/scripts/mutants.py [--check] [--jobs N] [name ...]
  --check  only verify that every patch applies exactly once (no builds)
Results: lean/scripts/mutants.json; a summary of survivors is printed.  Equivalent mutants are listed in EQUIVALENT below."""
import subprocess, shutil, os, re, sys, json
from concurrent.futures import ThreadPoolExecutor
from queue import Queue
HERE = os.path.dirname(os.path.abspath(__file__)); LEAN = os.path.dirname(HERE)
import tempfile
# a private workspace per run (concurrent runs never share one); set MUTANT_WORK to reuse a directory
_OWN_WORK = not os.environ.get('MUTANT_WORK')
WORK = os.environ.get('MUTANT_WORK') or tempfile.mkdtemp(prefix='sommelier-mutants-')
if _OWN_WORK:
    import atexit
    atexit.register(shutil.rmtree, WORK, True)   # a private workspace is removed on exit (a MUTANT_WORK directory is left to its owner)
M=[
# noteRead
('pile_replace_any_fresh',"lastFreshPile := if r.settled && r.level != .incomplete && !r.stripOpen then r.foldedSet else union }","lastFreshPile := r.foldedSet }"),
('pile_replace_unsettled',"if r.settled && r.level != .incomplete && !r.stripOpen then r.foldedSet","if r.level != .incomplete && !r.stripOpen then r.foldedSet"),
('pile_replace_incomplete',"if r.settled && r.level != .incomplete && !r.stripOpen then r.foldedSet","if r.settled && !r.stripOpen then r.foldedSet"),
('pile_replace_stripopen',"if r.settled && r.level != .incomplete && !r.stripOpen then r.foldedSet","if r.settled && r.level != .incomplete then r.foldedSet"),
('pile_never_replace',"if r.settled && r.level != .incomplete && !r.stripOpen then r.foldedSet else union","union"),
('stale_replaces_pile',".stale => { s with provenNotFull := false, noChevronReads := 0, lastFreshPile := union }",".stale => { s with provenNotFull := false, noChevronReads := 0, lastFreshPile := r.foldedSet }"),
('stale_no_union',".stale => { s with provenNotFull := false, noChevronReads := 0, lastFreshPile := union }",".stale => { s with provenNotFull := false, noChevronReads := 0 }"),
('stale_no_revoke',".stale => { s with provenNotFull := false, noChevronReads := 0,",".stale => { s with noChevronReads := 0,"),
('stale_no_count_reset',".stale => { s with provenNotFull := false, noChevronReads := 0,",".stale => { s with provenNotFull := false,"),
('fresh_no_revoke','{ s with provenNotFull := false, noChevronReads := 0,\n                 lastFreshPile','{ s with noChevronReads := 0,\n                 lastFreshPile'),
('fresh_no_count_reset','{ s with provenNotFull := false, noChevronReads := 0,\n                 lastFreshPile','{ s with provenNotFull := false,\n                 lastFreshPile'),
('incomplete_no_reset','else if r.level == .incomplete || !r.observed then { s with noChevronReads := 0 }','else if r.level == .incomplete || !r.observed then s'),
('incomplete_counts','else if r.level == .incomplete || !r.observed then { s with noChevronReads := 0 }','else if !r.observed then { s with noChevronReads := 0 }'),
('proof_at_2','(if r.kind == .pass then 3 else 2) <= s.noChevronReads','(if r.kind == .pass then 2 else 1) <= s.noChevronReads'),
('proof_at_4','(if r.kind == .pass then 3 else 2) <= s.noChevronReads','(if r.kind == .pass then 4 else 3) <= s.noChevronReads'),
('proof_keeps_hold','noChevronReads := 0, hold := false, lastFreshPile := [] }','noChevronReads := 0, lastFreshPile := [] }'),
('proof_keeps_pile','hold := false, lastFreshPile := [] }','hold := false }'),
('lastDrawn_not_set','let s := if r.kind == .pass && r.settled && r.level != .incomplete then { s with lastDrawn := r.drawn } else s','let s := s'),
# fold / movable
('fullBar_ignores_chevron',"!s.provenNotFull || r.chevron != .absent","!s.provenNotFull"),
('foldedAll_no_pile',"r.foldedSet ++ s.lastFreshPile","r.foldedSet"),
('foldedAll_no_read',"r.foldedSet ++ s.lastFreshPile","s.lastFreshPile"),
('movable_no_trust',"r.trusted.contains k && !(foldedAll s r).contains k","!(foldedAll s r).contains k"),
('movable_no_fold',"r.trusted.contains k && !(foldedAll s r).contains k","r.trusted.contains k"),
('needsStrip_no_near',"foldedAll s r ++ r.nearFold","foldedAll s r"),
('needsStrip_no_subject',"f.contains subject || f.contains rel.target","f.contains rel.target"),
('needsStrip_no_target',"f.contains subject || f.contains rel.target","f.contains subject"),
# planner
('plan_no_record_filter',"let hv := (movable s r).filter (fun k => s.record.contains k)\n","let hv := (movable s r)\n"),
('plan_no_givenUp',"if s.givenUp.contains w || s.skipped.contains w then none","if s.skipped.contains w then none"),
('plan_no_skipped',"if s.givenUp.contains w || s.skipped.contains w then none","if s.givenUp.contains w then none"),
# userMove
('um_pull_no_request','if (s.foldRequest == some k || s.owedKeys.contains k) && r.chevron == .fresh && r.foldedSet.contains k then','if r.chevron == .fresh && r.foldedSet.contains k then'),
('um_pull_no_fresh','if (s.foldRequest == some k || s.owedKeys.contains k) && r.chevron == .fresh && r.foldedSet.contains k then','if (s.foldRequest == some k || s.owedKeys.contains k) && r.foldedSet.contains k then'),
# the drop rule: a user's drop gets its move on the next good reading (licence = owed or requested, a fresh chevron, THIS read lists the key folded)
('um_licence_request_only','if (s.foldRequest == some k || s.owedKeys.contains k) && r.chevron == .fresh && r.foldedSet.contains k then','if s.foldRequest == some k && r.chevron == .fresh && r.foldedSet.contains k then'),
('um_licence_non_owed','if (s.foldRequest == some k || s.owedKeys.contains k) && r.chevron == .fresh && r.foldedSet.contains k then','if (s.foldRequest == some k || s.owedKeys.contains k || s.record.contains k) && r.chevron == .fresh && r.foldedSet.contains k then'),
('um_licence_memory_not_read','if (s.foldRequest == some k || s.owedKeys.contains k) && r.chevron == .fresh && r.foldedSet.contains k then','if (s.foldRequest == some k || s.owedKeys.contains k) && r.chevron == .fresh && (foldedAll s r).contains k then'),
('foldedAll_memory_not_superseded','if r.usable ∧ r.chevron = .fresh then r.foldedSet else r.foldedSet ++ s.lastFreshPile','r.foldedSet ++ s.lastFreshPile'),
('waiting_shown_on_good_read','def waitingKey (s : State) (r : Read) (k : Key) : Bool := owedNow s k && (!s.gate r || (userMove s r k).isSome)','def waitingKey (s : State) (r : Read) (k : Key) : Bool := owedNow s k'),
('waiting_only_when_move','def waitingKey (s : State) (r : Read) (k : Key) : Bool := owedNow s k && (!s.gate r || (userMove s r k).isSome)','def waitingKey (s : State) (r : Read) (k : Key) : Bool := owedNow s k && (userMove s r k).isSome'),
('waiting_only_when_not_good','def waitingKey (s : State) (r : Read) (k : Key) : Bool := owedNow s k && (!s.gate r || (userMove s r k).isSome)','def waitingKey (s : State) (r : Read) (k : Key) : Bool := owedNow s k && !s.gate r'),
('um_pull_target_unfiltered','((hv.filter (fun x => before.contains x)).getLast?)','(before.getLast?)'),
('um_anchors_include_owed',"a != k && s.record.contains a && !s.owedKeys.contains a","a != k && s.record.contains a"),
('um_anchors_any_drawn',"a != k && s.record.contains a && !s.owedKeys.contains a","a != k && !s.owedKeys.contains a"),
('um_seen_only_subset',"if seen.all (fun a => want.contains a) && want.all (fun a => seen.contains a) then none","if seen.all (fun a => want.contains a) then none"),
('um_want_only_subset',"if seen.all (fun a => want.contains a) && want.all (fun a => seen.contains a) then none","if want.all (fun a => seen.contains a) then none"),
('um_no_following','| none => anchors.head?.map (fun t => mk (.before t))','| none => none'),
('um_user_false',"needsStrip s r k rel, true⟩\n  let anchors :=","needsStrip s r k rel, false⟩\n  let anchors :="),
('um_strip_false',"needsStrip s r k rel, true⟩\n  let anchors :=","false, true⟩\n  let anchors :="),
('um_pull_user_false',"needsStrip s r k rel, true⟩\n  if (foldedAll s r).contains k then","needsStrip s r k rel, false⟩\n  if (foldedAll s r).contains k then"),
('userAllowed_true',"!(a.strip && (s.editSessionUsed || r.stripOpen))","true"),
('userAllowed_no_session',"!(a.strip && (s.editSessionUsed || r.stripOpen))","!(a.strip && r.stripOpen)"),
('userAllowed_no_open',"!(a.strip && (s.editSessionUsed || r.stripOpen))","!(a.strip && s.editSessionUsed)"),
# engineAllowed
('eng_no_restricted',"!s.restricted && !s.hold &&","!s.hold &&"),
('eng_no_hold',"!s.restricted && !s.hold &&","!s.restricted &&"),
('eng_no_stale',"r.chevron != .stale && !r.stripOpen","!r.stripOpen"),
('eng_no_open',"r.chevron != .stale && !r.stripOpen && ","r.chevron != .stale && "),
('eng_no_budget'," && s.moveCount < cap (fullBar s r)",""),
('eng_budget_notfull_only',"s.moveCount < cap (fullBar s r)","s.moveCount < capNotFull"),
('cap_full_4',"def capFull : Nat := 3","def capFull : Nat := 4"),
('cap_notfull_1000',"def capNotFull : Nat := 20","def capNotFull : Nat := 1000"),
# decideMove
('plan_on_poll',"if r.kind != .pass || !r.settled ||","if !r.settled ||"),
('plan_unsettled',"if r.kind != .pass || !r.settled ||","if r.kind != .pass ||"),
('plan_incomplete','|| r.level == .incomplete || s.inFlight.isSome || !s.gate r then none','|| s.inFlight.isSome || !s.gate r then none'),
('plan_inflight','|| r.level == .incomplete || s.inFlight.isSome || !s.gate r then none','|| r.level == .incomplete || !s.gate r then none'),
('owed_no_request_first',"  match (s.foldRequest.toList ++ s.owedKeys).findSome? (fun k => (userMove1","  match (s.owedKeys).findSome? (fun k => (userMove1"),
('engine_strip_unguarded','(if s.stripGrant then some { a with user := true } else none)','some a'),
('grant_not_user',"then some { a with user := true } else none)","then some a else none)"),
('grant_never','(if s.stripGrant then some { a with user := true } else none)','none'),
('decide_on_noted',"match decideMove s r with","match decideMove s' r with"),
# emit
('emit_no_erase',"owedKeys := s.owedKeys.erase a.subject,","owedKeys := s.owedKeys,"),
('emit_no_consume_req',"foldRequest := if s.foldRequest == some a.subject then none else s.foldRequest,","foldRequest := s.foldRequest,"),
('emit_no_session',"editSessionUsed := s.editSessionUsed || a.strip,","editSessionUsed := s.editSessionUsed,"),
('emit_grant_survives',"stripGrant := if granted then false else s.stripGrant }","stripGrant := s.stripGrant }"),
('emit_flightowed_always',"flightOwed := if s.owedKeys.contains a.subject then some s.gen else none,","flightOwed := some s.gen,"),
('emit_inflight_none',"{ s with inFlight := some a, flightOwed","{ s with flightOwed"),
# result
('res_count_unposted',"moveCount := s.moveCount + (if posted && !a.user then 1 else 0)","moveCount := s.moveCount + (if !a.user then 1 else 0)"),
('res_count_user',"moveCount := s.moveCount + (if posted && !a.user then 1 else 0)","moveCount := s.moveCount + (if posted then 1 else 0)"),
('res_never_count',"moveCount := s.moveCount + (if posted && !a.user then 1 else 0)","moveCount := s.moveCount"),
('res_no_hold',"{ s0 with hold := true, holdFolded := s0.lastFreshPile,","{ s0 with holdFolded := s0.lastFreshPile,"),
('res_holdFolded_empty',"{ s0 with hold := true, holdFolded := s0.lastFreshPile,","{ s0 with hold := true,"),
('res_no_giveup_full',"givenUp := if s0.givenUp.contains k then s0.givenUp else k :: s0.givenUp }","givenUp := s0.givenUp }"),
('res_hold_when_proven','if s0.provenNotFull then\n    markStrike','if false then\n    markStrike'),
('res_strikes_1',"if n >= 3 && !s0.givenUp","if n >= 1 && !s0.givenUp"),
('res_strikes_never',"if n >= 3 && !s0.givenUp","if n >= 99 && !s0.givenUp"),
('res_no_session_return',"editSessionUsed := if a.strip then false else s0.editSessionUsed,","editSessionUsed := s0.editSessionUsed,"),
('res_no_skip',"skipped := if was then s0.skipped else a.subject :: s0.skipped }","skipped := s0.skipped }"),
('rearm_any_outcome',"if o == .busy && s0.flightOwed == some s0.gen","if s0.flightOwed == some s0.gen"),
('rearm_any_gen',"if o == .busy && s0.flightOwed == some s0.gen && !was","if o == .busy && s0.flightOwed.isSome && !was"),
('rearm_granted',"if o == .busy && s0.flightOwed == some s0.gen && !was","if o == .busy && !was"),
('rearm_repeat',"s0.flightOwed == some s0.gen && !was &&","s0.flightOwed == some s0.gen &&"),
('rearm_not_in_record',"!was && s0.record.contains a.subject then","!was then"),
('rearm_no_request','foldRequest := if s0.flightReq && s1.foldRequest.isNone then some a.subject else s1.foldRequest }','foldRequest := s1.foldRequest }'),
('never_rearm',"if o == .busy && s0.flightOwed == some s0.gen","if false && s0.flightOwed == some s0.gen"),
# events
('step_emit_drop',"| some a => (emit s' a, [a])","| some a => (s', [a])"),
('edit_empty_no_filter_owed','record := rec, owedKeys := s.owedKeys.filter (fun k => rec.contains k),\n','record := rec,\n'),
('edit_empty_no_filter_req','\n            foldRequest := s.foldRequest.filter (fun k => rec.contains k),','\n            foldRequest := s.foldRequest,'),
('edit_overwrite_owed',"let owed := (s.owedKeys ++ rec.filter (fun k => moved.contains k)).eraseDups","let owed := (rec.filter (fun k => moved.contains k)).eraseDups"),
('edit_owed_no_record_filter',".eraseDups.filter (fun k => rec.contains k)\n",".eraseDups\n"),
('edit_pull_no_pile',"moved.contains k && s.lastFreshPile.contains k\n","moved.contains k\n"),
('edit_pull_no_drawn_before',"\n                                 && (rec.takeWhile (fun x => x != k)).any (fun x => s.lastDrawn.contains x))",")"),
('edit_release_any','hold := s.hold && !release,','hold := false,'),
('edit_never_release','hold := s.hold && !release,','hold := s.hold,'),
('edit_release_no_holdFolded',"moved.any (fun k => s.holdFolded.contains k || s.lastFreshPile.contains k)","moved.any (fun k => s.lastFreshPile.contains k)"),
('edit_release_no_pile',"moved.any (fun k => s.holdFolded.contains k || s.lastFreshPile.contains k)","moved.any (fun k => s.holdFolded.contains k)"),
('edit_no_budget_reset','record := rec, moveCount := 0, restricted := true,','record := rec, restricted := true,'),
('edit_not_restricted','moveCount := 0, restricted := true, editSessionUsed := false,\n            owedKeys := owed','moveCount := 0, editSessionUsed := false,\n            owedKeys := owed'),
('edit_no_session_reset','restricted := true, editSessionUsed := false,\n            owedKeys := owed','restricted := true,\n            owedKeys := owed'),
('edit_keep_skipped','\n            skipped := [],\n            strikes','\n            strikes'),
('edit_keep_strikes',"strikes := s.strikes.filter (fun k => !moved.contains k),\n",""),
('edit_keep_givenUp','strikes := s.strikes.filter (fun k => !moved.contains k),\n            givenUp := s.givenUp.filter (fun k => !moved.contains k) }, [])','strikes := s.strikes.filter (fun k => !moved.contains k) }, [])'),
('edit_clear_all_givenUp','givenUp := s.givenUp.filter (fun k => !moved.contains k) }, [])','givenUp := [] }, [])'),
('edit_req_keep_moved',"| none => s.foldRequest.filter (fun k => !moved.contains k && rec.contains k),","| none => s.foldRequest.filter (fun k => rec.contains k),"),
('edit_req_not_record',"| none => s.foldRequest.filter (fun k => !moved.contains k && rec.contains k),","| none => s.foldRequest.filter (fun k => !moved.contains k),"),
('retry_no_budget','moveCount := 0, hold := false, givenUp := [], strikes','hold := false, givenUp := [], strikes'),
('retry_keep_hold','moveCount := 0, hold := false, givenUp := [], strikes','moveCount := 0, givenUp := [], strikes'),
('retry_keep_givenUp','hold := false, givenUp := [], strikes := [], skipped := [],','hold := false, strikes := [], skipped := [],'),
('retry_keep_strikes',"givenUp := [], strikes := [], skipped := [],","givenUp := [], skipped := [],"),
('retry_keep_skipped',"givenUp := [], strikes := [], skipped := [],","givenUp := [], strikes := [],"),
('retry_keep_restricted',"restricted := false, owedKeys := [], foldRequest := none, stripGrant := true,","owedKeys := [], foldRequest := none, stripGrant := true,"),
('retry_keep_owed',"restricted := false, owedKeys := [], foldRequest := none, stripGrant := true,","restricted := false, foldRequest := none, stripGrant := true,"),
('retry_keep_req',"restricted := false, owedKeys := [], foldRequest := none, stripGrant := true,","restricted := false, owedKeys := [], stripGrant := true,"),
('retry_no_grant',"foldRequest := none, stripGrant := true, gen := s.gen + 1,","foldRequest := none, gen := s.gen + 1,"),
('retry_no_gen',"stripGrant := true, gen := s.gen + 1,\n","stripGrant := true,\n"),
('retry_no_session','gen := s.gen + 1,\n            editSessionUsed := false }, [])','gen := s.gen + 1 }, [])'),
('rk_pull_no_record',"let pull := s.record.contains k && s.lastFreshPile.contains k","let pull := s.lastFreshPile.contains k"),
('rk_pull_no_drawn'," && (s.record.takeWhile (fun x => x != k)).any (fun x => s.lastDrawn.contains x)\n","\n"),
('rk_no_budget','moveCount := 0, hold := false, givenUp := s.givenUp.erase k,','hold := false, givenUp := s.givenUp.erase k,'),
('rk_keep_hold','moveCount := 0, hold := false, givenUp := s.givenUp.erase k,','moveCount := 0, givenUp := s.givenUp.erase k,'),
('rk_keep_givenUp',"givenUp := s.givenUp.erase k,\n","\n"),
('rk_keep_strikes',"strikes := s.strikes.filter (fun x => x != k), skipped := [], restricted := true,","skipped := [], restricted := true,"),
('rk_keep_skipped',"skipped := [], restricted := true,\n","restricted := true,\n"),
('rk_not_restricted',"skipped := [], restricted := true,\n","skipped := [],\n"),
('rk_no_session','editSessionUsed := false,\n            owedKeys := (k ::','owedKeys := (k ::'),
('rk_no_owed_filter',"(k :: s.owedKeys).eraseDups.filter (fun x => s.record.contains x)","(k :: s.owedKeys).eraseDups"),
('rk_no_request',"foldRequest := if pull then some k else s.foldRequest,","foldRequest := s.foldRequest,"),
('mr_no_match',"| some a => if a.subject == k then (result s a o posted, []) else (s, [])","| some a => (result s a o posted, [])"),
('pb_grant_survives','foldRequest := none, stripGrant := false, gen := s.gen + 1 }, [])','foldRequest := none, gen := s.gen + 1 }, [])'),
('pb_owed_survives','restricted := false, owedKeys := [], foldRequest := none, stripGrant := false,','restricted := false, foldRequest := none, stripGrant := false,'),
('pb_req_survives','restricted := false, owedKeys := [], foldRequest := none, stripGrant := false,','restricted := false, owedKeys := [], stripGrant := false,'),
('pb_restricted_survives','restricted := false, owedKeys := [], foldRequest := none, stripGrant := false,','owedKeys := [], foldRequest := none, stripGrant := false,'),
('pb_no_gen','stripGrant := false, gen := s.gen + 1 }, [])','stripGrant := false }, [])'),
('pb_clears_hold','stripGrant := false, gen := s.gen + 1 }, [])','stripGrant := false, gen := s.gen + 1, hold := false }, [])'),
('pb_resets_budget','stripGrant := false, gen := s.gen + 1 }, [])','stripGrant := false, gen := s.gen + 1, moveCount := 0 }, [])'),
('lastDrawn_any_read','let s := if r.kind == .pass && r.settled && r.level != .incomplete then { s with lastDrawn := r.drawn } else s','let s := { s with lastDrawn := r.drawn }'),
('lastDrawn_incomplete_ok','r.kind == .pass && r.settled && r.level != .incomplete then { s with lastDrawn','r.kind == .pass && r.settled then { s with lastDrawn'),
('um_pull_noop_filter_dropped','(((hv.filter (fun x => before.contains x)).getLast?).map (fun p => mk (.after p))).filter\n        (fun a => applyMove r.drawn a != r.drawn)','((hv.filter (fun x => before.contains x)).getLast?).map (fun p => mk (.after p))'),
('prefix_subset_only','(l.take i).all (fun a => want.contains a) && want.all (fun a => (l.take i).contains a)','(l.take i).all (fun a => want.contains a)'),
('prefix_superset_only','(l.take i).all (fun a => want.contains a) && want.all (fun a => (l.take i).contains a)','want.all (fun a => (l.take i).contains a)'),
('um_gap_after_last','| none => anchors.head?.map (fun t => mk (.before t))','| none => anchors.getLast?.map (fun t => mk (.after t))'),
('emit_flightReq_always','flightReq := s.foldRequest == some a.subject,','flightReq := true,'),
('rearm_overwrites_request',"foldRequest := if s0.flightReq && s1.foldRequest.isNone then some a.subject else s1.foldRequest }","foldRequest := if s0.flightReq then some a.subject else s1.foldRequest }"),
('edit_keeps_flightReq','            flightReq := s.flightReq && !(s.inFlight.any (fun (a : Action) => moved.contains a.subject)),\n',''),
('retryKey_keeps_flightReq','flightReq := s.flightReq && !(s.inFlight.any (fun (a : Action) => a.subject == k)) }, [])','flightReq := s.flightReq }, [])'),
('empty_edit_keeps_flightReq','flightReq := s.flightReq && rec == s.record }, [])','flightReq := s.flightReq }, [])'),
('needsStrip_false',"  let f := foldedAll s r ++ r.nearFold\n  f.contains subject || f.contains rel.target","  let f := foldedAll s r ++ r.nearFold\n  false"),
('engine_grant_bypasses_budget',"!r.stripOpen && s.moveCount < cap (fullBar s r)","!r.stripOpen && (s.moveCount < cap (fullBar s r) || s.stripGrant)"),
('postedEngine_skips_case',"| .moveResult k _ true, some a => if a.subject == k && !a.user then 1 else 0","| .moveResult k _ true, some a => 0"),
('F1_label_user',"            else some a\n","            else some (if s.stripGrant then { a with user := true } else a)\n"),
('applyMove_noop_always',"if !l'.contains a.rel.target then l",'if true then l'),
('plan_noop_move',"else some ⟨w, .before h, needsStrip s r w (.before h), false⟩","else some ⟨w, .before w, needsStrip s r w (.before w), false⟩"),
# ejb.3 pass B: the verdict, `usable`, the gate, the status line and the rows (Truth.lean, Status.lean, Step.lean)
# -- each Honest conjunct's use in `verdict`
('verdict_A1_untrusted_open',"if r.usable then r.trustedDrawn else []","if r.usable then r.drawn else []"),
('verdict_A2_pile_ignored',"if r.usable ∧ r.chevron = .fresh then r.foldedSet else []","[]"),
('verdict_A2_any_chevron',"if r.usable ∧ r.chevron = .fresh then r.foldedSet else []","if r.usable then r.foldedSet else []"),
('verdict_A3_proof_not_needed',"(r.chevron = .fresh ∨ (r.chevron = .absent ∧ r.notFullProven = true))","(r.chevron = .fresh ∨ r.chevron = .absent)"),
('verdict_A6_everything_listed',"def Read.openOK (r : Read) (k : Key) : Bool := !decide r.usable || decide (r.listed k)","def Read.openOK (r : Read) (k : Key) : Bool := true"),
('verdict_A6_unread_not_listed',"k ∈ r.drawn ∨ k ∈ r.pile ∨ k ∈ r.folded ∨ k ∈ r.unread","k ∈ r.drawn ∨ k ∈ r.pile ∨ k ∈ r.folded"),
('verdict_unread_is_pinned_open',"if r.usable then r.trustedDrawn else []","if r.usable then r.trustedDrawn ++ r.unread else []"),
# -- `usable` missing each clause
('usable_no_stale',"(r.chevron = .fresh ∨ (r.chevron = .absent ∧ r.notFullProven = true))","(r.chevron ≠ .absent ∨ r.notFullProven = true)"),
('usable_no_unsettled',"r.kind = .pass ∧ r.settled = true ∧ r.level ≠ .incomplete ∧ r.observed = true ∧ r.stripOpen = false","r.kind = .pass ∧ r.level ≠ .incomplete ∧ r.observed = true ∧ r.stripOpen = false"),
('usable_no_proof',"(r.chevron = .fresh ∨ (r.chevron = .absent ∧ r.notFullProven = true))","(r.chevron = .fresh ∨ r.chevron = .absent)"),
('usable_no_strip',"r.observed = true ∧ r.stripOpen = false ∧","r.observed = true ∧"),
('usable_no_poll',"r.kind = .pass ∧ r.settled = true ∧ r.level ≠ .incomplete ∧ r.observed = true ∧ r.stripOpen = false","r.settled = true ∧ r.level ≠ .incomplete ∧ r.observed = true ∧ r.stripOpen = false"),
('usable_no_incomplete',"r.settled = true ∧ r.level ≠ .incomplete ∧ r.observed = true","r.settled = true ∧ r.observed = true"),
('usable_no_observed',"r.level ≠ .incomplete ∧ r.observed = true ∧ r.stripOpen = false","r.level ≠ .incomplete ∧ r.stripOpen = false"),
# -- the verdict itself
('verdict_ignores_pile',"def Read.pinBehind (r : Read) : List Key := if r.usable ∧ r.chevron = .fresh then r.foldedSet else []","def Read.pinBehind (r : Read) : List Key := if r.usable ∧ r.chevron = .fresh then r.folded else []"),
('verdict_ignores_unread',"  r.free k && r.openOK k &&\n    rec.any","  r.free k &&\n    rec.any"),
('verdict_U_padded',"    let U := rec.filter (party rec r)","    let U := rec.filter (fun k => r.free k && r.openOK k)"),
('verdict_U_empty',"    let U := rec.filter (party rec r)","    let U : List Key := []"),
('verdict_R_never_cannotTell',"    if R.length ≥ 2 then .cannotTell","    if R.length ≥ 99 then .cannotTell"),
('verdict_forcedBad_ignores_behind',"  rec.any (fun x => r.pinBehind.contains x && rec.any (fun y => r.pinOpen.contains y && rec.idxOf y < rec.idxOf x))","  false"),
('verdict_forcedBad_ignores_order',"  rec.filter (fun k => r.pinOpen.contains k) != r.pinOpen.filter (fun k => rec.contains k) ||\n","  false ||\n"),
('verdict_inconsistent_ok',"  if !decide r.usable || !r.consistent then .cannotTell","  if !decide r.usable then .cannotTell"),
('rowVerdict_tick_global',"    if rec.any (fun x => x != k && r.pinOpen.contains x &&\n          (decide (x ∈ rec.takeWhile (fun y => y != k)) != decide (r.pinOpen.idxOf x < r.pinOpen.idxOf k))) then .outOfPlace","    if forcedBad rec r then .outOfPlace"),
('rowVerdict_no_outOfTurn',"then .behindOutOfTurn","then .behindChevron"),
('rowVerdict_inconsistent_ok',"  if !r.consistent then .cannotTell\n  else if r.pinBehind.contains k then","  if false then .cannotTell\n  else if r.pinBehind.contains k then"),
('rowVerdict_unlisted_cannotTell',"  else if r.openOK k then .cannotTell\n  else .notOnBar","  else .cannotTell"),
('rowVerdict_free_notOnBar',"  else if r.openOK k then .cannotTell\n  else .notOnBar","  else .notOnBar"),
# -- the status line
('status_matches_on_except',"    | .matchesExcept U => .matchesExcept U","    | .matchesExcept _ => .matches"),
('status_matches_on_cannotTell',"    | .cannotTell => .checking","    | .cannotTell => .matches"),
('status_checking_on_differs',"    | .differs => .differs (if budgetSpent s r then .stopped else if s.hold then .barFull else .plain)","    | .differs => .checking"),
('status_moving_nothing_pending',"  if pending s r then .moving","  if pending s r || s.hold then .moving"),
('status_moving_never',"  if pending s r then .moving","  if false then .moving"),
('status_pending_ignores_flight',"def pending (s : State) (r : Read) : Bool := s.inFlight.isSome || (decideMove s r).isSome","def pending (s : State) (r : Read) : Bool := (decideMove s r).isSome"),
('status_pending_ignores_decide',"def pending (s : State) (r : Read) : Bool := s.inFlight.isSome || (decideMove s r).isSome","def pending (s : State) (r : Read) : Bool := s.inFlight.isSome"),
('status_stopped_without_budget',"if budgetSpent s r then .stopped else if s.hold then .barFull else .plain","if true then .stopped else if s.hold then .barFull else .plain"),
('status_barFull_without_hold',"else if s.hold then .barFull else .plain","else if true then .barFull else .plain"),
('status_stopped_ignores_budget',"if budgetSpent s r then .stopped else","if false then .stopped else"),
('budgetSpent_off_by_one',"def budgetSpent (s : State) (r : Read) : Bool := cap (fullBar s r) ≤ s.moveCount","def budgetSpent (s : State) (r : Read) : Bool := cap (fullBar s r) ≤ s.moveCount + 1"),
('row_moving_never',"  if movingKey s r k then .moving\n","  if false then .moving\n"),
('row_waiting_never',"  else if waitingKey s r k then .waiting\n","  else if false then .waiting\n"),
('row_waiting_always',"  else if waitingKey s r k then .waiting\n","  else if true then .waiting\n"),
('row_moving_inflight_only',"s.inFlight.any (fun a => a.subject == k) || (decideMove s r).any (fun a => a.subject == k)","s.inFlight.any (fun a => a.subject == k)"),
('row_moving_decide_only',"s.inFlight.any (fun a => a.subject == k) || (decideMove s r).any (fun a => a.subject == k)","(decideMove s r).any (fun a => a.subject == k)"),
('row_waiting_ignores_request',"def owedNow (s : State) (k : Key) : Bool := s.owedKeys.contains k || s.foldRequest == some k","def owedNow (s : State) (k : Key) : Bool := s.owedKeys.contains k"),
('row_notWherePut_as_tick',"  | .outOfPlace => .notWherePut\n","  | .outOfPlace => .tick\n"),
('row_behind_as_tick',"  | .behindChevron => .behind\n","  | .behindChevron => .tick\n"),
('status_view_ignored',"def shownVerdict (s : State) (r : Read) : Verdict := verdict s.record (s.view r)","def shownVerdict (s : State) (r : Read) : Verdict := verdict s.record r"),
# -- the gate and the pull-out
('decide_gate_removed',"|| s.inFlight.isSome || !s.gate r then none","|| s.inFlight.isSome then none"),
('gate_ignores_consistent',"decide (s.view r).usable && (s.view r).consistent","decide (s.view r).usable"),
('gate_ignores_usable',"decide (s.view r).usable && (s.view r).consistent","(s.view r).consistent"),
('view_uses_field',"def State.view (s : State) (r : Read) : Read := { r with notFullProven := s.provenNotFull }","def State.view (s : State) (r : Read) : Read := r"),
('um_pull_from_memory',"if (s.foldRequest == some k || s.owedKeys.contains k) && r.chevron == .fresh && r.foldedSet.contains k then","if (s.foldRequest == some k || s.owedKeys.contains k) && r.chevron == .fresh then"),
('trustedDrawn_untrusted',"def Read.trustedDrawn (r : Read) : List Key := r.drawn.filter (fun k => r.trusted.contains k)","def Read.trustedDrawn (r : Read) : List Key := r.drawn"),
# -- the proof of "not full"
('proof_counts_unsettled','        else if r.kind == .pass && !r.settled then s   -- an unsettled COMPLETE pass read is not evidence either way (Swift: it ends before noteChevronEvidence): no count, no reset\n',''),
('proof_unobserved_counts',"else if r.level == .incomplete || !r.observed then { s with noChevronReads := 0 }","else if r.level == .incomplete then { s with noChevronReads := 0 }"),
('proof_pass_flips_early',"(if r.kind == .pass then 3 else 2) <= s.noChevronReads","2 <= s.noChevronReads"),
('proof_poll_flips_late',"(if r.kind == .pass then 3 else 2) <= s.noChevronReads","3 <= s.noChevronReads"),
# ejb.10: the fallback for a misplaced owed key, the two phases, the note beside a row
('fb_none',"    | none => fallbackMove s r k\n","    | none => none\n"),
('fb_not_strict',"((argmin (worstCount s r k) (fallbackCands s r k)).map mk).filter (fun a => decide (worstCount s r k a.rel < invCount s r r.drawn))","((argmin (worstCount s r k) (fallbackCands s r k)).map mk)"),
('fb_nonstrict',"decide (worstCount s r k a.rel < invCount s r r.drawn))","decide (worstCount s r k a.rel ≤ invCount s r r.drawn))"),
('fb_non_owed',"if s.owedKeys.contains k && s.record.contains k && (movable s r).contains k && misplaced s r k then","if s.record.contains k && (movable s r).contains k && misplaced s r k then"),
('fb_not_misplaced',"if s.owedKeys.contains k && s.record.contains k && (movable s r).contains k && misplaced s r k then","if s.owedKeys.contains k && s.record.contains k && (movable s r).contains k then"),

('fb_not_in_record',"if s.owedKeys.contains k && s.record.contains k && (movable s r).contains k && misplaced s r k then","if s.owedKeys.contains k && (movable s r).contains k && misplaced s r k then"),
('fb_not_movable',"if s.owedKeys.contains k && s.record.contains k && (movable s r).contains k && misplaced s r k then","if s.owedKeys.contains k && s.record.contains k && misplaced s r k then"),
('whole_ignores_untrusted',"(movable s r).contains x || (r.chevron","r.drawn.contains x || (r.chevron"),
('whole_folded_any_chevron',"(movable s r).contains x || (r.chevron == .fresh && r.foldedSet.contains x))","(movable s r).contains x || (r.foldedSet.contains x))"),
('whole_ignores_unread',"r.folded.contains x || r.unread.contains x) ||\n    (movable s r).contains x","r.folded.contains x) ||\n    (movable s r).contains x"),
('whole_never',"def wholeBar (s : State) (r : Read) : Bool :=\n  s.record.all","def wholeBar (s : State) (r : Read) : Bool :=\n  true || s.record.all"),
('fb_argmax',"| some b => if f x < f b then some x else acc) none","| some b => if f b < f x then some x else acc) none"),
('fb_argmin_first',"| some b => if f x < f b then some x else acc) none","| some b => acc) none"),
('fb_cands_before_only',"flatMap (fun t => [Rel.before t, Rel.after t])","flatMap (fun t => [Rel.before t])"),
('fb_cands_unfiltered',"((movable s r).filter (fun t => t != k && s.record.contains t)).flatMap","((movable s r).filter (fun t => t != k)).flatMap"),
('fb_count_all_keys',"invs s.record (l.filter (fun x => (movable s r).contains x && s.record.contains x))","invs s.record (l.filter (fun x => s.record.contains x))"),
('fb_count_flipped',"decide (rec.idxOf y < rec.idxOf x)","decide (rec.idxOf x < rec.idxOf y)"),
('fb_tie_last',"(fallbackRel s r k).toList ++\n","[] ++\n"),
('fb_before_pred',"| some p => some (.after p)\n  | none => ((s.record.dropWhile","| some p => some (.before p)\n  | none => ((s.record.dropWhile"),
('fb_user_false',"def fallbackMove (s : State) (r : Read) (k : Key) : Option Action :=\n  let mk (rel : Rel) : Action := ⟨k, rel, needsStrip s r k rel, true⟩","def fallbackMove (s : State) (r : Read) (k : Key) : Option Action :=\n  let mk (rel : Rel) : Action := ⟨k, rel, needsStrip s r k rel, false⟩"),
('misplaced_ignores_record',"hv.any (fun x => x != k && s.record.contains x && (before.contains x != seen.contains x))","hv.any (fun x => x != k && (before.contains x != seen.contains x))"),
('misplaced_equal',"(before.contains x != seen.contains x))\n\n/-- Inversions","(before.contains x == seen.contains x))\n\n/-- Inversions"),
('misplaced_before_only',"(before.contains x != seen.contains x))\n\n/-- Inversions","(before.contains x && !seen.contains x))\n\n/-- Inversions"),
('phase_fallback_first',"  match (s.foldRequest.toList ++ s.owedKeys).findSome? (fun k => (userMove1 s r k).filter (userAllowed s r)) with\n  | some a => some a\n  | none => (s.foldRequest.toList ++ s.owedKeys).findSome? (fun k => (userMove2 s r k).filter (userAllowed s r))","  match (s.foldRequest.toList ++ s.owedKeys).findSome? (fun k => (userMove2 s r k).filter (userAllowed s r)) with\n  | some a => some a\n  | none => (s.foldRequest.toList ++ s.owedKeys).findSome? (fun k => (userMove1 s r k).filter (userAllowed s r))"),
('phase_single',"  | none => (s.foldRequest.toList ++ s.owedKeys).findSome? (fun k => (userMove2 s r k).filter (userAllowed s r))","  | none => none"),
('phase2_over_anchor',"if (userMove1 s r k).isNone && !(foldedAll s r).contains k && (movable s r).contains k then fallbackMove s r k else none","if !(foldedAll s r).contains k && (movable s r).contains k then fallbackMove s r k else none"),
('queue_head_only',"  | none => (s.foldRequest.toList ++ s.owedKeys).findSome? (fun k => (userMove2 s r k)","  | none => (s.foldRequest.toList ++ s.owedKeys).head?.bind (fun k => (userMove2 s r k)"),
('queue_reversed',"  | none => (s.foldRequest.toList ++ s.owedKeys).findSome? (fun k => (userMove2 s r k)","  | none => (s.foldRequest.toList ++ s.owedKeys.reverse).findSome? (fun k => (userMove2 s r k)"),
('note_never',"if rowLine s r k == .notWherePut && owedNow s k then","if false then"),
('note_without_owed',"if rowLine s r k == .notWherePut && owedNow s k then","if rowLine s r k == .notWherePut then"),
('note_on_any_owed',"if rowLine s r k == .notWherePut && owedNow s k then","if owedNow s k then"),
('note_on_tick',"if rowLine s r k == .notWherePut && owedNow s k then","if (rowLine s r k == .notWherePut || rowLine s r k == .tick) && owedNow s k then"),
('helps_ignores_others'," && (fallbackMove s r k).isNone && (userPick s r).isNone then"," && (fallbackMove s r k).isNone then"),
('helps_ignores_fallback',"&& misplaced s r k\n        && (fallbackMove s r k).isNone && (userPick s r).isNone then","&& misplaced s r k\n        && (userPick s r).isNone then"),
('helps_ignores_whole',"s.record.contains k && wholeBar s r && misplaced s r k\n        && (fallbackMove","s.record.contains k && misplaced s r k\n        && (fallbackMove"),
('cant_flipped',"s.record.contains k && !wholeBar s r && misplaced s r k","s.record.contains k && wholeBar s r && misplaced s r k"),
('cant_ignores_decide',"&& (decideMove s r).isNone then\n      some .cantJudge","then\n      some .cantJudge"),
('cant_not_misplaced',"s.record.contains k && !wholeBar s r && misplaced s r k","s.record.contains k && !wholeBar s r"),
('helps_not_misplaced',"s.record.contains k && wholeBar s r && misplaced s r k\n        && (fallbackMove","s.record.contains k && wholeBar s r\n        && (fallbackMove"),
('helps_always',"if (movable s r).contains k && s.owedKeys.contains k && s.record.contains k && wholeBar s r && misplaced s r k\n        && (fallbackMove s r k).isNone && (userPick s r).isNone then","if true then"),
('helps_not_movable',"if (movable s r).contains k && s.owedKeys.contains k && s.record.contains k && wholeBar s r","if s.owedKeys.contains k && s.record.contains k && wholeBar s r"),
# ejb.11: the whole-bar condition (and the free keys it is "none of"), the worst case of the free keys, the narrowed note
('own_whole_drawn_only',"    !(r.drawn.contains x || r.pile.contains x || r.folded.contains x || r.unread.contains x) ||","    !(r.drawn.contains x) ||"),
('own_whole_unlisted_fails',"    !(r.drawn.contains x || r.pile.contains x || r.folded.contains x || r.unread.contains x) ||","    false ||"),
('own_whole_unread_fresh',"(movable s r).contains x || (r.chevron == .fresh && r.foldedSet.contains x))","(movable s r).contains x || (r.chevron == .fresh && (r.foldedSet.contains x || r.unread.contains x)))"),
('own_cant_no_owed',"if (movable s r).contains k && s.owedKeys.contains k && s.record.contains k && !wholeBar s r","if (movable s r).contains k && s.record.contains k && !wholeBar s r"),
('own_cant_userpick',"&& (decideMove s r).isNone then\n      some .cantJudge","&& (userPick s r).isNone then\n      some .cantJudge"),
('cant_ignores_fallback',"&& (fallbackMove s r k).isNone && (decideMove s r).isNone then\n      some .cantJudge","&& (decideMove s r).isNone then\n      some .cantJudge"),
('free_ignores_unlisted',"  s.record.filter (fun x =>\n    (r.drawn.contains x || r.pile.contains x || r.folded.contains x || r.unread.contains x) &&","  s.record.filter (fun x =>\n    true &&"),
('free_ignores_unread',"r.folded.contains x || r.unread.contains x) &&\n    !(movable","r.folded.contains x) &&\n    !(movable"),
('free_ignores_movable',"!(movable s r).contains x && !(r.chevron == .fresh && r.foldedSet.contains x))","!(r.chevron == .fresh && r.foldedSet.contains x))"),
('free_ignores_fold',"!(movable s r).contains x && !(r.chevron == .fresh && r.foldedSet.contains x))","!(movable s r).contains x)"),
('free_fold_any_chevron',"!(movable s r).contains x && !(r.chevron == .fresh && r.foldedSet.contains x))","!(movable s r).contains x && !(r.foldedSet.contains x))"),
('fb_no_penalty',"Nat := afterCount s r k rel + penalty s r k rel","Nat := afterCount s r k rel"),
('fb_penalty_all_free',"((freeKeys s r).filter (fun y =>\n    if leftward r k rel then decide (s.record.idxOf y < s.record.idxOf k) else decide (s.record.idxOf k < s.record.idxOf y))).length","(freeKeys s r).length"),
('fb_penalty_dir_flipped',"if leftward r k rel then decide (s.record.idxOf y < s.record.idxOf k) else decide (s.record.idxOf k < s.record.idxOf y)","if leftward r k rel then decide (s.record.idxOf k < s.record.idxOf y) else decide (s.record.idxOf y < s.record.idxOf k)"),
('fb_penalty_same_side',"if leftward r k rel then decide (s.record.idxOf y < s.record.idxOf k) else decide (s.record.idxOf k < s.record.idxOf y)","decide (s.record.idxOf y < s.record.idxOf k)"),
('fb_leftward_flipped',"decide (r.drawn.idxOf rel.target < r.drawn.idxOf k)","decide (r.drawn.idxOf k < r.drawn.idxOf rel.target)"),
('fb_argmin_after_only',"argmin (worstCount s r k) (fallbackCands s r k)","argmin (afterCount s r k) (fallbackCands s r k)"),
('fb_fires_on_after_only',"decide (worstCount s r k a.rel < invCount s r r.drawn)","decide (afterCount s r k a.rel < invCount s r r.drawn)"),
# ejb.12: the fast versions (Fast.lean).  Each breaks a fast definition; the equality theorem `…F_eq` (or a lemma it rests on) must fail to elaborate.
('fast_cost_offbyone',"(g + l) :: costScan pk ys","(g + l + 1) :: costScan pk ys"),
('fast_cost_gt_flipped',"costScan pk ys (g + (if pk < y then 1 else 0))","costScan pk ys (g + (if y < pk then 1 else 0))"),
('fast_cost_lt_not_decreased',"(l - (if y < pk then 1 else 0))\n","l\n"),
('fast_relOff_after_zero',"| .after _ => 1","| .after _ => 0"),
('fast_relOff_before_one',"def relOff : Rel → Nat | .before _ => 0","def relOff : Rel → Nat | .before _ => 1"),
('fast_score_direction_swapped',"(if D.idxOf rel.target < kd then pl else pr)","(if D.idxOf rel.target < kd then pr else pl)"),
('fast_score_base_missing',"base + cs.getD (M.idxOf rel.target + relOff rel) 0 +","cs.getD (M.idxOf rel.target + relOff rel) 0 +"),
('fast_threshold_wrong',"pickF k (needsStrip s r k) (invN ((r.drawn.filter (kp hv s.record)).map s.record.idxOf))","pickF k (needsStrip s r k) (invN P)"),
('fast_nodup_guard_dropped',"    if r.drawn.Nodup then\n      let M := mkM","    if true then\n      let M := mkM"),
('fast_fallback_cond_dropped',"if s.owedKeys.contains k && s.record.contains k && hv.contains k && misplaced s r k then","if s.owedKeys.contains k && s.record.contains k && hv.contains k then"),
('fast_argmin_last',"| some (b, bv) => if v < bv then some (x, v) else acc) none","| some (b, bv) => if v ≤ bv then some (x, v) else acc) none"),
('fast_invN_nonstrict',"(xs.filter (fun y => decide (y < x))).length + invN xs","(xs.filter (fun y => decide (y ≤ x))).length + invN xs"),
('fast_gate_ignores_consistent',"decide (s.view r).usable && (s.view r).consistentF","decide (s.view r).usable"),
('fast_nodup_ignores_tail',"| x :: xs => !xs.contains x && nodupB xs","| x :: xs => nodupB xs"),
('fast_allNotIn_inverted',"def allNotIn (po pb : List Key) : Bool := po.all (fun k => !pb.contains k)","def allNotIn (po pb : List Key) : Bool := po.all (fun k => pb.contains k)"),
('fast_row_behind_swapped',"then .behindOutOfTurn\n    else .behindChevron\n  else if po.contains k then\n    if anyCrossed","then .behindChevron\n    else .behindOutOfTurn\n  else if po.contains k then\n    if anyCrossed"),
('fast_row_crossed_eq',"(decide (x ∈ bef) != decide (po.idxOf x < pk))","(decide (x ∈ bef) == decide (po.idxOf x < pk))"),
('fast_forcedBad_order',"decide (rec.idxOf y < ix))))\n\n/-- `r.free k","decide (rec.idxOf y > ix))))\n\n/-- `r.free k"),
('fast_party_side',"(pb.contains y && decide (ik < rec.idxOf y))","(pb.contains y && decide (rec.idxOf y < ik))"),
('fast_verdict_R_threshold',"let R := partyR rec po pb us r U\n    if R.length ≥ 2","let R := partyR rec po pb us r U\n    if R.length ≥ 3"),
('fast_step_no_emit',"| some a => (emit s' a, [a])\n  | e => step s e","| some a => (s', [a])\n  | e => step s e"),
('fast_decide_gate_dropped',"|| !s.gateF r then none","then none"),
('fast_userMove2_folded',"if (userMove1 s r k).isNone && !(foldedAll s r).contains k && (movable s r).contains k then fallbackMoveF s r k else none","if (userMove1 s r k).isNone && (movable s r).contains k then fallbackMoveF s r k else none"),
('fast_status_never_moving',"def statusLineF (s : State) (r : Read) : Status :=\n  if pendingF s r then .moving","def statusLineF (s : State) (r : Read) : Status :=\n  if false then .moving"),
('fast_row_never_moving',"def rowLineF (s : State) (r : Read) (k : Key) : RowLine :=\n  if movingKeyF s r k then .moving","def rowLineF (s : State) (r : Read) (k : Key) : RowLine :=\n  if false then .moving"),
('fast_free_movable_inverted',"&& !hv.contains x && !(fresh && fs.contains x))","&& hv.contains x && !(fresh && fs.contains x))"),
# ejb.17: a verified move the next read contradicts is a strike
('ver_no_strike',"(if verFailed s r k then markStrike { s with verified := none } k else { s with verified := none })","{ s with verified := none }"),
('ver_never_marked',"verified := if posted && !a.user && o == .verified then some a.subject else none,\n                     verRel := a.rel }","verified := none,\n                     verRel := a.rel }"),
('ver_mark_user_drags',"if posted && !a.user && o == .verified then","if posted && o == .verified then"),
('ver_judge_ungated',"if s.inFlight.isNone && s.gate r then\n        (if verFailed","if s.inFlight.isNone then\n        (if verFailed"),
('ver_confirm_keeps_mark',"else { s with verified := none })\n      else s","else s)\n      else s"),
('ver_misplaced_not_checked',"(movable s r).contains k && s.record.contains k && misplaced s r k","(movable s r).contains k && s.record.contains k"),
('ver_retry_keeps_mark',"({ s with\n            verified := none,\n            moveCount := 0, hold := false, givenUp := [], strikes","({ s with\n            moveCount := 0, hold := false, givenUp := [], strikes"),
('ver_edit_keeps_mark',"            verified := none,   -- ejb.26: ANY record change clears the mark (ejb.17 cleared only the moved keys')\n",""),
('ver_edit_empty_keeps_mark',"            verified := none,   -- ejb.26: ANY record change clears the mark (the read can no longer say whether the drag took)\n",""),
('ver_edit_clears_moved_only',"verified := none,   -- ejb.26: ANY record change clears the mark (ejb.17 cleared only the moved keys')","verified := s.verified.filter (fun k => !moved.contains k),"),
('ver_crossing_strikes',"stillMisplaced s r k && revertedFromAnchor s r k s.verRel","stillMisplaced s r k"),
('ver_anchor_side_swapped',"| .before t => two == [t, k]\n  | .after t => two == [k, t]","| .before t => two == [k, t]\n  | .after t => two == [t, k]"),
('ver_rel_not_recorded',"verRel := a.rel }","verRel := .before 0 }"),
('ver_rk_keeps_mark',"            verified := s.verified.filter (fun x => x != k),\n",""),
]


# ejb.26: these must also be noticed SEMANTICALLY (a failing example or a fuzz counterexample), not only by a broken proof
SEMANTIC_MUST_KILL = {'ver_mark_user_drags', 'ver_no_strike', 'ver_confirm_keeps_mark', 'ver_edit_keeps_mark', 'ver_edit_empty_keeps_mark', 'ver_edit_clears_moved_only', 'ver_crossing_strikes', 'ver_anchor_side_swapped', 'ver_rel_not_recorded'}
PROOF_MUST_KILL_ANY = {'ver_no_strike', 'ver_never_marked', 'ver_confirm_keeps_mark', 'ver_judge_ungated', 'own_whole_drawn_only', 'own_whole_unlisted_fails', 'own_whole_unread_fresh', 'free_ignores_unlisted', 'free_ignores_unread', 'free_ignores_movable', 'free_ignores_fold',
  'free_fold_any_chevron', 'engine_grant_bypasses_budget', 'needsStrip_false', 'postedEngine_skips_case', 'F1_label_user',
  'proof_counts_unsettled', 'proof_unobserved_counts', 'proof_pass_flips_early', 'proof_poll_flips_late'}  # some theorem or pin (Safety.lean or Gates/Truth/Honesty)
PROOF_MUST_KILL = {  # a Gates.lean/Truth.lean/Honesty.lean theorem must fail
  # ejb.3: the gates gate, the folded memory, failed drags, user events, one attempt per drop, pull-outs, subjects in the record
  'eng_no_hold', 'plan_no_givenUp', 'fullBar_ignores_chevron',
  'pile_replace_any_fresh', 'pile_replace_unsettled', 'pile_replace_incomplete', 'pile_replace_stripopen', 'pile_never_replace',
  'stale_replaces_pile', 'stale_no_union', 'proof_keeps_pile', 'proof_keeps_hold',
  'res_no_hold', 'res_hold_when_proven', 'res_no_giveup_full', 'res_strikes_1', 'res_strikes_never',
  'edit_never_release', 'edit_release_any', 'edit_release_no_holdFolded', 'edit_release_no_pile',
  'retry_keep_hold', 'rk_keep_hold', 'retry_keep_givenUp', 'rk_keep_givenUp', 'edit_keep_givenUp',
  'emit_no_erase', 'emit_no_consume_req', 'rearm_repeat', 'rearm_any_outcome',
  'applyMove_noop_always', 'um_seen_only_subset', 'um_want_only_subset', 'prefix_subset_only', 'prefix_superset_only',
  'um_pull_no_request', 'um_pull_no_fresh', 'um_pull_target_unfiltered', 'um_pull_noop_filter_dropped',
  'edit_pull_no_pile', 'edit_pull_no_drawn_before', 'rk_pull_no_record', 'rk_pull_no_drawn', 'rk_no_request',
  'emit_flightReq_always', 'edit_keeps_flightReq', 'retryKey_keeps_flightReq', 'empty_edit_keeps_flightReq',
  'rearm_no_request', 'rearm_overwrites_request',
  'edit_no_budget_reset', 'retry_no_budget', 'rk_no_budget', 'retry_keep_restricted', 'retry_no_grant',
  'plan_no_record_filter', 'edit_owed_no_record_filter', 'rk_no_owed_filter', 'rearm_not_in_record', 'edit_req_not_record',
  'edit_empty_no_filter_owed',
  'owed_no_request_first', 'never_rearm', 'rearm_granted', 'rearm_any_gen', 'plan_noop_move',
  # ejb.3 pass B: the gate, the pull-out and the view
  'decide_gate_removed', 'gate_ignores_consistent', 'gate_ignores_usable', 'view_uses_field', 'um_pull_from_memory',
  'status_view_ignored',
  # the drop rule (corrective pass): licence = owed or requested + fresh chevron + THIS read lists the key; the read supersedes the memory
  'um_licence_request_only', 'um_licence_non_owed', 'um_licence_memory_not_read', 'foldedAll_memory_not_superseded',
  # ejb.10: the fallback (strict reduction, best drag), the two phases, misplaced
  'fb_none', 'fb_not_strict', 'fb_nonstrict', 'fb_non_owed', 'fb_not_misplaced', 'fb_argmax', 'fb_argmin_first', 'fb_cands_before_only', 'fb_cands_unfiltered',
  'fb_count_all_keys', 'fb_count_flipped', 'fb_user_false', 'misplaced_ignores_record', 'misplaced_equal', 'misplaced_before_only', 'um_pull_user_false',
  'fb_not_in_record', 'fb_not_movable', 'whole_ignores_untrusted', 'whole_folded_any_chevron', 'whole_ignores_unread', 'whole_never',
  'phase_fallback_first', 'phase_single', 'phase2_over_anchor', 'queue_head_only', 'queue_reversed',
  'fb_no_penalty', 'fb_penalty_dir_flipped', 'fb_penalty_same_side', 'fb_leftward_flipped', 'fb_argmin_after_only', 'fb_fires_on_after_only'} | {
  # ejb.3 pass B: the verdict and the rows (a Truth.lean theorem must fail)
  'verdict_A1_untrusted_open', 'verdict_A2_pile_ignored', 'verdict_A2_any_chevron', 'verdict_A3_proof_not_needed',
  'verdict_A6_everything_listed', 'verdict_A6_unread_not_listed', 'verdict_unread_is_pinned_open',
  'usable_no_stale', 'usable_no_unsettled', 'usable_no_proof', 'usable_no_strip', 'usable_no_poll', 'usable_no_incomplete',
  'usable_no_observed', 'verdict_ignores_pile', 'verdict_ignores_unread', 'verdict_U_padded', 'verdict_U_empty',
  'verdict_R_never_cannotTell', 'verdict_forcedBad_ignores_behind', 'verdict_forcedBad_ignores_order', 'verdict_inconsistent_ok',
  'rowVerdict_tick_global', 'rowVerdict_no_outOfTurn', 'rowVerdict_inconsistent_ok', 'rowVerdict_unlisted_cannotTell',
  'rowVerdict_free_notOnBar', 'trustedDrawn_untrusted'}
# These must be caught by a theorem in Truth.lean itself (T1-T9 and the rows), whose imports are Model and Step only.
TRUTH_MUST_KILL = {
  'verdict_A1_untrusted_open', 'verdict_A2_pile_ignored', 'verdict_A2_any_chevron', 'verdict_A3_proof_not_needed',
  'verdict_A6_everything_listed', 'verdict_A6_unread_not_listed', 'verdict_unread_is_pinned_open',
  'usable_no_stale', 'usable_no_unsettled', 'usable_no_proof', 'usable_no_strip', 'usable_no_poll', 'usable_no_incomplete',
  'usable_no_observed', 'verdict_ignores_pile', 'verdict_ignores_unread', 'verdict_U_padded', 'verdict_U_empty',
  'verdict_R_never_cannotTell', 'verdict_forcedBad_ignores_behind', 'verdict_forcedBad_ignores_order', 'verdict_inconsistent_ok',
  'rowVerdict_tick_global', 'rowVerdict_no_outOfTurn', 'rowVerdict_inconsistent_ok', 'rowVerdict_unlisted_cannotTell',
  'rowVerdict_free_notOnBar', 'status_view_ignored', 'decide_gate_removed', 'gate_ignores_consistent', 'um_pull_from_memory',
  'trustedDrawn_untrusted'}
# These must be caught by a theorem in Honesty.lean itself (it builds, i.e. Gates.lean and Truth.lean are intact, and an Honesty
# declaration fails).  Honesty.lean imports Gates.lean and Status.lean (so Truth.lean): a mutant that breaks one of their proofs stops
# Honesty.lean from building at all; that kill is credited to Gates/Truth and says nothing about Honesty.lean.
HONESTY_MUST_KILL = {
  'status_matches_on_except', 'status_matches_on_cannotTell', 'status_checking_on_differs', 'status_moving_nothing_pending',
  'status_moving_never', 'status_pending_ignores_flight', 'status_pending_ignores_decide', 'status_stopped_without_budget',
  'status_barFull_without_hold', 'status_stopped_ignores_budget', 'budgetSpent_off_by_one', 'row_moving_never', 'row_waiting_never',
  'row_waiting_always', 'row_moving_inflight_only', 'row_moving_decide_only', 'row_waiting_ignores_request',
  'row_notWherePut_as_tick', 'row_behind_as_tick',
  'waiting_shown_on_good_read', 'waiting_only_when_move', 'waiting_only_when_not_good',
  # ejb.10: the note beside a row
  'note_never', 'note_without_owed', 'note_on_any_owed', 'note_on_tick', 'helps_ignores_others', 'helps_ignores_fallback', 'helps_not_misplaced', 'helps_always', 'helps_not_movable', 'helps_ignores_whole', 'cant_flipped', 'cant_ignores_decide', 'cant_not_misplaced', 'own_cant_no_owed', 'own_cant_userpick', 'cant_ignores_fallback'}
# ejb.12: a mutant of a fast definition must make an equality theorem of Fast.lean fail (the fast version is PROVED equal to the specification).
FAST_MUST_KILL = {m[0] for m in M if m[0].startswith('fast_')}
# Redundant guards: `decideMove` returns `none` unless `s.gate r`, and the gate requires `Read.usable` (a settled pass read, level not incomplete, strip
# closed, chevron fresh or proven absent), so the same conditions repeated in `decideMove`'s own guard and in `engineAllowed` change no decision.  The
# check is `gate_facts` (Honesty.lean) and the runner below: a mutant listed here must not be noticed by any example or fuzz check; it may still break a
# proof script that unfolds the redundant guard (a positional break, not a falsified property).
EQUIVALENT = {
  'ver_misplaced_not_checked': 'an engine drag is always `k before h` with h after k in the record (planOrderMoves: the first inversion), so k on the wrong side of its anchor h already means `misplaced`; the check only guards states no engine drag leaves',
  'plan_on_poll': 'the gate requires r.kind = .pass (Read.usable), so the guard `r.kind != .pass` in decideMove is redundant',
  'plan_unsettled': 'the gate requires r.settled = true (Read.usable), so the guard `!r.settled` in decideMove is redundant',
  'plan_incomplete': 'the gate requires r.level != .incomplete (Read.usable), so the guard in decideMove is redundant',
  'eng_no_stale': 'engineAllowed is reached only under the gate, which excludes a stale chevron (Read.usable: fresh, or absent with the proof)',
  'eng_no_open': 'engineAllowed is reached only under the gate, which requires r.stripOpen = false (Read.usable)',
}

def fresh(d):
    if os.path.exists(d): shutil.rmtree(d)
    shutil.copytree(LEAN, d, symlinks=True, ignore=shutil.ignore_patterns('.lake', 'scripts'))

def apply(d, old, new):
    for f in ['Sommelier/Step.lean', 'Sommelier/Model.lean', 'Sommelier/Safety.lean', 'Sommelier/Status.lean', 'Sommelier/Truth.lean', 'Sommelier/Fast.lean']:
        t = open(f'{d}/{f}').read()
        if t.count(old) == 1:
            open(f'{d}/{f}', 'w').write(t.replace(old, new)); return True
    return False

def failing_theorems(d, mod):
    """Names of the declarations of Sommelier/<mod>.lean that fail to elaborate (None if the module builds)."""
    b = subprocess.run(['lake', 'build', 'Sommelier.' + mod], cwd=d, capture_output=True, text=True)
    if b.returncode == 0: return None
    out = b.stdout + b.stderr
    lines = sorted(set(int(x) for x in re.findall(r'error: Sommelier/' + mod + r'\.lean:(\d+)', out)))
    src = open(f'{d}/Sommelier/{mod}.lean').read().split('\n')
    names = []
    for ln in lines:
        for i in range(min(ln, len(src)) - 1, -1, -1):
            m = re.match(r'(?:theorem|def|abbrev|structure|inductive)\s+([A-Za-z0-9_.\']+)', src[i])
            if m: names.append(m.group(1)); break
    return sorted(set(names)) or ['<module>']

def run(m, w):
    name, old, new = m
    d = f'{WORK}/{w}'
    fresh(d)
    if not apply(d, old, new): return name, 'BADPATCH', None, None
    # the mutant must at least elaborate Model and Step; Truth.lean and Status.lean contain `decide` witnesses and theorems that a
    # mutant may break (that is a kill), so `fuzz` (which imports them) is built only if they build.
    b = subprocess.run(['lake', 'build', 'Sommelier.Step'], cwd=d, capture_output=True, text=True)
    if b.returncode: return name, 'NOCOMPILE', None, (b.stdout + b.stderr)[-300:]
    kills = {}
    # Safety.lean and Gates.lean import only Step + Eqns, so a Safety proof that breaks cannot mask a Gates.lean theorem.
    # Honesty.lean imports Gates.lean and Status.lean/Truth.lean (not Safety.lean): a mutant that breaks a Gates.lean or Truth.lean proof stops Honesty.lean from building
    # at all, so Honesty.lean is only built (and its failing declarations only named) when Gates.lean builds: a `gates` kill says
    # nothing about Honesty.lean.  The modules are built separately and the failing declarations are named.
    eq = failing_theorems(d, 'Eqns')
    sf = failing_theorems(d, 'Safety')
    gf = failing_theorems(d, 'Gates')
    tf = failing_theorems(d, 'Truth')
    hf = failing_theorems(d, 'Honesty') if (gf is None and tf is None) else None
    ff = failing_theorems(d, 'Fast') if (gf is None and tf is None and hf is None) else None
    vf = failing_theorems(d, 'Verified') if (gf is None and tf is None and hf is None) else None   # ejb.17: the verified-revert bound
    pf = subprocess.run(['lake', 'build', 'Sommelier.Pins'], cwd=d, capture_output=True, text=True).returncode != 0
    e = subprocess.run(['lake', 'build', 'Sommelier.Examples'], cwd=d, capture_output=True, text=True)
    ex = sorted(set(int(x) for x in re.findall(r'error: Sommelier/Examples.lean:(\d+)', e.stdout + e.stderr)))
    # ejb.26: the verified-drag examples live in a module that imports only Step, so they decide the semantics even when a mutant breaks a Truth proof (Examples.lean then never builds)
    ve = subprocess.run(['lake', 'build', 'Sommelier.VerExamples'], cwd=d, capture_output=True, text=True)
    ex = ex + sorted(set(100000 + int(x) for x in re.findall(r'error: Sommelier/VerExamples.lean:(\d+)', ve.stdout + ve.stderr)))
    fk = {}
    if tf is None:
        bs = subprocess.run(['lake', 'build', 'Sommelier.Status'], cwd=d, capture_output=True, text=True)
        if bs.returncode: return name, 'NOCOMPILE', None, (bs.stdout + bs.stderr)[-300:]
    if tf is None:
        bf = subprocess.run(['lake', 'build', 'fuzz'], cwd=d, capture_output=True, text=True)
        if bf.returncode: return name, 'NOCOMPILE', None, (bf.stdout + bf.stderr)[-300:]
        f = subprocess.run(['.lake/build/bin/fuzz', '6000', '1500', '1'], cwd=d, capture_output=True, text=True)
        fk = {n: int(k) for n, _, k in re.findall(r'  (\w+): (\d+) instances, (\d+) failures', f.stdout) if int(k)}
        if f.returncode and not fk: fk['budget_saturation'] = 1
    kills.update(fk)
    if eq: kills['eqns'] = eq
    if sf: kills['safety'] = sf
    if gf: kills['gates'] = gf
    if hf: kills['honesty'] = hf
    if tf: kills['truth'] = tf
    if ff: kills['fast'] = ff
    if vf: kills['verified'] = vf
    if pf and not (eq or sf or gf or hf or tf or ff or vf): kills['pins'] = ['<pin>']
    if sf or gf or hf or pf or eq or tf or ff or vf: kills['theorems'] = 1
    return name, 'OK', ex, kills

if __name__ == '__main__':
    args = sys.argv[1:]
    check = '--check' in args
    jobs = 8
    if '--jobs' in args:
        k = args.index('--jobs'); jobs = int(args[k + 1]); del args[k:k + 2]
    sel = [a for a in args if not a.startswith('--')]
    ms = [m for m in M if not sel or m[0] in sel]
    if check:
        d = f'{WORK}/check'; bad = 0
        for m in ms:
            fresh(d)
            if not apply(d, m[1], m[2]): print('BADPATCH', m[0]); bad += 1
        print(f'{len(ms)} mutants, {bad} patches do not apply'); sys.exit(1 if bad else 0)
    q = Queue(); [q.put(i) for i in range(jobs)]
    def job(m):
        w = q.get()
        try: return run(m, w)
        finally: q.put(w)
    res = list(ThreadPoolExecutor(jobs).map(job, ms))
    json.dump(res, open(HERE + '/mutants.json', 'w'), indent=0)
    surv = []; invalid = []
    for n, st, ex, k in res:
        if st != 'OK': invalid.append(n); print(f'{n:32} {st} {k or ""}'); continue
        if not ex and not k: surv.append(n); print(f'{n:32} SURVIVES')
    ok = [(n, ex, k) for n, st, ex, k in res if st == 'OK']
    TH = ('gates', 'honesty', 'truth')
    by_gh = [n for n, ex, k in ok if any(t in k for t in TH)]   # a Gates/Truth/Honesty theorem fails
    by_saf = [n for n, ex, k in ok if 'theorems' in k and n not in by_gh]       # only Safety.lean / Eqns.lean / Pins.lean fails
    only_ef = [n for n, ex, k in ok if 'theorems' not in k]                      # only examples / fuzz notice
    print(f'{len(by_gh)} mutants fail a Gates.lean/Truth.lean/Honesty.lean theorem; {len(by_saf)} only a Safety.lean/Eqns.lean/Fast.lean theorem or a pin; '
          f'{len(only_ef)} are noticed only by examples/fuzz:')
    for n in by_saf: print('  Safety/Fast-only:', n)
    for n in only_ef: print('  examples/fuzz-only:', n)
    # does a HEADLINE theorem (the named statements of scripts/check-lean-axioms.sh) fail, or only a helper / specification lemma?
    hl = set(re.search(r'HEADLINE="(.*?)"', open(os.path.join(LEAN, '..', 'scripts', 'check-lean-axioms.sh')).read(), re.S).group(1).split())
    def failing(k): return set(sum([k[t] for t in ('eqns', 'safety', 'gates', 'truth', 'honesty', 'fast', 'verified') if t in k], []))
    by_head = [n for n, ex, k in ok if failing(k) & hl]
    by_helper = [n for n, ex, k in ok if 'theorems' in k and not (failing(k) & hl)]
    print(f'of the theorem kills, {len(by_head)} fail a named headline theorem (a theorem about the property) and {len(by_helper)} fail only a '
          f'helper/specification lemma or a pin (a break that may be incidental):')
    # semantic detection: an example (a concrete trace) or the fuzz harness (counterexample against a random honest bar) notices the
    # mutant; a mutant noticed ONLY by a broken proof script may be an incidental (positional) break, not a falsified property
    MODK = {'eqns', 'safety', 'gates', 'truth', 'honesty', 'pins', 'theorems', 'fast', 'verified'}
    sem = [n for n, ex, k in ok if ex or any(t not in MODK for t in k)]
    proof_only = [n for n, ex, k in ok if n not in sem]
    for n in sorted(SEMANTIC_MUST_KILL):
        if n in {r[0] for r in res} and n in proof_only: print('  FINDING: not noticed semantically (example/fuzz), only by a proof:', n)
    print(f'{len(sem)} killed mutants are also noticed semantically (a failing example or a fuzz counterexample); {len(proof_only)} die only to a broken proof/pin:')
    for n in proof_only: print('  proof-only:', n)
    ran = {r[0] for r in res}
    must = [n for n in PROOF_MUST_KILL if n in ran and n not in by_gh] + [n for n in PROOF_MUST_KILL_ANY if n in ran and n not in by_gh and n not in by_saf]
    for n in must: print('  FINDING: no theorem catches (Gates/Truth/Honesty required for the ejb.3 list)', n)
    must_head = [n for n, ex, k in ok if (n in PROOF_MUST_KILL or n in PROOF_MUST_KILL_ANY) and n not in by_head]
    for n in must_head: print('  NOTE: must-kill mutant dies to a helper/pin only, no named headline theorem fails:', n)
    # a Honesty kill needs Honesty.lean to build-fail on its own declarations, with Gates.lean and Truth.lean intact
    by_h = {n for n, ex, k in ok if 'honesty' in k}
    must_h = [n for n in sorted(HONESTY_MUST_KILL) if n in ran and n not in by_h]
    for n in must_h: print('  FINDING: no Honesty.lean theorem catches (kill is by Gates/Truth, a pin, an example or the fuzz only)', n)
    by_t = {n for n, ex, k in ok if 'truth' in k}
    must_t = [n for n in sorted(TRUTH_MUST_KILL) if n in ran and n not in by_t]
    for n in must_t: print('  FINDING: no Truth.lean theorem catches', n)
    eqv = [n for n, ex, k in ok if n in EQUIVALENT and (ex or any(t not in MODK for t in k))]
    for n in eqv: print('  FINDING: labelled equivalent but noticed by an example or the fuzz', n)
    by_f = {n for n, ex, k in ok if 'fast' in k}
    must_f = [n for n in sorted(FAST_MUST_KILL) if n in ran and n not in by_f]
    for n in must_f: print('  FINDING: no Fast.lean equality theorem catches', n)
    must = must + must_h + must_t + eqv + must_f
    killed = len(res) - len(surv) - len(invalid)
    print(f'{len(res)} mutants: {killed} killed, {len(surv)} survived, {len(invalid)} invalid (BADPATCH/NOCOMPILE, not counted as killed)')
    for n in surv: print('  survivor:', n, '-', EQUIVALENT.get(n, 'UNEXPLAINED'))
    # exit non-zero on any invalid mutant or any survivor that is not a documented equivalent, or a must-kill that no theorem catches
    sys.exit(1 if invalid or must or any(n not in EQUIVALENT for n in surv) else 0)
