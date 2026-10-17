---- MODULE Catalog ----
\* U05 tool catalog, client side, one server. Rules: CAT-01..CAT-05, CAT-11,
\* MRTR-07.
\*
\* The host needs the server's tool list (a model turn is starting). A fresh
\* cached list is served at once. Otherwise one listing runs, page by page,
\* and everyone who needed the list meanwhile gets its result. The list is
\* cached as one unit: it is fresh only if no invalidation happened
\* since the listing started, and, on a modern server, if no page had a
\* zero TTL. A modern list also goes stale when its TTL runs out. A legacy
\* list stays fresh until an invalidation or a new process.
\*
\* Pages are bounded: a listing stops after MaxPages pages, and an
\* invalid cursor restarts it from the beginning once. Failed listings never
\* touch the cache. Tool contents (validity, duplicate names) are data,
\* checked by the Zig tests, not here.
EXTENDS Naturals

CONSTANTS
    MaxPages,      \* pages per listing (100 in fx)
    MaxGen,        \* invalidations, bounds the state space
    MaxProcesses

ASSUME MaxPages \in Nat \ {0} /\ MaxGen \in Nat /\ MaxProcesses \in Nat \ {0}

VARIABLES
    era,           \* the current process's era: "none" before the first, "modern", "legacy"
    process,       \* the server process generation
    gen,           \* invalidation generation (list_changed, call errors, new process)
    cache,         \* the current list: "none", "fresh", or "stale"
    cacheGen,      \* the generation the current list was listed under
    cachedZero,    \* the current list had a page with a zero TTL
    listing,       \* "idle" or "fetching"
    startGen,      \* gen when the running listing started (or restarted)
    page,          \* pages received in the running listing
    restarts,      \* restarts of the running listing after an invalid cursor
    zeroTtl,       \* a page of the running listing had a zero TTL
    pending,       \* the page request in flight: "none", "first", or "next"
    waiting,       \* someone is waiting for the running listing
    \* Ghost variables for the safety properties.
    servedStale,   \* a need was served from a list that wasn't fresh and current
    extraFetch     \* a listing started while one was running

vars == <<era, process, gen, cache, cacheGen, cachedZero, listing, startGen, page,
          restarts, zeroTtl, pending, waiting, servedStale, extraFetch>>

listingVars == <<listing, startGen, page, restarts, zeroTtl, pending, waiting>>

Init ==
    /\ era = "none"
    /\ process = 0
    /\ gen = 0
    /\ cache = "none"
    /\ cacheGen = 0
    /\ cachedZero = FALSE
    /\ listing = "idle"
    /\ startGen = 0
    /\ page = 0
    /\ restarts = 0
    /\ zeroTtl = FALSE
    /\ pending = "none"
    /\ waiting = FALSE
    /\ servedStale = FALSE
    /\ extraFetch = FALSE

\* Mark the current list stale and move to a new generation.
Invalidated ==
    /\ gen' = gen + 1
    /\ cache' = IF cache = "fresh" THEN "stale" ELSE cache

\* Environment: a server process starts, after era detection (U04). The
\* previous process's requests already ended as lost (U03), so no listing
\* is running. A new process may be a new server version.
ProcessStarted(e) ==
    /\ process < MaxProcesses
    /\ gen < MaxGen
    /\ listing = "idle"
    /\ process' = process + 1
    /\ era' = e
    /\ Invalidated
    /\ UNCHANGED <<cacheGen, cachedZero, listingVars, servedStale, extraFetch>>

StartListing ==
    /\ listing' = "fetching"
    /\ startGen' = gen
    /\ page' = 0
    /\ restarts' = 0
    /\ zeroTtl' = FALSE
    /\ pending' = "first"
    /\ waiting' = TRUE

\* The host needs the tool list.
Need ==
    /\ era # "none"
    /\ IF listing = "fetching"
          THEN /\ waiting' = TRUE
               /\ UNCHANGED <<listing, startGen, page, restarts, zeroTtl, pending, servedStale, extraFetch>>
       ELSE IF cache = "fresh"
          THEN /\ servedStale' = (servedStale \/ cacheGen # gen)
               /\ UNCHANGED <<listingVars, extraFetch>>
       ELSE /\ StartListing
            /\ extraFetch' = (extraFetch \/ listing = "fetching")
            /\ UNCHANGED servedStale
    /\ UNCHANGED <<era, process, gen, cache, cacheGen, cachedZero>>

\* The listing ends with a list, delivered to everyone waiting. It is cached
\* as fresh only if nothing was invalidated since it started and, on a
\* modern server, no page had a zero TTL (CAT-04).
Finish(z) ==
    /\ listing' = "idle"
    /\ pending' = "none"
    /\ waiting' = FALSE
    /\ cache' = IF startGen = gen /\ (era = "legacy" \/ ~z) THEN "fresh" ELSE "stale"
    /\ cacheGen' = startGen
    /\ cachedZero' = z
    /\ UNCHANGED <<startGen, restarts>>

