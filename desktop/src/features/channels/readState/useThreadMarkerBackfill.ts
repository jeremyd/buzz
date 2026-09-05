import * as React from "react";
import { useQueryClient } from "@tanstack/react-query";

import { mutedStore } from "@/features/channels/unreadMembership";
import { DM_NOTIFIABLE_EVENT_KINDS } from "@/features/channels/isDmNotifiableKind";
import {
  type ContextParent,
  MSG_PREFIX,
  THREAD_PREFIX,
} from "@/features/channels/readState/readStateFormat";
import {
  type BackfillDeps,
  runThreadMarkerBackfillOnce,
} from "@/features/channels/readState/threadMarkerBackfill";
import { loadThreadReplies } from "@/features/messages/useThreadReplies";
import type { RelayClient } from "@/shared/api/relayClientSession";
import { CHANNEL_MESSAGE_EVENT_KINDS } from "@/shared/constants/kinds";

export const BACKFILL_INITIAL_DELAY_MS = 30_000;
export const BACKFILL_RUN_INTERVAL_MS = 60_000;
export const BACKFILL_MAX_BACKOFF_MS = 15 * 60_000;

// A msg: marker can cover any timeline content kind, DMs included.
const RESOLVE_KINDS = [
  ...new Set([...CHANNEL_MESSAGE_EVENT_KINDS, ...DM_NOTIFIABLE_EVENT_KINDS]),
];

/**
 * Idle-scheduled driver for the thread-marker backfill (see
 * threadMarkerBackfill.ts). Runs against the ACTIVE community's relay only —
 * msg ids from other communities resolve when those communities are active.
 *
 * Rule-4 shape: first run ~30 s after read state is ready, one bounded pass
 * per minute while candidates remain, exponential backoff (capped) on relay
 * failure, and a terminal stop once the candidate set is exhausted for this
 * session. Community switch or teardown cancels the timer.
 */
export function useThreadMarkerBackfill(args: {
  enabled: boolean;
  pubkey: string | undefined;
  relayUrl: string;
  relayClient: RelayClient | undefined;
  listOwnContexts: (prefix: string) => Array<[string, number]>;
  getOwnTimestamp: (contextId: string) => number | null;
  markContextRead: (
    contextId: string,
    unixTimestamp: number,
    parent?: ContextParent,
  ) => void;
  recordContextParent: (contextId: string, parent: ContextParent) => void;
}): void {
  const {
    enabled,
    pubkey,
    relayUrl,
    relayClient,
    listOwnContexts,
    getOwnTimestamp,
    markContextRead,
    recordContextParent,
  } = args;
  const queryClient = useQueryClient();

  React.useEffect(() => {
    if (!enabled || !pubkey || !relayClient || !relayUrl) return;

    let cancelled = false;
    let timer: number | null = null;
    let backoff = BACKFILL_RUN_INTERVAL_MS;

    const deps: BackfillDeps = {
      relayUrl,
      pubkey,
      listOwnMsgContexts: () => listOwnContexts(MSG_PREFIX),
      fetchEventsByIds: (ids) =>
        relayClient.fetchEvents({
          ids,
          kinds: RESOLVE_KINDS,
          limit: ids.length,
        }),
      loadReplies: (channelId, rootId) =>
        loadThreadReplies(queryClient, channelId, rootId),
      getOwnTimestamp,
      markThreadRead: (rootId, boundary, channelId) =>
        markContextRead(`${THREAD_PREFIX}${rootId}`, boundary, {
          c: channelId,
          r: null,
        }),
      recordContextParent,
      isRootMuted: (rootId) => mutedStore.read(pubkey).has(rootId),
      currentPubkey: pubkey,
    };

    const schedule = (delayMs: number) => {
      timer = window.setTimeout(() => {
        timer = null;
        void run();
      }, delayMs);
    };

    const run = async () => {
      try {
        const result = await runThreadMarkerBackfillOnce(deps);
        if (cancelled) return;
        backoff = BACKFILL_RUN_INTERVAL_MS;
        if (!result.exhausted) {
          schedule(BACKFILL_RUN_INTERVAL_MS);
        }
        // Exhausted → terminal for this session; the next session re-checks.
      } catch (error) {
        if (cancelled) return;
        console.warn("[ThreadMarkerBackfill] run failed; backing off:", error);
        backoff = Math.min(backoff * 2, BACKFILL_MAX_BACKOFF_MS);
        schedule(backoff);
      }
    };

    schedule(BACKFILL_INITIAL_DELAY_MS);
    return () => {
      cancelled = true;
      if (timer !== null) window.clearTimeout(timer);
    };
  }, [
    enabled,
    pubkey,
    relayUrl,
    relayClient,
    queryClient,
    listOwnContexts,
    getOwnTimestamp,
    markContextRead,
    recordContextParent,
  ]);
}
