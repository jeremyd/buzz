#!/bin/sh
# Fork package version: the exact tag when building a tag, else
# v<upstream desktop version>-<short sha>, e.g. v0.5.5-abc12345.
#
# The version base comes from desktop/package.json, which upstream bumps on
# main as part of every desktop release (see RELEASING.md). Anchoring on the
# in-tree file instead of `git describe` keeps this shallow-clone-safe and
# avoids mirroring upstream tags into the fork (each pushed tag would trigger
# its own CI pipeline).
set -eu
if [ -n "${CI_COMMIT_TAG:-}" ]; then
  printf '%s\n' "$CI_COMMIT_TAG"
  exit 0
fi
ROOT=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
BASE=$(sed -n 's/^  "version": "\(.*\)",$/\1/p' "$ROOT/desktop/package.json")
[ -n "$BASE" ] || { echo "fork-version: no version in desktop/package.json" >&2; exit 1; }
SHA="${CI_COMMIT_SHORT_SHA:-$(git -C "$ROOT" rev-parse --short=8 HEAD)}"
printf 'v%s-%s\n' "$BASE" "$SHA"
