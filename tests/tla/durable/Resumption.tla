---------------------------- MODULE Resumption ----------------------------
(***************************************************************************)
(* Step: agentic resumption.                                             *)
(*                                                                         *)
(* fx never asks the user to continue a session; it tells the agent.     *)
(* When a process reopens a session whose last turn was cut off          *)
(* by a crash, fx continues that turn on its own and tells the model     *)
(* "Resuming from unexpected session interruption". It never asks, and   *)
(* there is no crash-loop guard. A turn the user                       *)
(* stopped, or a committed turn, is never resumed automatically. Reopen  *)
(* covers `agent.resume()`, the queue waking a function through          *)
(* libfx/workflow's route, and `fx -c`.                                  *)
(*                                                                         *)
(* Today's CLI asks after the first unclean exit                          *)
(* (`ask_after_unclean_exit`); mutants.py keeps that behavior, and a     *)
(* one-resume guard, as planted bugs this spec must reject.              *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS MaxCrashes, MaxTurns

VARIABLES
    proc,           \* "running" | "down"
    turn,           \* durable: "none" | "open" | "committed" | "user_stopped"
    turns,          \* turns started (bound)
    crashesInTurn,  \* durable: unclean exits while this turn was open
    autoResumes,    \* durable: automatic resumptions of this turn
    asked,          \* fx asked the user what to do with this turn
    notices,        \* resume notices given to the model for this turn
    badResume,      \* history: an automatic resume of a turn that was not cut off
    crashes

vars == <<proc, turn, turns, crashesInTurn, autoResumes, asked, notices,
          badResume, crashes>>

TypeOK ==
    /\ proc \in {"running", "down"}
    /\ turn \in {"none", "open", "committed", "user_stopped"}
    /\ turns \in 0..MaxTurns
    /\ crashesInTurn \in 0..MaxCrashes
    /\ autoResumes \in 0..MaxCrashes
    /\ asked \in BOOLEAN
    /\ notices \in 0..MaxCrashes
    /\ badResume \in BOOLEAN
    /\ crashes \in 0..MaxCrashes

Init ==
    /\ proc = "running"
    /\ turn = "none"
    /\ turns = 0
    /\ crashesInTurn = 0
    /\ autoResumes = 0
    /\ asked = FALSE
    /\ notices = 0
    /\ badResume = FALSE
    /\ crashes = 0

StartTurn ==
    /\ proc = "running"
    /\ turn \in {"none", "committed", "user_stopped"}
    /\ turns < MaxTurns
    /\ turn' = "open"
    /\ turns' = turns + 1
    /\ crashesInTurn' = 0
    /\ autoResumes' = 0
    /\ asked' = FALSE
    /\ notices' = 0
    /\ UNCHANGED <<proc, badResume, crashes>>

\* The turn finishes and its end is durable.
Commit ==
    /\ proc = "running"
    /\ turn = "open"
    /\ turn' = "committed"
    /\ UNCHANGED <<proc, turns, crashesInTurn, autoResumes, asked, notices, badResume, crashes>>

\* The user cancels the turn (Esc, Ctrl+C, turn.cancel()); recorded durably.
UserStop ==
    /\ proc = "running"
    /\ turn = "open"
    /\ turn' = "user_stopped"
    /\ UNCHANGED <<proc, turns, crashesInTurn, autoResumes, asked, notices, badResume, crashes>>

\* Laptop crash, kill -9, function timeout.
Crash ==
    /\ proc = "running"
    /\ crashes < MaxCrashes
    /\ proc' = "down"
    /\ crashes' = crashes + 1
    /\ crashesInTurn' = IF turn = "open" THEN crashesInTurn + 1 ELSE crashesInTurn
    /\ UNCHANGED <<turn, turns, autoResumes, asked, notices, badResume>>

\* A clean exit only happens between turns.
CleanExit ==
    /\ proc = "running"
    /\ turn # "open"
    /\ proc' = "down"
    /\ UNCHANGED <<turn, turns, crashesInTurn, autoResumes, asked, notices, badResume, crashes>>

\* agent.resume(), the queue waking a function, or fx -c.
Reopen ==
    /\ proc = "down"
    /\ proc' = "running"
    /\ IF turn = "open"
       THEN /\ autoResumes' = autoResumes + 1
            /\ notices' = notices + 1
            /\ UNCHANGED asked
       ELSE UNCHANGED <<autoResumes, notices, asked>>
    /\ badResume' = (badResume \/ (autoResumes' > autoResumes /\ turn # "open"))
    /\ UNCHANGED <<turn, turns, crashesInTurn, crashes>>

Next ==
    \/ StartTurn
    \/ Commit
    \/ UserStop
    \/ Crash
    \/ CleanExit
    \/ Reopen

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Invariants *)

\* fx never asks the user to continue.
NeverAsks == ~asked

\* Every crash of an open turn was answered by an automatic resume by the
\* time the session runs again.
EveryCrashResumed == proc = "running" /\ turn = "open" => autoResumes = crashesInTurn

\* Every automatic resumption tells the model what happened.
ModelToldEveryTime == notices = autoResumes

\* Committed and user-stopped turns are never resumed automatically.
NeverResumeFinishedTurn == ~badResume

\* Each automatic resumption answers a crash during that turn.
AutoResumeOnlyAfterCrash == autoResumes <= crashesInTurn

=============================================================================
