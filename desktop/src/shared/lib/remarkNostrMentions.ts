/**
 * Remark plugin that detects NIP-27 profile references (`nostr:npub1…` /
 * `nostr:nprofile1…`) in text nodes and replaces them with custom
 * `nostr-mention` elements carrying the decoded hex pubkey.
 *
 * Interop clients (e.g. Armada) mention users the standard Nostr way — a
 * `nostr:` URI in the content plus a `p` tag — never Buzz's plaintext
 * `@Display Name` format, so without this pass their mentions render as raw
 * bech32 strings. References that fail bech32 decoding stay plain text.
 */

import { decode } from "nostr-tools/nip19";

import { createRemarkPrefixPlugin } from "./createRemarkPrefixPlugin";

// bech32 payload charset (no 1/b/i/o). npub payloads are exactly 58 chars;
// nprofile payloads are longer and variable, so the length is left open and
// decode() arbitrates validity.
const NOSTR_PROFILE_URI_PATTERN = /nostr:n(?:pub|profile)1[02-9ac-hj-np-z]+/g;

/** Decode a `nostr:npub1…` / `nostr:nprofile1…` URI to a hex pubkey, or null. */
export function decodeNostrProfileUri(uri: string): string | null {
  try {
    const decoded = decode(uri.slice("nostr:".length));
    if (decoded.type === "npub") {
      return decoded.data;
    }
    if (decoded.type === "nprofile") {
      return decoded.data.pubkey;
    }
  } catch {
    // fall through — invalid bech32 stays plain text
  }
  return null;
}

export default function remarkNostrMentions() {
  return createRemarkPrefixPlugin(NOSTR_PROFILE_URI_PATTERN, (matchText) => {
    const pubkey = decodeNostrProfileUri(matchText);
    if (!pubkey) {
      return { type: "text", value: matchText };
    }
    return {
      type: "nostrMention",
      value: matchText,
      data: {
        hName: "nostr-mention",
        hProperties: { pubkey },
        hChildren: [{ type: "text", value: matchText }],
      },
    };
  });
}
