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
WORK = os.environ.get('MUTANT_WORK', '/tmp/sommelier-mutants')
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
('fresh_no_revoke',"{ s with provenNotFull := false, noChevronReads := 0,\n               lastFreshPile","{ s with noChevronReads := 0,\n               lastFreshPile"),
('fresh_no_count_reset',"{ s with provenNotFull := false, noChevronReads := 0,\n               lastFreshPile","{ s with provenNotFull := false,\n               lastFreshPile"),
('incomplete_no_reset',"else if r.level == .incomplete then { s with noChevronReads := 0 }","else if r.level == .incomplete then s"),
('incomplete_counts',"else if r.level == .incomplete then { s with noChevronReads := 0 }\n",""+"\n"),
('proof_at_2',"s.noChevronReads + 1 >= 3","s.noChevronReads + 1 >= 2"),
('proof_at_4',"s.noChevronReads + 1 >= 3","s.noChevronReads + 1 >= 4"),
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
('um_pull_no_request',"if s.foldRequest == some k && r.chevron == .fresh then","if r.chevron == .fresh then"),
('um_pull_no_fresh',"if s.foldRequest == some k && r.chevron == .fresh then","if s.foldRequest == some k then"),
('um_pull_target_unfiltered','((hv.filter (fun x => before.contains x)).getLast?)','(before.getLast?)'),
('um_anchors_include_owed',"a != k && s.record.contains a && !s.owedKeys.contains a","a != k && s.record.contains a"),
('um_anchors_any_drawn',"a != k && s.record.contains a && !s.owedKeys.contains a","a != k && !s.owedKeys.contains a"),
('um_seen_only_subset',"if seen.all (fun a => want.contains a) && want.all (fun a => seen.contains a) then none","if seen.all (fun a => want.contains a) then none"),
('um_want_only_subset',"if seen.all (fun a => want.contains a) && want.all (fun a => seen.contains a) then none","if want.all (fun a => seen.contains a) then none"),
('um_no_following','| none => anchors.head?.map (fun t => mk (.before t))','| none => none'),
('um_user_false',"needsStrip s r k rel, true⟩","needsStrip s r k rel, false⟩"),
('um_strip_false',"needsStrip s r k rel, true⟩","false, true⟩"),
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
('plan_incomplete',"|| r.level == .incomplete || s.inFlight.isSome then none","|| s.inFlight.isSome then none"),
('plan_inflight',"|| r.level == .incomplete || s.inFlight.isSome then none","|| r.level == .incomplete then none"),
('owed_no_request_first',"(s.foldRequest.toList ++ s.owedKeys).findSome?","(s.owedKeys).findSome?"),
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
('res_no_giveup_full',"givenUp := if s0.givenUp.contains a.subject then s0.givenUp else a.subject :: s0.givenUp }","givenUp := s0.givenUp }"),
('res_hold_when_proven',"if s0.provenNotFull then\n          let n","if false then\n          let n"),
('res_strikes_1',"if n >= 3 && !s0.givenUp","if n >= 1 && !s0.givenUp"),
('res_strikes_never',"if n >= 3 && !s0.givenUp","if n >= 99 && !s0.givenUp"),
('res_no_session_return',"editSessionUsed := if a.strip then false else s0.editSessionUsed,","editSessionUsed := s0.editSessionUsed,"),
('res_no_skip',"skipped := if was then s0.skipped else a.subject :: s0.skipped }","skipped := s0.skipped }"),
('rearm_any_outcome',"if o == .busy && s0.flightOwed == some s0.gen","if s0.flightOwed == some s0.gen"),
('rearm_any_gen',"if o == .busy && s0.flightOwed == some s0.gen && !was","if o == .busy && s0.flightOwed.isSome && !was"),
('rearm_granted',"if o == .busy && s0.flightOwed == some s0.gen && !was","if o == .busy && !was"),
('rearm_repeat',"s0.flightOwed == some s0.gen && !was &&","s0.flightOwed == some s0.gen &&"),
('rearm_not_in_record',"!was && s0.record.contains a.subject then","!was then"),
('rearm_no_request','foldRequest := if s0.flightReq then some a.subject else s1.foldRequest }','foldRequest := s1.foldRequest }'),
('never_rearm',"if o == .busy && s0.flightOwed == some s0.gen","if false && s0.flightOwed == some s0.gen"),
# events
('step_emit_drop',"| some a => (emit s' a, [a])","| some a => (s', [a])"),
('edit_empty_no_filter_owed',"({ s with record := rec, owedKeys := s.owedKeys.filter (fun k => rec.contains k),\n","({ s with record := rec,\n"),
('edit_empty_no_filter_req',"\n                  foldRequest := s.foldRequest.filter (fun k => rec.contains k) }, [])"," }, [])"),
('edit_overwrite_owed',"let owed := (s.owedKeys ++ rec.filter (fun k => moved.contains k)).eraseDups","let owed := (rec.filter (fun k => moved.contains k)).eraseDups"),
('edit_owed_no_record_filter',".eraseDups.filter (fun k => rec.contains k)\n",".eraseDups\n"),
('edit_pull_no_pile',"moved.contains k && s.lastFreshPile.contains k\n","moved.contains k\n"),
('edit_pull_no_drawn_before',"\n                                 && (rec.takeWhile (fun x => x != k)).any (fun x => s.lastDrawn.contains x))",")"),
('edit_release_any','hold := s.hold && !release,','hold := false,'),
('edit_never_release','hold := s.hold && !release,','hold := s.hold,'),
('edit_release_no_holdFolded',"moved.any (fun k => s.holdFolded.contains k || s.lastFreshPile.contains k)","moved.any (fun k => s.lastFreshPile.contains k)"),
('edit_release_no_pile',"moved.any (fun k => s.holdFolded.contains k || s.lastFreshPile.contains k)","moved.any (fun k => s.holdFolded.contains k)"),
('edit_no_budget_reset',"({ s with record := rec, moveCount := 0, restricted := true,","({ s with record := rec, restricted := true,"),
('edit_not_restricted',"moveCount := 0, restricted := true, editSessionUsed := false,\n                  owedKeys := owed","moveCount := 0, editSessionUsed := false,\n                  owedKeys := owed"),
('edit_no_session_reset',"restricted := true, editSessionUsed := false,\n                  owedKeys := owed","restricted := true,\n                  owedKeys := owed"),
('edit_keep_skipped',"\n                  skipped := [],\n                  strikes","\n                  strikes"),
('edit_keep_strikes',"strikes := s.strikes.filter (fun k => !moved.contains k),\n",""),
('edit_keep_givenUp',"strikes := s.strikes.filter (fun k => !moved.contains k),\n                  givenUp := s.givenUp.filter (fun k => !moved.contains k) }","strikes := s.strikes.filter (fun k => !moved.contains k) }"),
('edit_clear_all_givenUp',"givenUp := s.givenUp.filter (fun k => !moved.contains k) }","givenUp := [] }"),
('edit_req_keep_moved',"| none => s.foldRequest.filter (fun k => !moved.contains k && rec.contains k),","| none => s.foldRequest.filter (fun k => rec.contains k),"),
('edit_req_not_record',"| none => s.foldRequest.filter (fun k => !moved.contains k && rec.contains k),","| none => s.foldRequest.filter (fun k => !moved.contains k),"),
('retry_no_budget','({ s with moveCount := 0, hold := false, givenUp := [], strikes','({ s with hold := false, givenUp := [], strikes'),
('retry_keep_hold','({ s with moveCount := 0, hold := false, givenUp := [], strikes','({ s with moveCount := 0, givenUp := [], strikes'),
('retry_keep_givenUp','hold := false, givenUp := [], strikes := [], skipped := [],','hold := false, strikes := [], skipped := [],'),
('retry_keep_strikes',"givenUp := [], strikes := [], skipped := [],","givenUp := [], skipped := [],"),
('retry_keep_skipped',"givenUp := [], strikes := [], skipped := [],","givenUp := [], strikes := [],"),
('retry_keep_restricted',"restricted := false, owedKeys := [], foldRequest := none, stripGrant := true,","owedKeys := [], foldRequest := none, stripGrant := true,"),
('retry_keep_owed',"restricted := false, owedKeys := [], foldRequest := none, stripGrant := true,","restricted := false, foldRequest := none, stripGrant := true,"),
('retry_keep_req',"restricted := false, owedKeys := [], foldRequest := none, stripGrant := true,","restricted := false, owedKeys := [], stripGrant := true,"),
('retry_no_grant',"foldRequest := none, stripGrant := true, gen := s.gen + 1,","foldRequest := none, gen := s.gen + 1,"),
('retry_no_gen',"stripGrant := true, gen := s.gen + 1,\n","stripGrant := true,\n"),
('retry_no_session',"gen := s.gen + 1,\n                editSessionUsed := false }, [])","gen := s.gen + 1 }, [])"),
('rk_pull_no_record',"let pull := s.record.contains k && s.lastFreshPile.contains k","let pull := s.lastFreshPile.contains k"),
('rk_pull_no_drawn'," && (s.record.takeWhile (fun x => x != k)).any (fun x => s.lastDrawn.contains x)\n","\n"),
('rk_no_budget','({ s with moveCount := 0, hold := false, givenUp := s.givenUp.erase k,','({ s with hold := false, givenUp := s.givenUp.erase k,'),
('rk_keep_hold','({ s with moveCount := 0, hold := false, givenUp := s.givenUp.erase k,','({ s with moveCount := 0, givenUp := s.givenUp.erase k,'),
('rk_keep_givenUp',"givenUp := s.givenUp.erase k,\n","\n"),
('rk_keep_strikes',"strikes := s.strikes.filter (fun x => x != k), skipped := [], restricted := true,","skipped := [], restricted := true,"),
('rk_keep_skipped',"skipped := [], restricted := true,\n","restricted := true,\n"),
('rk_not_restricted',"skipped := [], restricted := true,\n","skipped := [],\n"),
('rk_no_session','editSessionUsed := false,\n                owedKeys := (k ::','owedKeys := (k ::'),
('rk_no_owed_filter',"(k :: s.owedKeys).eraseDups.filter (fun x => s.record.contains x)","(k :: s.owedKeys).eraseDups"),
('rk_no_request',"foldRequest := if pull then some k else s.foldRequest }","foldRequest := s.foldRequest }"),
('mr_no_match',"| some a => if a.subject == k then (result s a o posted, []) else (s, [])","| some a => (result s a o posted, [])"),
('pb_grant_survives',"foldRequest := none, stripGrant := false, gen := s.gen + 1 }","foldRequest := none, gen := s.gen + 1 }"),
('pb_owed_survives',"({ s with restricted := false, owedKeys := [], foldRequest := none, stripGrant := false,","({ s with restricted := false, foldRequest := none, stripGrant := false,"),
('pb_req_survives',"({ s with restricted := false, owedKeys := [], foldRequest := none, stripGrant := false,","({ s with restricted := false, owedKeys := [], stripGrant := false,"),
('pb_restricted_survives',"({ s with restricted := false, owedKeys := [], foldRequest := none, stripGrant := false,","({ s with owedKeys := [], foldRequest := none, stripGrant := false,"),
('pb_no_gen',"stripGrant := false, gen := s.gen + 1 }, [])","stripGrant := false }, [])"),
('pb_clears_hold',"foldRequest := none, stripGrant := false, gen := s.gen + 1 }","foldRequest := none, stripGrant := false, gen := s.gen + 1, hold := false }"),
('pb_resets_budget',"foldRequest := none, stripGrant := false, gen := s.gen + 1 }","foldRequest := none, stripGrant := false, gen := s.gen + 1, moveCount := 0 }"),
('lastDrawn_any_read','let s := if r.kind == .pass && r.settled && r.level != .incomplete then { s with lastDrawn := r.drawn } else s','let s := { s with lastDrawn := r.drawn }'),
('lastDrawn_incomplete_ok','r.kind == .pass && r.settled && r.level != .incomplete then { s with lastDrawn','r.kind == .pass && r.settled then { s with lastDrawn'),
('um_pull_noop_filter_dropped','(((hv.filter (fun x => before.contains x)).getLast?).map (fun p => mk (.after p))).filter\n        (fun a => applyMove r.drawn a != r.drawn)','((hv.filter (fun x => before.contains x)).getLast?).map (fun p => mk (.after p))'),
('prefix_subset_only','(l.take i).all (fun a => want.contains a) && want.all (fun a => (l.take i).contains a)','(l.take i).all (fun a => want.contains a)'),
('prefix_superset_only','(l.take i).all (fun a => want.contains a) && want.all (fun a => (l.take i).contains a)','want.all (fun a => (l.take i).contains a)'),
('um_gap_after_last','| none => anchors.head?.map (fun t => mk (.before t))','| none => anchors.getLast?.map (fun t => mk (.after t))'),
('emit_flightReq_always','flightReq := s.foldRequest == some a.subject,','flightReq := true,'),
('applyMove_noop_always',"if !l'.contains a.rel.target then l",'if true then l'),
]

