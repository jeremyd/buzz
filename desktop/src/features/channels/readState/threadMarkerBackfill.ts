import { computeThreadReadBoundary } from "@/features/channels/lib/threadReadBoundary";
import {
  type ContextParent,
  MSG_PREFIX,
  THREAD_PREFIX,
  isMsgContextKey,
  maxReadAt,
} from "@/features/channels/readState/readStateFormat";
import { getThreadReference } from "@/features/messages/lib/threading";
import type { RelayEvent } from "@/shared/api/types";

/**
 * Thread-marker backfill: aggregate legacy `msg:` read markers into durable
 * `thread:` markers.
 *
 * Threads fully read before the thread-open boundary-advance shipped have no
 * `thread:` aggregate — their replies are covered only by per-message `msg:`
 * markers, which the publish path may evict under byte-budget pressure. Every
 * eviction of such a load-bearing marker resurrects its reply as unread on
 * every relay-state reader (the phantom community badge). This module drains
 * that tail: resolve each unaccounted `msg:` context to its channel/root,
 * record parent coordinates for the dominated-marker GC, and — for thread
 * replies — recompute the maximal safe `thread:` boundary from the COMPLETE
 * reply set and advance it grow-only.
 *
 * Bounded and resumable by construction: per-message terminal states persist
 * in localStorage (`done` / `unresolvable` after MAX_RESOLVE_ATTEMPTS), at
 * most RESOLVE_BATCH ids are fetched and ROOTS_PER_RUN roots aggregated per
 * run, and a run that cannot fetch a complete reply set writes nothing for
 * that root and leaves it pending (never advance over a partial tree).
 */

export const BACKFILL_STORE_VERSION = 1;
export const BACKFILL_MAX_TRACKED = 5_000;
export const BACKFILL_MAX_RESOLVE_ATTEMPTS = 3;
export const BACKFILL_RESOLVE_BATCH = 100;
export const BACKFILL_ROOTS_PER_RUN = 3;

/** `done`/`unresolvable` are terminal; a number is resolve attempts so far. */
export type BackfillEntryState = "done" | "unresolvable" | number;

export interface BackfillStore {
  v: typeof BACKFILL_STORE_VERSION;
  msgs: Record<string, BackfillEntryState>;
}

export function backfillStoreKey(relayUrl: string, pubkey: string): string {
  return `buzz.thread-backfill.v1:${relayUrl}:${pubkey}`;
}

export function readBackfillStore(
  relayUrl: string,
  pubkey: string,
): BackfillStore {
  try {
    const raw = window.localStorage.getItem(backfillStoreKey(relayUrl, pubkey));
    if (!raw) return { v: BACKFILL_STORE_VERSION, msgs: {} };
    const parsed = JSON.parse(raw);
    if (
      typeof parsed !== "object" ||
      parsed === null ||
      parsed.v !== BACKFILL_STORE_VERSION ||
      typeof parsed.msgs !== "object" ||
      parsed.msgs === null
    ) {
      return { v: BACKFILL_STORE_VERSION, msgs: {} };
    }
    const msgs: Record<string, BackfillEntryState> = {};
    for (const [id, state] of Object.entries(parsed.msgs)) {
      if (
        state === "done" ||
        state === "unresolvable" ||
        (typeof state === "number" && Number.isInteger(state) && state >= 0)
      ) {
        msgs[id] = state;
      }
    }
    return { v: BACKFILL_STORE_VERSION, msgs };
  } catch {
    return { v: BACKFILL_STORE_VERSION, msgs: {} };
  }
}

export function writeBackfillStore(
  relayUrl: string,
  pubkey: string,
  store: BackfillStore,
): void {
  // Cap by dropping the OLDEST entries (JSON object insertion order). A
  // dropped `done` entry only costs a redundant refetch-and-no-op later.
  const entries = Object.entries(store.msgs);
  const bounded =
    entries.length > BACKFILL_MAX_TRACKED
      ? Object.fromEntries(entries.slice(entries.length - BACKFILL_MAX_TRACKED))
      : store.msgs;
  try {
    window.localStorage.setItem(
      backfillStoreKey(relayUrl, pubkey),
      JSON.stringify({ v: BACKFILL_STORE_VERSION, msgs: bounded }),
    );
  } catch {
    // Quota exhaustion loses only resumability bookkeeping, never markers.
  }
}

export interface BackfillRunResult {
  /** Thread roots whose `thread:` marker this run advanced. */
  advanced: number;
  /** True when no pending candidates remain — the caller can stop scheduling. */
  exhausted: boolean;
}

export interface BackfillDeps {
  relayUrl: string;
  pubkey: string;
  /** Own `msg:` contexts as [contextId, markerTimestamp]. */
  listOwnMsgContexts(): Array<[string, number]>;
  /** Fetch full events for the given ids (relay `ids` filter). */
  fetchEventsByIds(ids: string[]): Promise<RelayEvent[]>;
  /**
   * Fetch the COMPLETE reply set for a root (exhaustively paged; must throw
   * rather than return a partial set).
   */
  loadReplies(channelId: string, rootId: string): Promise<RelayEvent[]>;
  getOwnTimestamp(contextId: string): number | null;
  markThreadRead(rootId: string, boundary: number, channelId: string): void;
  recordContextParent(contextId: string, parent: ContextParent): void;
  isRootMuted(rootId: string): boolean;
  currentPubkey: string;
}

