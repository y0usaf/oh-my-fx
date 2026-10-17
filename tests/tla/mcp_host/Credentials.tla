---- MODULE Credentials ----
\* fx's MCP-v2 credential store (src/core/mcp_host/credentials.zig), file
\* backend (FX_DISABLE_KEYCHAIN=1; the Keychain backend reads and writes the
\* same document through native_keychain, and keeps its note as a file too).
\*
\* One document, `~/.fx/mcp-credentials/credentials-v2.json`:
\*   {"version":1, "imported_v1":bool, "servers":[{name,url,credential}]}
\* and one note beside it, `v1-imported`, saying v1's logins were taken over.
\* Every operation holds the directory's advisory lock (Store.lock), so each
\* is atomic here. Each one reads the document first (Store.read):
\*   - readSaved: a missing file is empty. One that doesn't parse, or whose
\*     version isn't 1, is unreadable, and nothing writes over it:
\*     get finds no login, and put and remove fail;
\*   - read: unless the document's flag or the note says v1's logins were
\*     taken over, they are (importV1: each v1 login whose name and URL the
\*     document lacks), and the document and the note are written at once,
\*     even by `get`. A document with the flag but no note, saved before the
\*     note existed, gets the note.
\* Operations: get (config.resolve -> Runtime.savedCredential, for every
\* HTTP server, whenever a host starts: `fx mcp list`, `fx ask`, the shell),
\* put (a `credential` event after a sign-in or refresh), remove (logout:
\* runtime.zig `.logout`; verbs.zig remove and logout).
\*
\* Entries are names: each scenario gives each server one URL. Deleting the
\* note as well (the whole directory) is outside the model: with the
\* Keychain, v1's logins would then be taken over again.
EXTENDS Naturals, FiniteSets

CONSTANTS
    Names,         \* HTTP servers
    Faults,        \* environment faults allowed: SUBSET {"unreadable", "repair", "delete", "v1login"}
    InitKinds,     \* SUBSET {"absent", "ok", "unreadable"}
    InitEntries,   \* entries an initial document may hold
    InitImported,  \* SUBSET BOOLEAN: its flag, when there is a document
    InitMarked,    \* SUBSET BOOLEAN: whether the note is there at the start
    InitV1         \* v1's logins at the start may be any subset of these

Kinds == {"absent", "ok", "unreadable"}

VARIABLES
    kind,        \* the document: missing, readable, or unreadable
    entries,     \* what it holds (an unreadable one still holds it, for a reader that can read it)
    imported,    \* its imported_v1 flag
    marked,      \* the note beside it
    v1,          \* v1's logins (mcp_auth_store.zig), never changed by MCP-v2
    loggedOut,   \* ghost: names signed out of and not signed in to since
    kept,        \* ghost: names signed in to and not signed out of since
    undone,      \* ghost: an import brought back a login signed out of
    overwritten  \* ghost: an unreadable document was written over

vars == <<kind, entries, imported, marked, v1, loggedOut, kept, undone, overwritten>>

TypeOK ==
    /\ kind \in Kinds
    /\ entries \subseteq Names
    /\ imported \in BOOLEAN /\ marked \in BOOLEAN
    /\ v1 \subseteq Names
    /\ loggedOut \subseteq Names
    /\ kept \subseteq Names
    /\ undone \in BOOLEAN /\ overwritten \in BOOLEAN

Init ==
    /\ kind \in InitKinds
    /\ entries \in (IF kind = "absent" THEN {{}} ELSE SUBSET InitEntries)
    /\ imported \in (IF kind = "absent" THEN {FALSE} ELSE InitImported)
    /\ marked \in InitMarked
    /\ v1 \in SUBSET InitV1
    /\ loggedOut = {}
    /\ kept = entries
    /\ undone = FALSE /\ overwritten = FALSE

\* readSaved: what this fx reads.
Unread == kind = "unreadable"
SavedEntries == IF kind = "ok" THEN entries ELSE {}
\* read: whether v1's logins were taken over already, and what it takes now.
Copied == (kind = "ok" /\ imported) \/ marked
Imports == IF Copied THEN {} ELSE v1 \ SavedEntries
AfterRead == SavedEntries \cup Imports

