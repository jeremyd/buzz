# CI infrastructure (arrowhead cluster)

Cluster-side config for the GitLab runner that builds this repo. The runner
itself is a helm release (`gitlab-runner` in namespace `gitlab-ci`); these
files are the source of truth for its values.

| File | Purpose |
|------|---------|
| `gitlab-runner-values.yaml` | Helm values for the `gitlab-runner` release (incl. cache config) |
| `runner-cache-pvc.yaml` | PVC that persists job caches across builds |

## Cache design

Jobs declare `cache:` in `.gitlab-ci.yml` (the desktop job caches
`.hermit-state/` and `.cargo/`). Without a backend those archives died with
each ephemeral build pod, so every build cold-downloaded the toolchain from
GitHub. The fix is deliberately simple — **a PVC, not S3/MinIO**:

- every build pod mounts the `runner-cache` PVC at `/cache`
- `cache_dir = "/cache"` makes the runner keep cache archives there
- arrowhead is single-node, so concurrent pods sharing one RWO
  local-path volume is safe

Losing the cache is harmless by design: delete the PVC (or the node dir
behind it) and the next build cold-starts and repopulates it.

The project's "use separate caches for protected branches" setting
(`ci_separated_caches`) is disabled so feature branches share main's
toolchain cache — this is a solo-maintainer fork, so cache poisoning
from untrusted branches is not a concern.

## Applying changes

```sh
kubectl apply -f runner-cache-pvc.yaml
helm upgrade gitlab-runner gitlab/gitlab-runner --version 0.90.1 \
  -n gitlab-ci -f gitlab-runner-values.yaml
```

The helm upgrade restarts the runner manager and **kills in-flight jobs** —
wait for running pipelines to finish first.
