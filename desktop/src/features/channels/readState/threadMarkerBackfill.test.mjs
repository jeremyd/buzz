import assert from "node:assert/strict";
import test from "node:test";

// window.localStorage shim must exist before the module reads it at run time.
function makeLocalStorage() {
  const store = new Map();
  return {
    getItem: (key) => store.get(key) ?? null,
    setItem: (key, value) => store.set(key, value),
    removeItem: (key) => store.delete(key),
  };
}
if (typeof globalThis.window === "undefined") {
  globalThis.window = {};
}
globalThis.window.localStorage = makeLocalStorage();

const { runThreadMarkerBackfillOnce, readBackfillStore } = await import(
  "./threadMarkerBackfill.ts"
);

const RELAY = "wss://relay.example.com";
const PUBKEY = "f".repeat(64);
const OTHER = "0".repeat(64);
const CHANNEL = "channel-1";
const ROOT = "a".repeat(64);

function msgId(seed) {
  return String(seed).padStart(4, "0").repeat(16);
}

function replyEvent(id, createdAt, { root = ROOT, pubkey = OTHER } = {}) {
  return {
    id,
    pubkey,
    created_at: createdAt,
    kind: 9,
    tags: [
      ["h", CHANNEL],
      ["e", root, "", "root"],
      ["e", root, "", "reply"],
    ],
    content: "",
    sig: "sig",
  };
}

function topLevelEvent(id, createdAt) {
  return {
    id,
    pubkey: OTHER,
    created_at: createdAt,
    kind: 9,
    tags: [["h", CHANNEL]],
    content: "",
    sig: "sig",
  };
}

// Deps builder: real store + real boundary math; fake relay and mark seams.
function makeDeps({
  msgContexts,
  eventsById = new Map(),
  replies = [],
  ownTimestamps = new Map(),
  muted = new Set(),
  loadRepliesImpl,
} = {}) {
  const calls = {
    fetchBatches: [],
    loadReplies: [],
    marked: [],
    parents: [],
  };
  return {
    calls,
    deps: {
      relayUrl: RELAY,
      pubkey: PUBKEY,
      listOwnMsgContexts: () => msgContexts,
      fetchEventsByIds: async (ids) => {
        calls.fetchBatches.push([...ids]);
        return ids.map((id) => eventsById.get(id)).filter(Boolean);
      },
      loadReplies:
        loadRepliesImpl ??
        (async (channelId, rootId) => {
          calls.loadReplies.push([channelId, rootId]);
          return replies;
        }),
      getOwnTimestamp: (contextId) => ownTimestamps.get(contextId) ?? null,
      markThreadRead: (rootId, boundary, channelId) => {
        calls.marked.push({ rootId, boundary, channelId });
      },
      recordContextParent: (contextId, parent) => {
        calls.parents.push({ contextId, parent });
      },
      isRootMuted: (rootId) => muted.has(rootId),
      currentPubkey: PUBKEY,
    },
  };
}

test("backfill aggregates a fully-read thread to max reply createdAt", async () => {
  globalThis.window.localStorage = makeLocalStorage();
  const m1 = msgId(1);
  const m2 = msgId(2);
  const { deps, calls } = makeDeps({
    msgContexts: [
      [`msg:${m1}`, 100],
      [`msg:${m2}`, 200],
    ],
    eventsById: new Map([
      [m1, replyEvent(m1, 100)],
      [m2, replyEvent(m2, 200)],
    ]),
    replies: [replyEvent(m1, 100), replyEvent(m2, 200)],
    ownTimestamps: new Map([
      [`msg:${m1}`, 100],
      [`msg:${m2}`, 200],
    ]),
  });

  const result = await runThreadMarkerBackfillOnce(deps);

  assert.deepEqual(calls.marked, [
    { rootId: ROOT, boundary: 200, channelId: CHANNEL },
  ]);
  assert.deepEqual(calls.loadReplies, [[CHANNEL, ROOT]]);
  assert.ok(
    calls.parents.some(
      (p) =>
        p.contextId === `msg:${m1}` &&
        p.parent.c === CHANNEL &&
        p.parent.r === ROOT,
    ),
  );
  assert.equal(result.advanced, 1);
  assert.equal(result.exhausted, true);
  const store = readBackfillStore(RELAY, PUBKEY);
  assert.equal(store.msgs[m1], "done");
  assert.equal(store.msgs[m2], "done");
});

test("backfill stops below an unread reply (min unread - 1)", async () => {
  globalThis.window.localStorage = makeLocalStorage();
  const m1 = msgId(1);
  const unreadId = msgId(9);
  const { deps, calls } = makeDeps({
    msgContexts: [[`msg:${m1}`, 100]],
    eventsById: new Map([[m1, replyEvent(m1, 100)]]),
    replies: [replyEvent(m1, 100), replyEvent(unreadId, 150)],
    ownTimestamps: new Map([[`msg:${m1}`, 100]]),
  });

  await runThreadMarkerBackfillOnce(deps);

  assert.deepEqual(calls.marked, [
    { rootId: ROOT, boundary: 149, channelId: CHANNEL },
  ]);
});

test("backfill is grow-only: covered boundary writes nothing but completes", async () => {
  globalThis.window.localStorage = makeLocalStorage();
  const m1 = msgId(1);
  const { deps, calls } = makeDeps({
    msgContexts: [[`msg:${m1}`, 100]],
    eventsById: new Map([[m1, replyEvent(m1, 100)]]),
    replies: [replyEvent(m1, 100)],
    ownTimestamps: new Map([
      [`msg:${m1}`, 100],
      [`thread:${ROOT}`, 500], // aggregate already ahead of the boundary
    ]),
  });

  const result = await runThreadMarkerBackfillOnce(deps);

  assert.deepEqual(calls.marked, []);
  assert.equal(result.exhausted, true);
  assert.equal(readBackfillStore(RELAY, PUBKEY).msgs[m1], "done");
});

