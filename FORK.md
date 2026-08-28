# FORK.md — Maintaining the relay.tools Fork

This repository is a fork of [block/buzz](https://github.com/block/buzz)
maintained at `code.relay.tools` (GitLab). This document describes how the
fork is kept current, how contributors build on top of it, and how its
artifacts are versioned.

## Remotes

| Remote | URL | Purpose |
|--------|-----|---------|
| `origin` | `https://code.relay.tools/forks/buzz.git` | The fork (GitLab) — `main` is the published branch |
| `block` | `github.com/block/buzz` | Upstream |
| `jeremyd` | `github.com/jeremyd/buzz` | GitHub fork used for upstream PRs |

## The float (rebase dance)

Fork-only commits ("carries" — external-login removal, GitLab CI, Helm
chart/workbench tooling, upstream-PR candidates) are periodically rebased
onto the latest `block/main`, then force-pushed to `origin main`. Keeping
carries floated on top of upstream keeps the diff reviewable and
upstreamable. History rewrites on `origin main` after a float are normal
and expected.

The dance:

1. **Preflight** — clean working tree; `git config user.email` must be
   `cloudfodder@relay.tools` (set repo-locally; the global config is a
   different identity and will silently stamp rebased commits).
2. **Backup** — `git branch backup/pre-float-<date> main`, then **publish
   it**: `git push --no-verify origin backup/pre-float-<date>`. The
   published snapshot is the contract that lets downstream contributors
   recover deterministically after the rewrite (see
   [Building on this fork](#building-on-this-fork) below). Pushing a new
   branch needs no protection dance.
3. **Fetch** — `git fetch block --tags`.
4. **Float** — `git rebase block/main main --signoff` (DCO requires the
   trailer on every replayed commit). Resolve conflicts with the carry's
   intent in mind; if upstream has since implemented what a carry did,
   **drop the carry** (`git rebase --skip`) rather than keeping a duplicate.
5. **Verify in-cluster** — `just wb-check` (runs `just ci` on the arrowhead
   workbench pod against the local working tree). No local cargo/pnpm runs.
6. **Force-push** — `origin main` is a protected branch that blocks force
   pushes. Toggle `allow_force_push` via the GitLab API (token in
   `~/GITLAB_TOKEN_BUZZFORK.env`, kept outside the repo), push with
   `--force-with-lease --no-verify`, toggle back. Plain fast-forward pushes
   need no dance.

## Building on this fork

`origin main` is **periodically rewritten** by the float above — often
several times a week. If you (human or agent) maintain changes on top of
this fork, follow this workflow and the rewrites become a routine
30-second operation instead of a merge disaster.

### One-time setup

```bash
git config pull.rebase true      # pull does the right thing on a rewritten upstream
git config rerere.enabled true   # remembers conflict resolutions across repeated floats
```

### The rules

1. **Never merge `origin/main` into your branch.** After a float, a merge
   resurrects every pre-rewrite carry as a conflicting duplicate. Rebase
   only.
2. **Keep your branch a linear stack of your own commits** on top of
   `origin/main` — no merge commits mixed in. You are maintaining a carry
   stack one level down, exactly as this fork does on top of `block/main`.
3. **Sign off every commit** (`git commit -s`) — same DCO convention as
   the fork.

### After each float (recovering your branch)

The usual case — your branch is "old `origin/main` + your commits":

```bash
git fetch origin
git rebase origin/main my-branch
```

`git rebase` drops commits whose patch-id already exists on the new base,
so only *your* commits are replayed; the fork's rewritten carries are
skipped automatically.

If that leaves stray duplicates or confusing conflicts (it can, when a
float resolved conflicts inside a carry), use the deterministic form
anchored on the published pre-float snapshot — it moves *exactly* your
commits, no patch-id heuristics:

```bash
git rebase --onto origin/main origin/backup/pre-float-<date> my-branch
```

where `backup/pre-float-<date>` is the newest snapshot older than your
branch (i.e. the head your branch was built on). List them with
`git ls-remote origin 'refs/heads/backup/pre-float-*'`.

### Where should your change live?

- **Useful to everyone running this fork** → open a merge request against
  the fork. Once merged into the carry stack it gets floated for you;
  you maintain nothing.
- **Private/experimental** → keep it as your own overlay stack on top of
  `origin/main` and re-float it (as above) after each fork float. Keep the
  stack small; upstream anything that stops being experimental.
- **Independent of the fork's carries** → consider basing on `block/main`
  instead. Upstream never rewrites, so plain merges work, and you only
  combine with the fork's carries at deploy time.

### Note for agents

When asked to update a branch that no longer applies cleanly to
`origin/main`, assume a float happened: `git fetch origin`, check
`git log --oneline origin/main -5` against the branch's merge base, and
use the recovery recipes above. Do not "fix" the situation by merging,
cherry-picking the whole fork history, or resetting the branch to
`origin/main` (which discards the contributor's work).

## Package versioning

GitLab CI (`.gitlab-ci.yml`) publishes Linux/Windows desktop bundles, an
Arch package, and a signed Android APK to the project package registry.
Each Linux build also ships a `-debug` variant (tarball + `buzz-desktop-debug`
Arch package): the same release-profile app compiled with the `devtools`
cargo feature, so the WebKit inspector (right-click → Inspect Element, JS
console) is available. It installs as `/usr/bin/buzz-desktop-debug` next to
the regular app.
Versions come from `scripts/fork-version.sh`:

- Tag builds use the tag as-is.
- Branch builds use `v<upstream desktop version>-<short sha>`
  (e.g. `v0.5.5-abc12345`), where the base is the `version` field of
  `desktop/package.json` — the file upstream bumps on `main` with every
  desktop release. This anchors fork artifacts to the upstream release they
  contain without mirroring upstream tags into the fork (every pushed tag
  would trigger its own CI pipeline).

## Commit conventions

- Every commit is DCO signed-off (`git commit -s`; rebases use `--signoff`).
- Author/committer identity is `cloudfodder <cloudfodder@relay.tools>`.