function tagValue(event: RelayEvent, name: string): string | null {
  return event.tags.find((tag) => tag[0] === name)?.[1] ?? null;
}

/**
 * One bounded backfill pass. Throws on relay failure (callers back off and
 * retry — a failed root stays pending, per the no-partial-advance rule).
 */
export async function runThreadMarkerBackfillOnce(
  deps: BackfillDeps,
): Promise<BackfillRunResult> {
  const store = readBackfillStore(deps.relayUrl, deps.pubkey);

  const pendingIds: string[] = [];
  for (const [contextId] of deps.listOwnMsgContexts()) {
    if (!isMsgContextKey(contextId)) continue;
    const id = contextId.slice(MSG_PREFIX.length);
    const state = store.msgs[id];
    if (state === "done" || state === "unresolvable") continue;
    pendingIds.push(id);
  }

  if (pendingIds.length === 0) {
    return { advanced: 0, exhausted: true };
  }

  const batch = pendingIds.slice(0, BACKFILL_RESOLVE_BATCH);
  const events = await deps.fetchEventsByIds(batch);
  const byId = new Map(events.map((event) => [event.id, event]));

  // Group resolved thread replies by root; resolve terminal states for the
  // rest. Parent coordinates are recorded for every resolved event so the
  // publish-path GC can judge domination even before roots are aggregated.
  const rootGroups = new Map<
    string,
    { channelId: string; memberIds: string[] }
  >();
  for (const id of batch) {
    const event = byId.get(id);
    if (!event) {
      const prior = store.msgs[id];
      const attempts = (typeof prior === "number" ? prior : 0) + 1;
      store.msgs[id] =
        attempts >= BACKFILL_MAX_RESOLVE_ATTEMPTS ? "unresolvable" : attempts;
      continue;
    }
    const channelId = tagValue(event, "h");
    if (!channelId) {
      // No channel scope — nothing to aggregate against; terminal.
      store.msgs[id] = "unresolvable";
      continue;
    }
    const { rootId } = getThreadReference(event.tags);
    deps.recordContextParent(`${MSG_PREFIX}${id}`, {
      c: channelId,
      r: rootId ?? null,
    });
    if (rootId === null) {
      // Top-level message: the channel marker is its only parent frontier —
      // parent recorded, nothing to aggregate.
      store.msgs[id] = "done";
      continue;
    }
    const group = rootGroups.get(rootId) ?? { channelId, memberIds: [] };
    group.memberIds.push(id);
    rootGroups.set(rootId, group);
  }

  let advanced = 0;
  let processedRoots = 0;
  try {
    for (const [rootId, group] of rootGroups) {
      if (processedRoots >= BACKFILL_ROOTS_PER_RUN) break;
      processedRoots++;

      if (deps.isRootMuted(rootId)) {
        // Muted: never advance, but the members are accounted for — terminal.
        for (const id of group.memberIds) store.msgs[id] = "done";
        continue;
      }

      // The e-tag root may itself be a nested reply (legacy fallback
      // threading). Resolve the TRUE root before aggregating — a `thread:`
      // marker on a nested id would never be consulted by the readers' fold.
      let trueRoot = rootId;
      const rootEvent =
        byId.get(rootId) ?? (await deps.fetchEventsByIds([rootId]))[0];
      if (rootEvent) {
        trueRoot = getThreadReference(rootEvent.tags).rootId ?? rootId;
      }

      const replies = await deps.loadReplies(group.channelId, trueRoot);
      const boundary = computeThreadReadBoundary({
        replies: replies
          .filter((event) => event.id !== trueRoot)
          .map((event) => ({
            id: event.id,
            createdAt: event.created_at,
            pubkey: event.pubkey,
          })),
        getReadAt: (messageId) =>
          maxReadAt(
            deps.getOwnTimestamp(`${MSG_PREFIX}${messageId}`),
            deps.getOwnTimestamp(`${THREAD_PREFIX}${trueRoot}`),
            deps.getOwnTimestamp(group.channelId),
          ),
        currentPubkey: deps.currentPubkey,
      });

      if (boundary !== null) {
        const effective =
          maxReadAt(
            deps.getOwnTimestamp(`${THREAD_PREFIX}${trueRoot}`),
            deps.getOwnTimestamp(group.channelId),
          ) ?? 0;
        if (boundary > effective) {
          deps.markThreadRead(trueRoot, boundary, group.channelId);
          advanced++;
        }
      }
      // Success only: a thrown loadReplies above leaves members pending.
      for (const id of group.memberIds) store.msgs[id] = "done";
    }
  } finally {
    // Persist terminal states recorded before any mid-run throw — losing them
    // only costs redundant refetches, but there is no reason to pay that.
    writeBackfillStore(deps.relayUrl, deps.pubkey, store);
  }

  const remaining = pendingIds.filter((id) => {
    const state = store.msgs[id];
    return state !== "done" && state !== "unresolvable";
  });
  return { advanced, exhausted: remaining.length === 0 };
}