\* A complete page. `more`: it has a nextCursor (an empty string is a
\* cursor, CAT-01). `ttlZero`: its ttlMs is 0, absent, or negative (CAT-04).
PageReceived(more, ttlZero) ==
    /\ pending # "none"
    /\ LET p == page + 1
           z == zeroTtl \/ ttlZero
       IN IF more /\ p < MaxPages
             THEN /\ page' = p /\ zeroTtl' = z /\ pending' = "next"
                  /\ UNCHANGED <<listing, startGen, restarts, waiting, cache, cacheGen, cachedZero>>
          ELSE /\ page' = p /\ zeroTtl' = z
               /\ Finish(z)
    /\ UNCHANGED <<era, process, gen, servedStale, extraFetch>>

\* -32602 for a continuation page: drop the pages so far and list again from
\* the beginning, once (CAT-02).
InvalidCursor ==
    /\ pending = "next"
    /\ IF restarts = 0
          THEN /\ restarts' = 1
               /\ startGen' = gen
               /\ page' = 0
               /\ zeroTtl' = FALSE
               /\ pending' = "first"
               /\ UNCHANGED <<listing, waiting>>
          ELSE /\ listing' = "idle" /\ pending' = "none" /\ waiting' = FALSE
               /\ UNCHANGED <<startGen, page, restarts, zeroTtl>>
    /\ UNCHANGED <<era, process, gen, cache, cacheGen, cachedZero, servedStale, extraFetch>>

\* Any other end of a page request: an error (including -32602 on the first
\* page), input_required (MRTR-07: never cached), a malformed result, a
\* timeout, or a lost connection. Everyone waiting gets the failure; the
\* cache is untouched (never serve stale on error, never cache it).
PageFailed ==
    /\ pending # "none"
    /\ listing' = "idle"
    /\ pending' = "none"
    /\ waiting' = FALSE
    /\ UNCHANGED <<era, process, gen, cache, cacheGen, cachedZero, startGen, page,
                   restarts, zeroTtl, servedStale, extraFetch>>

\* list_changed, a tools/call answered -32601 or -32602, or the
\* host. The list goes stale at once (CAT-05).
Invalidate ==
    /\ gen < MaxGen
    /\ Invalidated
    /\ UNCHANGED <<era, process, cacheGen, cachedZero, listingVars, servedStale, extraFetch>>

\* A modern list's TTL ran out (CAT-04). Legacy lists have no TTL.
Expired ==
    /\ cache = "fresh"
    /\ era = "modern"
    /\ cache' = "stale"
    /\ UNCHANGED <<era, process, gen, cacheGen, cachedZero, listingVars, servedStale, extraFetch>>

Answer == (\E m, z \in BOOLEAN : PageReceived(m, z)) \/ InvalidCursor \/ PageFailed

Next ==
    \/ \E e \in {"modern", "legacy"} : ProcessStarted(e)
    \/ Need
    \/ Answer
    \/ Invalidate
    \/ Expired

\* Every page request ends (U02 EveryRequestEnds), so the server's answers are
\* weakly fair.
Spec == Init /\ [][Next]_vars /\ WF_vars(Answer)

TypeOK ==
    /\ era \in {"none", "modern", "legacy"}
    /\ process \in 0..MaxProcesses
    /\ gen \in 0..MaxGen
    /\ cache \in {"none", "fresh", "stale"}
    /\ cacheGen \in 0..MaxGen
    /\ cachedZero \in BOOLEAN
    /\ listing \in {"idle", "fetching"}
    /\ startGen \in 0..MaxGen
    /\ page \in 0..MaxPages
    /\ restarts \in 0..1
    /\ zeroTtl \in BOOLEAN
    /\ pending \in {"none", "first", "next"}
    /\ waiting \in BOOLEAN
    /\ servedStale \in BOOLEAN
    /\ extraFetch \in BOOLEAN

\* A fresh list was listed in the current generation: no answer from before
\* an invalidation is ever cached as fresh.
CacheCurrent == cache = "fresh" => cacheGen = gen

\* A need is served from the cache only when the list is fresh and current.
NoStaleServe == ~servedStale

\* On a modern server, a list with a zero-TTL page is never cached (CAT-04).
ZeroTtlNotCached == (cache = "fresh" /\ era = "modern") => ~cachedZero

\* At most one listing at a time; later needs join it.
OneListing == ~extraFetch

\* A listing never asks for more than MaxPages pages.
PagesBounded == page <= MaxPages /\ (pending # "none" => page < MaxPages)

\* A listing runs only while someone waits for it, and waiting implies a listing.
WaitingMeansListing == waiting <=> listing = "fetching"

\* Everyone who needs the list gets an answer.
EveryNeedAnswered == waiting ~> ~waiting
====
