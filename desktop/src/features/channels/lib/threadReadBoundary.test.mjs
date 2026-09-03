import assert from "node:assert/strict";
import test from "node:test";

import { computeThreadReadBoundary } from "./threadReadBoundary.ts";
import { computeThreadUnreadMarker } from "@/features/messages/lib/unreadMarker";

const OWN_PUBKEY = "f".repeat(64);
const OTHER_PUBKEY = "0".repeat(64);

const reply = (id, createdAt, pubkey = OTHER_PUBKEY) => ({
  id,
  createdAt,
  pubkey,
});

test("all replies read advances to the max reply createdAt", () => {
  const replies = [reply("r1", 100), reply("r2", 200), reply("r3", 300)];
  const boundary = computeThreadReadBoundary({
    replies,
    getReadAt: (id) => ({ r1: 100, r2: 200, r3: 300 })[id] ?? null,
    currentPubkey: OWN_PUBKEY,
  });
  assert.equal(boundary, 300);

  // The eviction-resurrection regression, end to end: with every msg: marker
  // dominated by the boundary and evicted, folding the aggregate alone keeps
  // the whole thread read under the badge predicate.
  const { unreadCount } = computeThreadUnreadMarker(
    replies,
    () => boundary,
    OWN_PUBKEY,
  );
  assert.equal(unreadCount, 0);
});

test("a collapsed unread reply caps the boundary at min(unread) - 1", () => {
  // r2 is unread (collapsed branch); r1 and r3 are read. The boundary stops
  // below r2 — the read replies at and above r2's createdAt stay covered by
  // their own msg: markers (not dominated, so not safely evictable).
  const replies = [reply("r1", 100), reply("r2", 200), reply("r3", 300)];
  const msgMarkers = { r1: 100, r3: 300 };
  const boundary = computeThreadReadBoundary({
    replies,
    getReadAt: (id) => msgMarkers[id] ?? null,
    currentPubkey: OWN_PUBKEY,
  });
  assert.equal(boundary, 199);

  // Cross-check against the badge predicate with the aggregate folded in:
  // exactly the collapsed-unread reply stays lit.
  const folded = (id) => Math.max(boundary, msgMarkers[id] ?? 0);
  const { unreadCount, firstUnreadReplyId } = computeThreadUnreadMarker(
    replies,
    folded,
    OWN_PUBKEY,
  );
  assert.equal(firstUnreadReplyId, "r2");
  assert.equal(unreadCount, 1);
});

test("self-authored replies never block the boundary", () => {
  // The user's own newest reply extends the boundary even with no marker —
  // the reply-send case: replying advances thread: past everything read.
  const replies = [reply("r1", 100), reply("mine", 500, OWN_PUBKEY)];
  const boundary = computeThreadReadBoundary({
    replies,
    getReadAt: (id) => (id === "r1" ? 100 : null),
    currentPubkey: OWN_PUBKEY,
  });
  assert.equal(boundary, 500);
});

test("a forced-unread reply caps the boundary", () => {
  const replies = [reply("r1", 100), reply("r2", 200)];
  const boundary = computeThreadReadBoundary({
    replies,
    getReadAt: () => 999,
    currentPubkey: OWN_PUBKEY,
    isForcedUnread: (id) => id === "r2",
  });
  assert.equal(boundary, 199);
});

test("empty replies and non-positive boundaries return null", () => {
  assert.equal(
    computeThreadReadBoundary({ replies: [], getReadAt: () => null }),
    null,
  );
  // Sole reply unread at createdAt=1 → boundary 0 → null (never mint a key).
  assert.equal(
    computeThreadReadBoundary({
      replies: [reply("r1", 1)],
      getReadAt: () => null,
      currentPubkey: OWN_PUBKEY,
    }),
    null,
  );
});

test("ties: a read and an unread reply sharing createdAt cap at t - 1", () => {
  // r1 read at exactly its createdAt (tie = read, strict > is unread); r2
  // unread at the same createdAt. Boundary must stay below both.
  const replies = [reply("r1", 200), reply("r2", 200)];
  const boundary = computeThreadReadBoundary({
    replies,
    getReadAt: (id) => (id === "r1" ? 200 : null),
    currentPubkey: OWN_PUBKEY,
  });
  assert.equal(boundary, 199);

  // A reply whose createdAt equals the boundary reads as covered.
  const covered = computeThreadReadBoundary({
    replies: [reply("r3", 199)],
    getReadAt: () => boundary,
    currentPubkey: OWN_PUBKEY,
  });
  assert.equal(covered, 199);
});
