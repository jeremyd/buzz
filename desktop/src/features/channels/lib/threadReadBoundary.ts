import type { TimelineMessage } from "@/features/messages/types";

/**
 * Maximal safe `thread:<root>` frontier for a COMPLETE reply set: the largest
 * T such that every reply with createdAt <= T is read. All replies read (or
 * self-authored) -> max reply createdAt; otherwise min(unread createdAt) - 1,
 * so msg: markers keep covering read replies newer than the first unread one
 * and a collapsed unread branch stays unread (LP4 v3).
 *
 * The read predicate is the exact inverse of computeThreadUnreadMarker's:
 * self-authored OR (not forced-unread AND createdAt <= readAt). Ties count as
 * read everywhere (strict `>` is unread), so returning a boundary equal to a
 * reply's createdAt marks that reply read.
 *
 * Returns null when there is nothing to advance to: no replies (never mint a
 * thread: key for a replyless thread) or a boundary that is not a positive
 * timestamp. Callers MUST pass the complete reply set — an unloaded reply
 * older than the computed boundary would be wrongly covered.
 */
export function computeThreadReadBoundary({
  replies,
  getReadAt,
  currentPubkey,
  isForcedUnread = () => false,
}: {
  replies: Pick<TimelineMessage, "id" | "createdAt" | "pubkey">[];
  getReadAt: (messageId: string) => number | null;
  currentPubkey?: string;
  isForcedUnread?: (messageId: string) => boolean;
}): number | null {
  if (replies.length === 0) return null;

  const normalizedPubkey = currentPubkey?.toLowerCase();
  let maxCreatedAt = 0;
  let minUnread: number | null = null;

  for (const reply of replies) {
    maxCreatedAt = Math.max(maxCreatedAt, reply.createdAt);
    if (normalizedPubkey && reply.pubkey?.toLowerCase() === normalizedPubkey) {
      continue;
    }
    const readAt = getReadAt(reply.id);
    const isUnread =
      isForcedUnread(reply.id) || readAt === null || reply.createdAt > readAt;
    if (isUnread && (minUnread === null || reply.createdAt < minUnread)) {
      minUnread = reply.createdAt;
    }
  }

  const boundary = minUnread === null ? maxCreatedAt : minUnread - 1;
  return boundary > 0 ? boundary : null;
}
