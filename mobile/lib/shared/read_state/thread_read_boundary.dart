/// A reply considered by [computeThreadReadBoundary] — the minimal projection
/// of a timeline message the boundary needs, kept as a record so this shared
/// helper does not depend on feature-layer message types.
typedef ThreadBoundaryReply = ({String id, int createdAt, String pubkey});

/// Maximal safe `thread:<root>` frontier for a COMPLETE reply set: the largest
/// T such that every reply with createdAt <= T is read. All replies read (or
/// self-authored) -> max reply createdAt; otherwise min(unread createdAt) - 1,
/// so `msg:` markers keep covering read replies newer than the first unread
/// one and an unread branch stays unread.
///
/// Port of desktop's `computeThreadReadBoundary`
/// (desktop/src/features/channels/lib/threadReadBoundary.ts) — keep the two in
/// sync. The read predicate is: self-authored OR (not forced-unread AND
/// createdAt <= readAt). Ties count as read everywhere (strict `>` is
/// unread), so returning a boundary equal to a reply's createdAt marks that
/// reply read.
///
/// Returns null when there is nothing to advance to: no replies (never mint a
/// `thread:` key for a replyless thread) or a boundary that is not a positive
/// timestamp. Callers MUST pass the complete reply set — an unloaded reply
/// older than the computed boundary would be wrongly covered.
int? computeThreadReadBoundary({
  required List<ThreadBoundaryReply> replies,
  required int? Function(String messageId) getReadAt,
  String? currentPubkey,
  bool Function(String messageId)? isForcedUnread,
}) {
  if (replies.isEmpty) return null;

  final normalizedPubkey = currentPubkey?.toLowerCase();
  var maxCreatedAt = 0;
  int? minUnread;

  for (final reply in replies) {
    if (reply.createdAt > maxCreatedAt) {
      maxCreatedAt = reply.createdAt;
    }
    if (normalizedPubkey != null &&
        reply.pubkey.toLowerCase() == normalizedPubkey) {
      continue;
    }
    final readAt = getReadAt(reply.id);
    final unread =
        (isForcedUnread?.call(reply.id) ?? false) ||
        readAt == null ||
        reply.createdAt > readAt;
    if (unread && (minUnread == null || reply.createdAt < minUnread)) {
      minUnread = reply.createdAt;
    }
  }

  final boundary = minUnread == null ? maxCreatedAt : minUnread - 1;
  return boundary > 0 ? boundary : null;
}
