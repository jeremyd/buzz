import {
  readObservedUnreadFromStorage,
  writeObservedUnreadToStorage,
} from "@/features/channels/observedUnreadStorage";
import {
  type ObservedUnreadEvent,
  makeObservedUnreadEvent,
} from "@/features/channels/unreadChannelCounts";
import type { CommunityUnreadEventDetail } from "@/features/communities/communityUnreadObserver";
import { normalizeRelayUrl } from "@/features/profile/lib/selfProfileStorage";

/**
 * Persist the observer's unread detail into the community relay's
 * observed-unread projection cache, so the events behind a badge are visible
 * and clearable in-app the moment the community is activated (sidebar badges,
 * activity popover — both already read this cache and mark-read against NIP-RS
 * markers). The cache is explicitly not a source of truth: a stale entry
 * self-heals when the projection re-evaluates against markers.
 *
 * Merge-only: existing observed events are kept (the storage layer prunes by
 * age and caps), and an id seen by both keeps the higher-priority flag.
 */
export function persistObserverUnreadDetail(
  pubkey: string,
  communityRelayUrl: string,
  unreadEvents: CommunityUnreadEventDetail[],
): void {
  if (unreadEvents.length === 0) return;
  const relayUrl = normalizeRelayUrl(communityRelayUrl);
  const existing =
    readObservedUnreadFromStorage(pubkey, relayUrl) ??
    new Map<string, Map<string, ObservedUnreadEvent>>();

  for (const detail of unreadEvents) {
    const observed = makeObservedUnreadEvent({
      id: detail.id,
      createdAt: detail.createdAt,
      rootId: detail.rootId,
      highPriority: detail.mention,
      channelType: detail.channelType,
      isThreadedReply: detail.rootId !== null,
    });
    const channelEvents =
      existing.get(detail.channelId) ?? new Map<string, ObservedUnreadEvent>();
    const current = channelEvents.get(detail.id);
    if (!current || (!current.highPriority && observed.highPriority)) {
      channelEvents.set(detail.id, observed);
    }
    existing.set(detail.channelId, channelEvents);
  }

  writeObservedUnreadToStorage(pubkey, relayUrl, existing);
}
