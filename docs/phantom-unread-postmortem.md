# The Phantom Unread Badge: Postmortem and Fix Series

*Status: fixes shipped and live-validated 2026-09-05 (desktop v0.5.22-d9d36f9d).
This document is the durable record: why the badge lied, what we changed, how
to validate it, and where to pick up for upstream submission or future
debugging.*

## 1. The symptom

A community-switcher badge (dot or mention count) that will not clear. The
user reads everything, sits in the community, uses "mark all as read" — the
badge returns. The Home inbox is empty; no channel shows unread. The badge
counts messages **no surface in the app can display**, so there is nothing to
click and no way out. It recurred four times between 2026-08-22 and
2026-09-05, each time with a subtly different root cause in the same
subsystem.

## 2. Architecture background (NIP-RS read state)

- Read state is an encrypted addressable event (kind 30078, `#t=read-state`,
  NIP-44 to self) holding a `contexts` map: context id → unix-seconds marker.
- Context kinds: channel ids, `thread:<root>` aggregates, and per-message
  `msg:<event-id>` markers (spec: `docs/nips/NIP-RS.md`).
- Read predicate folds hierarchically: a reply is read iff
  `max(msg:<id>, thread:<root>, channel) >= created_at`. Ties count as read.
- The published blob has a **32 KB per-slot plaintext budget**
  (`READ_STATE_MAX_PLAINTEXT_BYTES`); `thread:`/`msg:` markers live only in
  slot 0 and only slot 0 is trimmed. The relay accepts 512 KB — the budget is
  client policy for NIP-44 headroom.
- Desktop surfaces split their sources: the **community-switcher badge** for
  inactive communities polls **relay-published state only**
  (`communityUnreadObserver.ts`), while the channel rail and Home inbox read
  the **local** `ReadStateManager.effectiveState`.

## 3. Root-cause history (four occurrences)

| # | Date | Root cause |
|---|------|-----------|
| 1–2 | Aug 22–27 | Silent native unread-catch-up failure: cold-start catch-up raced the socket's NIP-42 AUTH (timer armed before readiness), 0-of-N delivery, error paths swallowed and claims leaked. Badges were *truthful* but the causing messages were invisible. Fixed Aug 27 (`f8c678d73` readiness barrier, `16ff1e984` retry/backoff + authoritative rail mark-all-read). |
| 3 | Sep 3 | Publish-side byte-budget eviction ordered by **marker value**: an old-valued `msg:` marker that was the *sole cover* for a thread reply was evicted on every publish, forever. Fixed by re-keying eviction on read-action recency and adding thread-open `thread:` advancement (`89c78c5ca` et al.). |
| 4 | Sep 5 | **Legacy fallout**: threads fully read *before* the Sep-3 fix have no `thread:` aggregate — covered only by evictable `msg:` markers. Recency eviction merely slowed the fuse: once ~400 newer read actions accumulated, the load-bearing markers aged out of the 32 KB budget and the badge re-lit. The trigger profile: 965 local contexts, 851 of them `msg:`, ~412 fitting the published blob. |

The occurrence-4 diagnosis in one line: **the badge read relay state, relay
state was missing markers the local state held, and nothing in the app could
show or clear the difference.** Three interacting defects:

1. Load-bearing `msg:` markers evicted from the published blob (no
   dominated-marker GC meant inert markers crowded the budget).
2. A legacy tail of thread reads with no durable `thread:` aggregate.
3. Badge (relay view) vs. inbox/rail (local view) divergence with no recovery
   affordance — the observer returned only `{hasUnread, mentionCount}`,
   discarding *which* events it counted.

A fourth, latent defect surfaced during the mobile audit: on NIP-44 blob
overflow, mobile set a terminal `_remoteUnsupported` flag — **silently
disabling cross-device read-state sync for the session**, no retry, no signal.
Every mobile profile was headed there as `msg:` markers accumulated.

## 4. The fix series (fork main `c76f1f18d..d9d36f9d9`)

Six commits, each independently testable; ordered by urgency-to-risk:

### A. `b72ba03cb` — fold local read state into the community unread observer
A device must never badge an event it locally knows is read. The observer now
max-merges local storage (advance-only superset of relay state) over the
relay-published view before every consult point. Read-only, per-device,
cannot regress other devices. *This is the immediate kill of the phantom
class on the device that did the reading.*

### B. `96ad5f985` — dominated-marker GC on the publish path
NIP-RS permits dropping `msg:`/`thread:` entries covered by their parent
frontier ("Dominated entries"); Buzz never did. Parent coordinates
(channel, thread root) are recorded at mark time into a persisted map
(`buzz.channel-read-state.parents.v1:<pubkey>`) because the publish path has
no event-graph access. `dropDominatedContexts` runs **before** the byte trim.
Safety invariants (each has a dedicated test):
- Domination is judged **only against the outgoing blob**, never wider local
  state (a local-only value other devices never saw must not justify dropping
  a marker they depend on).
- Unmapped contexts are never dropped (the parent map is best-effort).
- Channel keys are never dropped. Split mode GCs against the cross-slot union
  (readers max-merge all slots).
- Trap documented in-code: the manager's `parentResolver` maps every context
  to the *active* channel and must never feed the GC.

### C. `8452dd4e6` — backfill `thread:` aggregates from legacy `msg:` markers
The drain for the legacy tail and the ongoing safety net. For every
unaccounted `msg:` context on the active community: resolve the event
(batches ≤100, 3 attempts then terminal `unresolvable`), record parents, and
for thread replies fetch the **complete** reply set (paged-to-exhaustion or
throw — never advance over a partial tree), compute the maximal safe boundary
with the same `computeThreadReadBoundary` the thread panel uses, and advance
`thread:` grow-only. Persisted done-store
(`buzz.thread-backfill.v1:<relayUrl>:<pubkey>`) makes runs resumable; pacing
is one bounded pass per minute (≤3 roots each), exponential backoff on relay
failure, terminal for the session when exhausted. **Healing is deliberately
gradual** — expect minutes-to-an-hour on a large legacy profile.

