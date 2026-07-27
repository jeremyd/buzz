import assert from "node:assert/strict";
import test from "node:test";

import { npubEncode, nprofileEncode } from "nostr-tools/nip19";

import remarkNostrMentions, {
  decodeNostrProfileUri,
} from "./remarkNostrMentions.ts";

const PUBKEY =
  "7cc328a08ddb2afdf9f9be77beff4c83489ff979721827d628a542f32a247c0e";

function transform(text) {
  const tree = { type: "root", children: [{ type: "text", value: text }] };
  remarkNostrMentions()(tree);
  return tree.children;
}

test("decodes a nostr:npub URI to the hex pubkey", () => {
  assert.equal(decodeNostrProfileUri(`nostr:${npubEncode(PUBKEY)}`), PUBKEY);
});

test("decodes a nostr:nprofile URI to the hex pubkey", () => {
  const uri = `nostr:${nprofileEncode({ pubkey: PUBKEY, relays: [] })}`;
  assert.equal(decodeNostrProfileUri(uri), PUBKEY);
});

test("invalid bech32 decodes to null", () => {
  assert.equal(decodeNostrProfileUri("nostr:npub1qqqq"), null);
});

test("replaces a nostr:npub reference with a nostr-mention node", () => {
  const npub = npubEncode(PUBKEY);
  const children = transform(`hey nostr:${npub} hello`);

  assert.equal(children.length, 3);
  assert.deepEqual(children[0], { type: "text", value: "hey " });
  assert.equal(children[1].type, "nostrMention");
  assert.equal(children[1].data.hName, "nostr-mention");
  assert.equal(children[1].data.hProperties.pubkey, PUBKEY);
  assert.deepEqual(children[2], { type: "text", value: " hello" });
});

test("invalid references stay plain text", () => {
  // The match may split the text node, but every part stays a text node
  // and the content is preserved verbatim.
  const children = transform("see nostr:npub1qqqq for details");
  assert.ok(children.every((child) => child.type === "text"));
  assert.equal(
    children.map((child) => child.value).join(""),
    "see nostr:npub1qqqq for details",
  );
});

test("trailing punctuation is not swallowed", () => {
  const npub = npubEncode(PUBKEY);
  const children = transform(`ask nostr:${npub}.`);

  assert.equal(children.length, 3);
  assert.equal(children[1].data.hProperties.pubkey, PUBKEY);
  assert.deepEqual(children[2], { type: "text", value: "." });
});

test("plain text without nostr URIs is untouched", () => {
  const children = transform("no mentions here");
  assert.deepEqual(children, [{ type: "text", value: "no mentions here" }]);
});