EQUIVALENT = {}  # name -> reason (filled in below)

def fresh(d):
    if os.path.exists(d): shutil.rmtree(d)
    shutil.copytree(LEAN, d, symlinks=True, ignore=shutil.ignore_patterns('.lake', 'scripts'))

def apply(d, old, new):
    for f in ['Sommelier/Step.lean', 'Sommelier/Model.lean']:
        t = open(f'{d}/{f}').read()
        if t.count(old) == 1:
            open(f'{d}/{f}', 'w').write(t.replace(old, new)); return True
    return False

def run(m, w):
    name, old, new = m
    d = f'{WORK}/{w}'
    fresh(d)
    if not apply(d, old, new): return name, 'BADPATCH', None, None
    b = subprocess.run(['lake', 'build', 'fuzz'], cwd=d, capture_output=True, text=True)
    if b.returncode: return name, 'NOCOMPILE', None, (b.stdout + b.stderr)[-300:]
    e = subprocess.run(['lake', 'build', 'Sommelier.Examples'], cwd=d, capture_output=True, text=True)
    ex = sorted(set(int(x) for x in re.findall(r'error: Sommelier/Examples.lean:(\d+)', e.stdout + e.stderr)))
    f = subprocess.run(['.lake/build/bin/fuzz', '6000', '1500', '1'], cwd=d, capture_output=True, text=True)
    kills = {n: int(k) for n, _, k in re.findall(r'  (\w+): (\d+) instances, (\d+) failures', f.stdout) if int(k)}
    if f.returncode and not kills: kills['budget_saturation'] = 1
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
    surv = []
    for n, st, ex, k in res:
        if st != 'OK': print(f'{n:32} {st} {k or ""}'); continue
        if not ex and not k: surv.append(n); print(f'{n:32} SURVIVES')
    print(f'{len(res)} mutants: {len(res) - len(surv)} killed, {len(surv)} survived')
    for n in surv: print('  survivor:', n, '-', EQUIVALENT.get(n, 'UNEXPLAINED'))
    sys.exit(0)
