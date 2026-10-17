------------------------------ MODULE Wiring ------------------------------
(***************************************************************************)
(* Step: fx wiring, through the adapter.                                   *)
(*                                                                         *)
(* One fx process at a time. It picks its backend once at start            *)
(* (`--sessions-v2` or FX_SESSIONS_V2, D26) and keeps it until it exits.   *)
(* The host has one session slot: it opens a session through the adapter, *)
(* runs turns, may switch to another session, and closes it at exit. To    *)
(* switch it may open the next session before closing the current one     *)
(* (D41), which fills a second slot, `next`, until the current closes. A   *)
(* turn may spawn a child thread, whose finish is appended through the     *)
(* parent's Session. Usage is charged to the profile as it happens and     *)
(* reaches the session log with the next durable batch; the profile's      *)
(* usage-recovery marker covers the gap. "Continue" starts a new turn      *)
(* linked to an interrupted one (D23). `/fork` (D58) makes a new session  *)
(* from the current one's log before a prompt and switches to it. The     *)
(* process can crash anywhere.                                            *)
(*                                                                         *)
(* The manager's own rules are modeled elsewhere (TurnLifecycle.tla,       *)
(* Subagents.tla, WriterLock.tla); here a reopen simply ends a turn a      *)
(* crash left open as interrupted (D1).                                    *)
(*                                                                         *)
(* Design: system-design.md "fx mapping" and D20 to D27.                   *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANT Sessions

Backends == {"v1", "v2"}
Ends == {"none", "commit", "interrupt"}

VARIABLES
    up,          \* the fx process is running
    backend,     \* the backend this process chose at start
    wrote,       \* backends this process has written since it started
    cur,         \* the session open in the host slot, or "none"
    turnOpen,    \* [Sessions -> BOOLEAN]: the log has an open turn
    lastEnd,     \* [Sessions -> Ends]: how the newest ended turn ended
    linked,      \* [Sessions -> Ends]: how the turn a continuation continues ended
    child,       \* "none" or "running": the one child thread
    childOf,     \* the session whose turn spawned the child, or "none"
    usageSplit,  \* [Sessions -> BOOLEAN]: the profile and the log may disagree on usage
    marker,      \* [Sessions -> BOOLEAN]: the profile's usage-recovery marker exists
    next,        \* the session opened to switch to, or "none" (D41)
    made,        \* [Sessions -> BOOLEAN]: the session exists on disk
    forkOf       \* [Sessions -> Sessions \cup {"none"}]: the session a fork came from

vars == <<up, backend, wrote, cur, turnOpen, lastEnd, linked, child, childOf, usageSplit, marker, next, made, forkOf>>

\* Every component uses the backend the process chose (D26).
ChildBackend == backend
UsageBackend == backend

TypeOK ==
    /\ up \in BOOLEAN
    /\ backend \in Backends
    /\ wrote \subseteq Backends
    /\ cur \in Sessions \cup {"none"}
    /\ turnOpen \in [Sessions -> BOOLEAN]
    /\ lastEnd \in [Sessions -> Ends]
    /\ linked \in [Sessions -> Ends]
    /\ child \in {"none", "running"}
    /\ childOf \in Sessions \cup {"none"}
    /\ usageSplit \in [Sessions -> BOOLEAN]
    /\ marker \in [Sessions -> BOOLEAN]
    /\ next \in Sessions \cup {"none"}
    /\ made \in [Sessions -> BOOLEAN]
    /\ forkOf \in [Sessions -> Sessions \cup {"none"}]

Init ==
    /\ up = FALSE
    /\ backend = "v1"
    /\ wrote = {}
    /\ cur = "none"
    /\ turnOpen = [s \in Sessions |-> FALSE]
    /\ lastEnd = [s \in Sessions |-> "none"]
    /\ linked = [s \in Sessions |-> "none"]
    /\ child = "none"
    /\ childOf = "none"
    /\ usageSplit = [s \in Sessions |-> FALSE]
    /\ marker = [s \in Sessions |-> FALSE]
    /\ next = "none"
    /\ made = [s \in Sessions |-> FALSE]
    /\ forkOf = [s \in Sessions |-> "none"]

Active == up /\ cur # "none"

\* fx starts and picks its backend, once.
Start(b) ==
    /\ ~up
    /\ up' = TRUE
    /\ backend' = b
    /\ wrote' = {}
    /\ UNCHANGED <<cur, turnOpen, lastEnd, linked, child, childOf, usageSplit, marker, next, made, forkOf>>

\* Startup usage recovery: a marker left by a crash is reconciled, then removed.
RecoverUsage(s) ==
    /\ up
    /\ marker[s]
    /\ usageSplit' = [usageSplit EXCEPT ![s] = FALSE]
    /\ marker' = [marker EXCEPT ![s] = FALSE]
    /\ UNCHANGED <<up, backend, wrote, cur, turnOpen, lastEnd, linked, child, childOf, next, made, forkOf>>

\* The adapter opens a session: into the slot, or, while one is open, as the
\* session to switch to (D41). A turn a crash left open ends as interrupted.
Open(s) ==
    /\ up
    /\ next = "none"
    /\ s # cur
    /\ IF cur = "none" THEN cur' = s /\ next' = "none" ELSE cur' = cur /\ next' = s
    /\ wrote' = wrote \cup {backend}
    /\ turnOpen' = [turnOpen EXCEPT ![s] = FALSE]
    /\ lastEnd' = IF turnOpen[s] THEN [lastEnd EXCEPT ![s] = "interrupt"] ELSE lastEnd
    /\ made' = [made EXCEPT ![s] = TRUE]
    /\ UNCHANGED <<up, backend, linked, child, childOf, usageSplit, marker, forkOf>>

\* New work needs a session and no switch pending.
Idle == Active /\ next = "none"

BeginTurn ==
    /\ Idle
    /\ ~turnOpen[cur]
    /\ turnOpen' = [turnOpen EXCEPT ![cur] = TRUE]
    /\ linked' = [linked EXCEPT ![cur] = "none"]
    /\ wrote' = wrote \cup {backend}
    /\ UNCHANGED <<up, backend, cur, lastEnd, child, childOf, usageSplit, marker, next, made, forkOf>>

\* "Continue" (D23): a new turn whose first item links to the newest ended
\* turn, which must have been interrupted.
Continue ==
    /\ Idle
    /\ ~turnOpen[cur]
    /\ lastEnd[cur] = "interrupt"
    /\ turnOpen' = [turnOpen EXCEPT ![cur] = TRUE]
    /\ linked' = [linked EXCEPT ![cur] = lastEnd[cur]]
    /\ wrote' = wrote \cup {backend}
    /\ UNCHANGED <<up, backend, cur, lastEnd, child, childOf, usageSplit, marker, next, made, forkOf>>

\* Before a model request is charged, the marker is written.
MarkUsage ==
    /\ Active
    /\ turnOpen[cur]
    /\ ~marker[cur]
    /\ marker' = [marker EXCEPT ![cur] = TRUE]
    /\ UNCHANGED <<up, backend, wrote, cur, turnOpen, lastEnd, linked, child, childOf, usageSplit, next, made, forkOf>>

\* The request is charged to the profile; the log has not caught up yet.
Charge ==
    /\ Active
    /\ turnOpen[cur]
    /\ marker[cur]
    /\ usageSplit' = [usageSplit EXCEPT ![cur] = TRUE]
    /\ UNCHANGED <<up, backend, wrote, cur, turnOpen, lastEnd, linked, child, childOf, marker, next, made, forkOf>>

\* A usage checkpoint mid-turn: `set usage` is a durability point, so the
\* log catches up with the profile once the append returns.
PersistUsage ==
    /\ Active
    /\ usageSplit[cur]
    /\ usageSplit' = [usageSplit EXCEPT ![cur] = FALSE]
    /\ wrote' = wrote \cup {UsageBackend}
    /\ UNCHANGED <<up, backend, cur, turnOpen, lastEnd, linked, child, childOf, marker, next, made, forkOf>>

\* The turn ends, also while a switch is pending (a cancelled turn); the
\* usage so far is written in the same durable batch.
EndTurn(e) ==
    /\ Active
    /\ turnOpen[cur]
    /\ turnOpen' = [turnOpen EXCEPT ![cur] = FALSE]
    /\ lastEnd' = [lastEnd EXCEPT ![cur] = e]
    /\ usageSplit' = [usageSplit EXCEPT ![cur] = FALSE]
    /\ wrote' = wrote \cup {UsageBackend}
    /\ UNCHANGED <<up, backend, cur, linked, child, childOf, marker, next, made, forkOf>>

\* Once a durable batch carried the usage, the marker goes.
ClearMarker(s) ==
    /\ up
    /\ marker[s]
    /\ ~usageSplit[s]
    /\ marker' = [marker EXCEPT ![s] = FALSE]
    /\ UNCHANGED <<up, backend, wrote, cur, turnOpen, lastEnd, linked, child, childOf, usageSplit, next, made, forkOf>>

\* A turn spawns a child thread (child_spawned through the parent).
Spawn ==
    /\ Idle
    /\ turnOpen[cur]
    /\ child = "none"
    /\ child' = "running"
    /\ childOf' = cur
    /\ wrote' = wrote \cup {backend, ChildBackend}
    /\ UNCHANGED <<up, backend, cur, turnOpen, lastEnd, linked, usageSplit, marker, next, made, forkOf>>

\* The child's thread appends child_finished through the parent's Session,
\* or the parent cancels it; either way through an open parent.
ChildDone ==
    /\ up
    /\ child = "running"
    /\ cur = childOf
    /\ child' = "none"
    /\ childOf' = "none"
    /\ wrote' = wrote \cup {backend}
    /\ UNCHANGED <<up, backend, cur, turnOpen, lastEnd, linked, usageSplit, marker, next, made, forkOf>>

\* The host closes a session, to switch or to exit: children are finished
\* and joined first, then close interrupts an open turn and carries usage.
\* Closing the current session hands the slot to the one switched to;
\* closing that one instead abandons the switch (D41).
Close(s) ==
    /\ up
    /\ s \in {cur, next} \ {"none"}
    /\ child = "none"
    /\ cur' = IF s = cur THEN next ELSE cur
    /\ next' = "none"
    /\ turnOpen' = [turnOpen EXCEPT ![s] = FALSE]
    /\ lastEnd' = IF turnOpen[s] THEN [lastEnd EXCEPT ![s] = "interrupt"] ELSE lastEnd
    /\ usageSplit' = [usageSplit EXCEPT ![s] = FALSE]
    /\ wrote' = wrote \cup {backend}
    /\ UNCHANGED <<up, backend, linked, child, childOf, marker, made, forkOf>>

\* /fork (D58): a new session holding the current one's log before a chosen
\* prompt becomes the session to switch to, and Close then hands it the
\* slot. Only on v2, between turns and with no child running; the source
\* is never written. The fork's newest ended turn is whichever the source
\* had before that prompt.
Fork(f) ==
    /\ Idle
    /\ backend = "v2"
    /\ child = "none"
    /\ f \notin {cur, next}
    /\ ~made[f]
    /\ ~turnOpen[cur]
    /\ next' = f
    /\ made' = [made EXCEPT ![f] = TRUE]
    /\ forkOf' = [forkOf EXCEPT ![f] = cur]
    /\ \E e \in Ends : lastEnd' = [lastEnd EXCEPT ![f] = e]
    /\ wrote' = wrote \cup {backend}
    /\ UNCHANGED <<up, backend, cur, turnOpen, linked, child, childOf, usageSplit, marker>>

Exit ==
    /\ up
    /\ cur = "none"
    /\ next = "none"
    /\ child = "none"
    /\ up' = FALSE
    /\ UNCHANGED <<backend, wrote, cur, turnOpen, lastEnd, linked, child, childOf, usageSplit, marker, next, made, forkOf>>

\* The process dies anywhere: memory and threads are gone; the logs, the
\* profile ledger and the marker stay.
Crash ==
    /\ up
    /\ up' = FALSE
    /\ cur' = "none"
    /\ next' = "none"
    /\ child' = "none"
    /\ childOf' = "none"
    /\ UNCHANGED <<backend, wrote, turnOpen, lastEnd, linked, usageSplit, marker, made, forkOf>>

Next ==
    \/ \E b \in Backends : Start(b)
    \/ \E s \in Sessions : RecoverUsage(s) \/ Open(s) \/ ClearMarker(s) \/ Close(s)
    \/ BeginTurn \/ Continue
    \/ MarkUsage \/ Charge \/ PersistUsage
    \/ \E e \in {"commit", "interrupt"} : EndTurn(e)
    \/ Spawn \/ ChildDone
    \/ \E f \in Sessions : Fork(f)
    \/ Exit \/ Crash

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Invariants *)

\* A process writes one backend only: no dual writes.
OneBackend == Cardinality(wrote) <= 1

\* A child thread runs only while its parent's Session is open.
ParentOutlivesChildren == child = "running" => (up /\ cur = childOf)

\* Whenever the profile and the log may disagree on usage, the marker says so.
UsageNeverSilent == \A s \in Sessions : usageSplit[s] => marker[s]

\* A pending switch names a second session, never the current one (D41).
SwitchIsTwoSessions == next # "none" => (cur # "none" /\ cur # next)

\* A continuation always continues an interrupted turn.
ContinueLinksInterrupted == \A s \in Sessions : linked[s] \in {"none", "interrupt"}

(* Properties of /fork (D58) *)

ForkStep(f) == forkOf'[f] # forkOf[f]

\* A fork is a session that never existed: it never replaces one.
ForkIsNewSession == [][\A f \in Sessions : ForkStep(f) => ~made[f]]_vars

\* The fork step leaves the source as it was.
ForkLeavesSource ==
    [][\A f \in Sessions : ForkStep(f) =>
         /\ turnOpen'[cur] = turnOpen[cur] /\ lastEnd'[cur] = lastEnd[cur]
         /\ linked'[cur] = linked[cur] /\ usageSplit'[cur] = usageSplit[cur]]_vars

\* A fork happens on v2, between turns, with no child running.
ForkBetweenTurns ==
    [][\A f \in Sessions : ForkStep(f) =>
         (backend = "v2" /\ ~turnOpen[cur] /\ child = "none")]_vars
=============================================================================
