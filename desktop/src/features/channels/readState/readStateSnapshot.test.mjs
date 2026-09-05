import assert from "node:assert/strict";
import test from "node:test";

import { mergeReadStateMaps } from "./readStateSnapshot.ts";

test("mergeReadStateMaps keeps the per-context maximum from both sides", () => {
  const merged = mergeReadStateMaps(
    new Map([
      ["channel-1", 100],
      ["msg:aaa", 50],
    ]),
    new Map([
      ["channel-1", 40],
      ["msg:aaa", 60],
    ]),
  );
  assert.deepEqual(
    merged,
    new Map([
      ["channel-1", 100],
      ["msg:aaa", 60],
    ]),
  );
});

test("mergeReadStateMaps unions disjoint contexts", () => {
  const merged = mergeReadStateMaps(
    new Map([["channel-1", 10]]),
    new Map([["thread:bbb", 20]]),
  );
  assert.deepEqual(
    merged,
    new Map([
      ["channel-1", 10],
      ["thread:bbb", 20],
    ]),
  );
});

test("mergeReadStateMaps does not mutate its inputs", () => {
  const base = new Map([["channel-1", 10]]);
  const overlay = new Map([["channel-1", 20]]);
  mergeReadStateMaps(base, overlay);
  assert.equal(base.get("channel-1"), 10);
  assert.equal(overlay.get("channel-1"), 20);
});
