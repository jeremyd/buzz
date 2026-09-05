import 'dart:convert';

import 'read_state_format.dart';

/// Publish-path hygiene for the read-state blob — Dart port of desktop's
/// dropDominatedContexts + trimContextsToBudget (readStateManager.ts); keep
/// the two in sync.

/// Drop `msg:`/`thread:` entries dominated by their parent frontier WITHIN
/// THE SAME contexts map (NIP-RS "Dominated entries"): a `msg:` entry whose
/// value is <= max(outgoing `thread:<root>`, outgoing channel marker), or a
/// `thread:` entry whose value is <= the outgoing channel marker, reads
/// identically on every conforming reader whether present or absent.
///
/// Safety invariant: domination is judged ONLY against values present in the
/// same outgoing map (a pre-drop snapshot of it) — a local-only value other
/// devices never saw must not justify dropping a marker they depend on.
/// Contexts with no recorded parent are never dropped. Channel keys are never
/// dropped. Mutates [contexts] in place; returns the number dropped.
int dropDominatedContexts(
  Map<String, int> contexts,
  Map<String, ContextParent> parents,
) {
  final snapshot = Map<String, int>.from(contexts);
  var dropped = 0;
  for (final entry in snapshot.entries) {
    final parent = parents[entry.key];
    if (parent == null) continue;

    int? frontier;
    if (entry.key.startsWith(msgContextPrefix)) {
      final root = parent.r;
      frontier = maxReadAt([
        snapshot[parent.c],
        if (root != null) snapshot['$threadContextPrefix$root'],
      ]);
    } else if (entry.key.startsWith(threadContextPrefix)) {
      frontier = snapshot[parent.c];
    } else {
      continue;
    }

    if (frontier != null && entry.value <= frontier) {
      contexts.remove(entry.key);
      dropped++;
    }
  }
  return dropped;
}

/// Result of a [trimContextsToBudget] call.
class TrimResult {
  final int evicted;
  final bool fitsAfterTrim;

  const TrimResult({required this.evicted, required this.fitsAfterTrim});
}

int _blobBytes(Map<String, int> contexts, String clientId) => utf8
    .encode(jsonEncode({'v': 1, 'client_id': clientId, 'contexts': contexts}))
    .length;

/// Trim a contexts map to fit within [maxBytes] when serialized as the blob
/// `{v:1, client_id, contexts}`. Evicts `msg:` entries first, then `thread:`
/// entries, each tier ordered by read-action recency ([sourceCreatedAt],
/// falling back to the marker value) — an old-VALUED marker the user recently
/// re-affirmed can be the sole cover for an event newer than its channel and
/// thread frontiers, and evicting it by marker age resurrects that event as
/// unread on every relay-state reader. Channel keys are never evicted.
///
/// `fitsAfterTrim` is false when channel keys alone still exceed the budget —
/// the caller must not publish in that case. Mutates [contexts] in place.
TrimResult trimContextsToBudget(
  Map<String, int> contexts,
  String clientId,
  int maxBytes,
  Map<String, int> sourceCreatedAt,
) {
  var currentBytes = _blobBytes(contexts, clientId);
  if (currentBytes <= maxBytes) {
    return const TrimResult(evicted: 0, fitsAfterTrim: true);
  }

  final msgEntries = <MapEntry<String, int>>[];
  final threadEntries = <MapEntry<String, int>>[];
  for (final entry in contexts.entries) {
    if (entry.key.startsWith(msgContextPrefix)) {
      msgEntries.add(entry);
    } else if (entry.key.startsWith(threadContextPrefix)) {
      threadEntries.add(entry);
    }
  }

  int recency(MapEntry<String, int> entry) =>
      sourceCreatedAt[entry.key] ?? entry.value;
  int byRecency(MapEntry<String, int> a, MapEntry<String, int> b) {
    final byAffirmed = recency(a) - recency(b);
    if (byAffirmed != 0) return byAffirmed;
    final byValue = a.value - b.value;
    if (byValue != 0) return byValue;
    return a.key.compareTo(b.key);
  }

  msgEntries.sort(byRecency);
  threadEntries.sort(byRecency);

  var evicted = 0;
  for (final entry in [...msgEntries, ...threadEntries]) {
    if (currentBytes <= maxBytes) break;
    // Per-entry contribution estimate: `,"key":value`.
    currentBytes -= entry.key.length + 3 + entry.value.toString().length + 1;
    contexts.remove(entry.key);
    evicted++;
  }

  return TrimResult(
    evicted: evicted,
    fitsAfterTrim: _blobBytes(contexts, clientId) <= maxBytes,
  );
}