### D. `648480039` — surface the events behind the badge
The observer now retains bounded per-event detail (channel, id, createdAt,
root, mention flag) and each poll persists it into the community relay's
observed-unread projection cache. On activation, the existing sidebar badges
and activity popover display those exact events with working mark-read.
Mention detail is complete (the numeric badge *is* the mention count);
dot-only detail can be partial (the existence fetch short-circuits), with
rail mark-all-read as the blunt recovery. Product contract restored: the
inbox always shows what is unread and lets you mark it read.

### E1. `961b2797f` — mobile thread page advances `thread:` aggregates
Desktop-parity port of `computeThreadReadBoundary` to Dart
(`mobile/lib/shared/read_state/thread_read_boundary.dart` — keep in sync with
the TS original). Advances over the FULL subtree of the outermost root, gated
on the exhaustively-paged relay query, grow-only. Widget tests bind the page
seam through the channel-detail harness.

### E2. `d9d36f9d9` — mobile publish GC + trim; overflow made non-terminal
Ports B's GC/trim to Dart (`read_state_gc.dart`), records parents at the
thread page's mark sites, and replaces the silent permanent sync-disable
with skip-this-cycle-and-retry. The manager test that pinned the old
disable behavior now proves an msg-heavy state publishes after GC.

## 5. Validation protocol (how we proved it)

The live repro (the "2" badge on buzz.relay.tools: two Testoor replies of
Sep 1 under root `d3c9bc32…`, read locally, cover evicted from the published
blob) was **deliberately preserved as the test fixture** — no manual
thread-open, no manual relay writes.

1. **Offline observer emulation** (`buzz-observer-replay.sh <relay-url>`,
   home-dir tooling; replicates `fetchCommunityUnread` relay-only): baseline
   showed exactly the badge's 2 candidates.
2. **Install fix build → launch**: badge gone within one poll (~30 s),
   thread untouched. Proves A (local fold) on-device.
3. **Relay-side heal**: replay again after the backfill has run. Progression
   observed: published thread markers 73 → 76, msg markers shrinking under
   GC; the affected root's `thread:` aggregate publishes when its batch is
   reached. End state: replay reports 0 candidates → the badge class is
   unrepresentable for every reader, mobile included.
4. Full gates: in-cluster `just ci` (all Rust + 6302 desktop JS + 2125
   Flutter tests) on every commit; each regression test demonstrated to fail
   on pre-fix code (falsifiability controls included in-suite).

## 6. Debugging a future phantom badge (runbook)

1. `buzz-observer-replay.sh wss://<relay>` — is the badge truthful
   relay-side? Which channel/events?
2. `buzz-unread-inspect.sh` — what do the LOCAL stores say (native
   observed-unread.db + localStorage v2)? Phantom = relay says unread, local
   says read.
3. Decrypt the published blob (kind 30078 `#t=read-state`, nip44-to-self) and
   check coverage of the specific events: `max(msg:, thread:root, channel)`
   vs `created_at`. Absent cover that exists locally ⇒ eviction/publish
   problem; absent everywhere ⇒ read-tracking problem.
4. Check the parent map and backfill store in localStorage
   (`buzz.channel-read-state.parents.v1`, `buzz.thread-backfill.v1`) — an
   unmapped, undominated `msg:` marker for an unresolvable event will pend
   3 attempts then go terminal.
5. Desktop debug builds (`buzz-desktop-debug`) have the WebKit inspector;
   `[ReadStateManager]` logs show GC drops, trim evictions ("trimmed N
   entries" should be rare-to-never now — its reappearance means budget
   pressure the GC could not relieve), and backfill progress.

## 7. Follow-ups / open threads

- **Multi-slot sharding on mobile** (desktop has 8 slots; mobile is
  single-slot) — only needed past ~650 channels; deferred.
- **`ov_*` override layer** (NIP-RS durable manual-unread) — unimplemented on
  both platforms; session-local forced-unread stands in.
- **Dot-only observer detail is partial** by design (existence fetch
  short-circuits); if a "show me everything behind the dot" affordance is
  wanted, the short-circuit must be removed at the cost of extra fetches.
- **Spec**: NIP-RS.md already documents recency-keyed eviction and permits
  dominated-entry GC; consider adding a normative note that evicting a
  NON-dominated entry is a correctness hazard mitigated only by aggregation
  (the thread-boundary mechanism) — that is the lesson of occurrence 4.
- **Upstream submission**: the six commits are self-contained against
  `block/buzz` main and ordered for review (A and B are independent; C
  depends on B; D on A; E1/E2 are mobile parity). The falsifiability-control
  test pattern (same fixture, fold disabled, asserts the bug) is worth
  calling out in the PR description.

## 8. Related incident: build-infra disk pressure (same day)

Validation was delayed by kubelet ephemeral-storage evictions on the CI node
(threshold: 300 GB available ≈ 15% of the 2 TB volume; kubelet "available"
excludes ~100 GB root-reserved blocks, so `df` overstates margin by ~100 GB).
Root cause of the pressure: a runaway `git/cache/` in one newlay feed relay
(325 GB, ~30 GB/day, no eviction — actual event DB was 1 GB), plus ~270 GB of
buildkit caches. The same class of bug we fixed in Buzz — an unbounded
accumulation path — living in the infrastructure. Bounding that cache in
newlay is tracked separately.
