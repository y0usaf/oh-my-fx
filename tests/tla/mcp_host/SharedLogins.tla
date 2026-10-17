---- MODULE SharedLogins ----
\* Several fx processes sharing one saved login for one MCP server
\* (src/core/mcp_host/runtime.zig pickUpLogin and saveCredential,
\* credentials.zig removeIfSame).
\*
\* The store holds the version of the login last saved, 0 for none; each
\* sign-in anywhere is a new, higher version. Each process holds a version in
\* memory, 0 when signed out, and remembers the last version it had or tried
\* (`tried`, a digest in the code).
\*   - SignIn: a process signs in and saves its version.
\*   - Refused: the server stops taking the version a process holds (a newer
\*     sign-in elsewhere rotated it, or it expired). Its tokens drop, it needs
\*     a login, and it removes the saved login only if that is its own.
\*   - NeedsScope: the server wants more than the version a process holds
\*     (a step-up); it needs a login but keeps its tokens, so nothing is
\*     removed and the saved login is still its own.
\*   - PickUp: a process that needs a login takes the saved one, unless it
\*     already had or tried it.
\*   - Logout: a sign-out on purpose removes the saved login, whoever saved it.
EXTENDS Naturals

CONSTANTS
    Procs,    \* fx processes sharing the store
    MaxVer    \* sign-ins per run

VARIABLES
    store,    \* the saved version, 0 for none
    held,     \* [Procs -> the version held, 0 for none]
    tried,    \* [Procs -> the last version had or tried, 0 for none]
    needs,    \* [Procs -> needs a login]
    next,     \* the next sign-in's version
    \* Ghosts.
    erased,   \* a refusal removed a newer login another process saved
    retook    \* a process took a version it had or tried before

vars == <<store, held, tried, needs, next, erased, retook>>

TypeOK ==
    /\ store \in 0..MaxVer
    /\ held \in [Procs -> 0..MaxVer]
    /\ tried \in [Procs -> 0..MaxVer]
    /\ needs \in [Procs -> BOOLEAN]
    /\ next \in 1..(MaxVer + 1)
    /\ erased \in BOOLEAN /\ retook \in BOOLEAN

Init ==
    /\ store = 0
    /\ held = [p \in Procs |-> 0]
    /\ tried = [p \in Procs |-> 0]
    /\ needs = [p \in Procs |-> FALSE]
    /\ next = 1
    /\ erased = FALSE /\ retook = FALSE

SignIn(p) ==
    /\ next <= MaxVer
    /\ store' = next
    /\ held' = [held EXCEPT ![p] = next]
    /\ tried' = [tried EXCEPT ![p] = next]
    /\ needs' = [needs EXCEPT ![p] = FALSE]
    /\ next' = next + 1
    /\ UNCHANGED <<erased, retook>>

Refused(p) ==
    /\ held[p] # 0
    /\ held' = [held EXCEPT ![p] = 0]
    /\ needs' = [needs EXCEPT ![p] = TRUE]
    /\ store' = IF store = tried[p] THEN 0 ELSE store
    /\ erased' = (erased \/ (store > tried[p] /\ store' = 0))
    /\ UNCHANGED <<tried, next, retook>>

NeedsScope(p) ==
    /\ held[p] # 0
    /\ ~needs[p]
    /\ needs' = [needs EXCEPT ![p] = TRUE]
    /\ UNCHANGED <<store, held, tried, next, erased, retook>>

PickUp(p) ==
    /\ needs[p]
    /\ store # 0
    /\ store # tried[p]
    /\ held' = [held EXCEPT ![p] = store]
    /\ tried' = [tried EXCEPT ![p] = store]
    /\ needs' = [needs EXCEPT ![p] = FALSE]
    /\ retook' = (retook \/ store = tried[p])
    /\ UNCHANGED <<store, next, erased>>

Logout(p) ==
    /\ held[p] # 0
    /\ held' = [held EXCEPT ![p] = 0]
    /\ store' = 0
    /\ UNCHANGED <<tried, needs, next, erased, retook>>

\* Nothing happens: a run may end anywhere, so no state is a deadlock.
Idle == UNCHANGED vars

Next == (\E p \in Procs : SignIn(p) \/ Refused(p) \/ NeedsScope(p) \/ PickUp(p) \/ Logout(p)) \/ Idle

Spec == Init /\ [][Next]_vars

\* A refusal never removes a newer login another process saved.
NoNewerLoginErased == ~erased

\* A process never takes a version it had or tried before.
NoLoginRetaken == ~retook

\* What a process holds is the version it last had or tried; so a refused
\* process removes its own saved login, and only that.
HeldIsTried == \A p \in Procs : held[p] # 0 => held[p] = tried[p]
====
