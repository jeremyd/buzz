import assert from "node:assert/strict";
import test from "node:test";

// window.localStorage shim before the storage module is exercised.
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

const { persistObserverUnreadDetail } = await import(
  "./communityUnreadDetailCache.ts"
);
const { readObservedUnreadFromStorage } = await import(
  "../channels/observedUnreadStorage.ts"
);
const { normalizeRelayUrl } = await import(
  "../profile/lib/selfProfileStorage.ts"
);

const PUBKEY = "a".repeat(64);
const RELAY = "wss://relay.example.com";
const CHANNEL = "channel-1";
const ROOT = "c".repeat(64);

function nowSeconds() {
  return Math.floor(Date.now() / 1_000);
}

test("persistObserverUnreadDetail round-trips through the real observed cache", () => {
  globalThis.window.localStorage = makeLocalStorage();
  const createdAt = nowSeconds();

  persistObserverUnreadDetail(PUBKEY, RELAY, [
    {
      channelId: CHANNEL,
      channelType: "stream",
      id: "mention-ev".padEnd(64, "0"),
      createdAt,
      rootId: ROOT,
      mention: true,
    },
    {
      channelId: CHANNEL,
      channelType: "stream",
      id: "plain-ev".padEnd(64, "0"),
      createdAt,
      rootId: null,
      mention: false,
    },
  ]);

  const cached = readObservedUnreadFromStorage(
    PUBKEY,
    normalizeRelayUrl(RELAY),
  );
  assert.notEqual(cached, null);
  const channelEvents = cached.get(CHANNEL);
  const mention = channelEvents.get("mention-ev".padEnd(64, "0"));
  assert.equal(mention.highPriority, true);
  assert.equal(mention.countsTowardBadge, true);
  assert.equal(mention.rootId, ROOT);
  const plain = channelEvents.get("plain-ev".padEnd(64, "0"));
  assert.equal(plain.highPriority, false);
  assert.equal(
    plain.countsTowardBadge,
    false,
    "a plain top-level stream message lights the dot, not the badge",
  );
});

test("persistObserverUnreadDetail merges and upgrades priority, never downgrades", () => {
  globalThis.window.localStorage = makeLocalStorage();
  const createdAt = nowSeconds();
  const id = "upgraded".padEnd(64, "0");
  const detail = (mention) => [
    {
      channelId: CHANNEL,
      channelType: "stream",
      id,
      createdAt,
      rootId: ROOT,
      mention,
    },
  ];

  persistObserverUnreadDetail(PUBKEY, RELAY, detail(false));
  persistObserverUnreadDetail(PUBKEY, RELAY, detail(true));
  persistObserverUnreadDetail(PUBKEY, RELAY, detail(false)); // must not downgrade

  const cached = readObservedUnreadFromStorage(
    PUBKEY,
    normalizeRelayUrl(RELAY),
  );
  assert.equal(cached.get(CHANNEL).get(id).highPriority, true);
});

test("persistObserverUnreadDetail with no detail writes nothing", () => {
  globalThis.window.localStorage = makeLocalStorage();
  persistObserverUnreadDetail(PUBKEY, RELAY, []);
  assert.equal(
    readObservedUnreadFromStorage(PUBKEY, normalizeRelayUrl(RELAY)),
    null,
  );
});
