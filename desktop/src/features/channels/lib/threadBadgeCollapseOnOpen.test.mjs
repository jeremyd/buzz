import assert from "node:assert/strict";
import test from "node:test";

import { computeThreadBadgeCounts } from "./threadBadgeCounts.ts";
import { computeThreadReadBoundary } from "./threadReadBoundary.ts";
import { buildRepliesByRootId } from "./subtreeCreatedAt.ts";

// Open-at-level contract (LP4 v3). Opening a thread no longer collapses the
// whole subtree badge (#1118's behavior, deliberately reversed). The on-open
// effect marks read ONLY the replies revealed on open — each gets its own
// msg:<id> marker advanced to its createdAt — so a reply in a still-collapsed
// branch keeps its badge until it too is revealed. The root summary badge
// (computeThreadBadgeCounts) reads effective(msg:<id>) live: a reply counts
// iff createdAt > readAt, so reading one reply never clears another.

// rootId travels with every reply (getThreadReference's `root` e-tag), so a
// nested reply rolls up to the thread root even when an ancestor is collapsed.
const msg = (id, parentId, createdAt = 100, pubkey = "author", rootId) => ({
  id,
  parentId,
  rootId: rootId ?? parentId ?? id,
  createdAt,
  pubkey,
});

const countAll = () => true;

// Model the on-open mark-read effect: each revealed reply's msg:<id> marker is
// advanced to its own createdAt (useChannelUnreadState's open effect maps
// markMessageRead(id, createdAt) over the visible set). A reply absent from the
// revealed set was never read, so its resolver returns null and it stays
// unread. Returns the live per-message getReadAt resolver after the open.
function openMarksRevealed(messages, revealedIds) {
  const revealed = new Set(revealedIds);
  const createdAtById = new Map(messages.map((m) => [m.id, m.createdAt]));
  return (id) => (revealed.has(id) ? (createdAtById.get(id) ?? null) : null);
}

const rootBadge = (messages, getReadAt, currentPubkey) =>
  computeThreadBadgeCounts(
    messages,
    buildRepliesByRootId(messages),
    getReadAt,
    countAll,
    currentPubkey,
  ).get("root");

test("openRevealingOnlyDirectChild_keepsCollapsedGrandchildBadge", () => {
  // root -> a -> b: opening reveals direct child a but b is nested under a
  // still-collapsed branch. The OLD whole-subtree-on-open would have cleared
  // the badge entirely; v3 marks only a read, so b keeps the root badge lit.
  const messages = [
    msg("root", null, 50),
    msg("a", "root", 100),
    msg("b", "a", 200, "author", "root"),
  ];
  assert.equal(rootBadge(messages, openMarksRevealed(messages, ["a"])), 1);
});

test("openRevealingWholeSubtree_clearsRootBadge", () => {
  // When every reply is revealed on open, each is marked read and the badge
  // clears — the only case the old subtree-collapse and the new open-at-level
  // agree on.
  const messages = [
    msg("root", null, 50),
    msg("a", "root", 100),
    msg("b", "a", 200, "author", "root"),
  ];
  assert.equal(
    rootBadge(messages, openMarksRevealed(messages, ["a", "b"])),
    undefined,
  );
});

test("openRevealingOneBranch_keepsOtherCollapsedBranchBadge", () => {
  // root -> {a -> a1, c -> c1}: opening reveals branch a (a, a1) but leaves
  // branch c collapsed. The two unread replies under c keep the root badge.
  const messages = [
    msg("root", null, 50),
    msg("a", "root", 100),
    msg("a1", "a", 110, "author", "root"),
    msg("c", "root", 120),
    msg("c1", "c", 130, "author", "root"),
  ];
  assert.equal(
    rootBadge(messages, openMarksRevealed(messages, ["a", "a1"])),
    2,
  );
});

test("newerReplyAfterOpen_relightsRootBadge", () => {
  // Open marks a(100) read at its createdAt. A newer reply b(200) arrives in
  // the same revealed branch; the predicate is strictly createdAt > readAt, so
  // b is unread against a's marker and the badge relights. Models a reply
  // landing after the open snapshot without re-marking.
  const messages = [
    msg("root", null, 50),
    msg("a", "root", 100),
    msg("b", "root", 200),
  ];
  // Only a was present/revealed at open; b is unread (never marked).
  assert.equal(rootBadge(messages, openMarksRevealed(messages, ["a"])), 1);
});

test("boundaryAdvanceThenMsgEviction_coveredBranchesStayClear", () => {
  // The eviction-resurrection regression, end to end at the badge seam:
  // open reveals branch a (a, a1) while branch c stays collapsed. The
  // boundary-advance effect then advances thread:root to min(unread)-1, and
  // budget pressure later evicts the revealed replies' msg: markers. With
  // the aggregate folded into the resolver (the production fold), the
  // covered branch stays clear and ONLY the collapsed-unread branch is lit.
  const messages = [
    msg("root", null, 50),
    msg("a", "root", 100),
    msg("a1", "a", 110, "author", "root"),
    msg("c", "root", 120),
    msg("c1", "c", 130, "author", "root"),
  ];
  const afterOpen = openMarksRevealed(messages, ["a", "a1"]);
  const boundary = computeThreadReadBoundary({
    replies: messages.filter((m) => m.id !== "root"),
    getReadAt: afterOpen,
  });
  // First unread is c(120) → boundary 119 covers a(100) and a1(110).
  assert.equal(boundary, 119);

  // Every msg: marker below the boundary is dominated and evicted; the
  // resolver folds only the surviving aggregate.
  const foldedAfterEviction = (id) => {
    const own = afterOpen(id);
    const dominated = own !== null && own <= boundary;
    return Math.max(dominated ? 0 : (own ?? 0), boundary) || null;
  };
  assert.equal(rootBadge(messages, foldedAfterEviction), 2);

  // Without the boundary advance, the same eviction resurrects the read
  // branch: all four replies light up again — the bug this guards against.
  const evictedWithoutBoundary = (id) => {
    const own = afterOpen(id);
    return own !== null && own <= boundary ? null : own;
  };
  assert.equal(rootBadge(messages, evictedWithoutBoundary), 4);
});

test("openThreadWhereOnlyUnreadIsOwnReply_neverShowsBadge", () => {
  // A nested reply authored by the current user. Self-authored replies are
  // excluded from the count, so no badge shows regardless of read state — the
  // open-at-level change is inert here.
  const messages = [
    msg("root", null, 50),
    msg("a", "root", 100, "other"),
    msg("b", "a", 200, "ME", "root"),
  ];
  // Nothing revealed (never read), only "other"'s reply a could count.
  assert.equal(
    rootBadge(messages, () => null, "me"),
    1,
  );
  // After revealing a, only the self-authored b remains — no badge.
  assert.equal(
    rootBadge(messages, openMarksRevealed(messages, ["a"]), "me"),
    undefined,
  );
});

test("openThreadWhereEveryUnreadIsOwnReply_inertNoBadgeEver", () => {
  // Every reply is the user's own → no badge before OR after open.
  const messages = [
    msg("root", null, 50),
    msg("a", "root", 100, "ME"),
    msg("b", "a", 200, "ME", "root"),
  ];
  assert.equal(
    rootBadge(messages, () => null, "me"),
    undefined,
  );
  assert.equal(
    rootBadge(messages, openMarksRevealed(messages, ["a", "b"]), "me"),
    undefined,
  );
});
