# FORK.md — Maintaining the relay.tools Fork

This repository is a fork of [block/buzz](https://github.com/block/buzz)
maintained at `code.relay.tools` (GitLab). This document describes how the
fork is kept current and how its artifacts are versioned.

## Remotes

| Remote | URL | Purpose |
|--------|-----|---------|
| `origin` | `ssh://git@code.relay.tools:2222/forks/buzz.git` | The fork (GitLab) — `main` is the published branch |
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
2. **Backup** — `git branch backup/float-<date> main`.
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

## Package versioning

GitLab CI (`.gitlab-ci.yml`) publishes Linux/Windows desktop bundles, an
Arch package, and a signed Android APK to the project package registry.
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