test("backfill skips a muted root without fetching its replies", async () => {
  globalThis.window.localStorage = makeLocalStorage();
  const m1 = msgId(1);
  const { deps, calls } = makeDeps({
    msgContexts: [[`msg:${m1}`, 100]],
    eventsById: new Map([[m1, replyEvent(m1, 100)]]),
    muted: new Set([ROOT]),
  });

  await runThreadMarkerBackfillOnce(deps);

  assert.deepEqual(calls.loadReplies, []);
  assert.deepEqual(calls.marked, []);
  assert.equal(readBackfillStore(RELAY, PUBKEY).msgs[m1], "done");
});

test("backfill reply-fetch failure writes no marker and leaves the root pending", async () => {
  globalThis.window.localStorage = makeLocalStorage();
  const m1 = msgId(1);
  let attempts = 0;
  const base = {
    msgContexts: [[`msg:${m1}`, 100]],
    eventsById: new Map([[m1, replyEvent(m1, 100)]]),
  };
  const { deps, calls } = makeDeps({
    ...base,
    loadRepliesImpl: async () => {
      attempts++;
      throw new Error("relay timeout");
    },
  });

  await assert.rejects(() => runThreadMarkerBackfillOnce(deps));
  assert.deepEqual(calls.marked, []);
  assert.notEqual(readBackfillStore(RELAY, PUBKEY).msgs[m1], "done");

  // A later run retries the same root.
  const retry = makeDeps({
    ...base,
    replies: [replyEvent(m1, 100)],
    ownTimestamps: new Map([[`msg:${m1}`, 100]]),
  });
  const result = await runThreadMarkerBackfillOnce(retry.deps);
  assert.equal(attempts, 1);
  assert.equal(result.advanced, 1);
  assert.equal(readBackfillStore(RELAY, PUBKEY).msgs[m1], "done");
});

test("backfill unresolvable ids terminate after exactly the attempt cap", async () => {
  globalThis.window.localStorage = makeLocalStorage();
  const ghost = msgId(7);
  let fetches = 0;
  const make = () =>
    makeDeps({
      msgContexts: [[`msg:${ghost}`, 100]],
      eventsById: new Map(), // never resolves
    });

  for (let run = 0; run < 5; run++) {
    const { deps, calls } = make();
    const result = await runThreadMarkerBackfillOnce(deps);
    fetches += calls.fetchBatches.length;
    if (run >= 2) {
      assert.equal(
        result.exhausted,
        true,
        `run ${run}: terminal after 3 attempts`,
      );
    }
  }

  assert.equal(fetches, 3, "exactly 3 resolve attempts across all runs");
  assert.equal(readBackfillStore(RELAY, PUBKEY).msgs[ghost], "unresolvable");
});

test("backfill resumes: a second run performs zero relay work", async () => {
  globalThis.window.localStorage = makeLocalStorage();
  const m1 = msgId(1);
  const fixture = {
    msgContexts: [[`msg:${m1}`, 100]],
    eventsById: new Map([[m1, replyEvent(m1, 100)]]),
    replies: [replyEvent(m1, 100)],
    ownTimestamps: new Map([[`msg:${m1}`, 100]]),
  };
  await runThreadMarkerBackfillOnce(makeDeps(fixture).deps);

  const second = makeDeps(fixture);
  const result = await runThreadMarkerBackfillOnce(second.deps);
  assert.deepEqual(second.calls.fetchBatches, []);
  assert.deepEqual(second.calls.loadReplies, []);
  assert.equal(result.exhausted, true);
});

test("backfill records channel-only parents for top-level messages", async () => {
  globalThis.window.localStorage = makeLocalStorage();
  const m1 = msgId(1);
  const { deps, calls } = makeDeps({
    msgContexts: [[`msg:${m1}`, 100]],
    eventsById: new Map([[m1, topLevelEvent(m1, 100)]]),
  });

  const result = await runThreadMarkerBackfillOnce(deps);

  assert.deepEqual(calls.parents, [
    { contextId: `msg:${m1}`, parent: { c: CHANNEL, r: null } },
  ]);
  assert.deepEqual(calls.loadReplies, []);
  assert.deepEqual(calls.marked, []);
  assert.equal(result.exhausted, true);
  assert.equal(readBackfillStore(RELAY, PUBKEY).msgs[m1], "done");
});

test("backfill resolves a nested e-tag root to the true thread root", async () => {
  globalThis.window.localStorage = makeLocalStorage();
  const trueRoot = "b".repeat(64);
  const nested = "c".repeat(64);
  const m1 = msgId(1);
  const { deps, calls } = makeDeps({
    msgContexts: [[`msg:${m1}`, 100]],
    eventsById: new Map([
      // The reply's e-tags point at the NESTED message as its root.
      [m1, replyEvent(m1, 100, { root: nested })],
      // The nested message is itself a reply under the true root.
      [nested, replyEvent(nested, 50, { root: trueRoot })],
    ]),
    replies: [replyEvent(m1, 100, { root: trueRoot })],
    ownTimestamps: new Map([[`msg:${m1}`, 100]]),
  });

  await runThreadMarkerBackfillOnce(deps);

  assert.deepEqual(calls.loadReplies, [[CHANNEL, trueRoot]]);
  assert.deepEqual(calls.marked, [
    { rootId: trueRoot, boundary: 100, channelId: CHANNEL },
  ]);
});