\* Store.write of `e`, then the note; `fresh` is a name signed in to by this operation.
Write(e, fresh) ==
    /\ kind' = "ok"
    /\ entries' = e
    /\ imported' = TRUE
    /\ marked' = TRUE
    /\ undone' = (undone \/ ((Imports \cap loggedOut \cap e) \ {fresh}) # {})
    /\ overwritten' = (overwritten \/ Unread)

Same == UNCHANGED <<kind, entries, imported, marked, undone, overwritten>>

\* Only the note is written.
Mark ==
    /\ marked' = TRUE
    /\ UNCHANGED <<kind, entries, imported, undone, overwritten>>

\* What Store.read itself writes: the import, or a missing note.
ReadEffect ==
    IF Unread THEN Same
    ELSE IF ~Copied THEN Write(AfterRead, "")
    ELSE IF ~marked THEN Mark
    ELSE Same

\* Store.get, from config.resolve when a host starts. An unreadable document
\* gives no login and stays as it is.
Get ==
    /\ ReadEffect
    /\ UNCHANGED <<v1, loggedOut, kept>>

\* Store.put after a sign-in (or a refresh) of `n`. It fails on an
\* unreadable document, so the sign-in isn't saved.
Put(n) ==
    /\ ~Unread
    /\ Write(AfterRead \cup {n}, n)
    /\ loggedOut' = loggedOut \ {n}
    /\ kept' = kept \cup {n}
    /\ UNCHANGED v1

\* Store.remove on logout of `n`: written when it had `n`, else only what
\* the read writes. It fails on an unreadable document, so `n` stays.
Remove(n) ==
    /\ ~Unread
    /\ IF n \in AfterRead THEN Write(AfterRead \ {n}, "") ELSE ReadEffect
    /\ loggedOut' = loggedOut \cup {n}
    /\ kept' = kept \ {n}
    /\ UNCHANGED v1

\* Environment: the document stops being readable by this fx (a newer fx
\* wrote another version, a hand edit, a damaged file); what it holds stays.
Unreadable ==
    /\ "unreadable" \in Faults /\ kind = "ok"
    /\ kind' = "unreadable"
    /\ UNCHANGED <<entries, imported, marked, v1, loggedOut, kept, undone, overwritten>>

\* Environment: it is readable again (fixed by hand, or saved as version 1
\* again), holding what it held.
Repair ==
    /\ "repair" \in Faults /\ kind = "unreadable"
    /\ kind' = "ok"
    /\ UNCHANGED <<entries, imported, marked, v1, loggedOut, kept, undone, overwritten>>

\* Environment: the user deletes the document, and with it what it kept;
\* the note stays.
Delete ==
    /\ "delete" \in Faults /\ kind # "absent"
    /\ kind' = "absent" /\ entries' = {} /\ imported' = FALSE
    /\ kept' = {}
    /\ UNCHANGED <<marked, v1, loggedOut, undone, overwritten>>

\* Environment: a sign-in with the v1 engine (FX_MCP_ENGINE unset).
V1Login(n) ==
    /\ "v1login" \in Faults /\ n \notin v1
    /\ v1' = v1 \cup {n}
    /\ UNCHANGED <<kind, entries, imported, marked, loggedOut, kept, undone, overwritten>>

Next ==
    \/ Get
    \/ \E n \in Names : Put(n) \/ Remove(n) \/ V1Login(n)
    \/ Unreadable
    \/ Repair
    \/ Delete

Spec == Init /\ [][Next]_vars

\* ---- Safety ----

\* The import is once: after it, a read never adds v1's logins again.
ImportOnce == Copied => Imports = {}

\* What was signed in to, and not signed out of since, is kept.
SignedInKept == kind = "ok" => kept \subseteq entries

\* A login signed out of stays out of a readable document until the next
\* sign-in.
LogoutStays == kind = "ok" => loggedOut \cap entries = {}

\* A logout is never undone by an import, even after the document is deleted.
NoLogoutUndoneByImport == ~undone

\* An unreadable document is never written over.
UnreadableNeverOverwritten == ~overwritten
====
