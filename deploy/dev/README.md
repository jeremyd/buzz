# buzz — in-cluster development environment

Everything (toolchains, builds, tests, image builds, helm deploys) runs inside the
`buzz` namespace on a Kubernetes cluster; nothing is installed on the local machine.
Local disk only holds source text files.

Point `KUBECONFIG` at a cluster with a default StorageClass before running the
`wb-*` just recipes (defined in `wb.just`, imported by the root `Justfile`).

## Components

| Component | Purpose |
|---|---|
| `workbench` Deployment | debian + C toolchain; Rust/Node/just come from the repo's own hermit env (`. ./bin/activate-hermit`), cached on a 100Gi PVC (`/work`). All builds/tests run here via `kubectl exec`. `HERMIT_STATE_DIR` / `CARGO_HOME` on the PVC keep toolchains and build caches across pod restarts. |
| `buildkitd` Deployment | Container image builds (`buildctl`, `BUILDKIT_HOST=tcp://buildkitd:1234`), 50Gi cache PVC. |
| Helm release `buzz` | The relay itself, deployed from `deploy/charts/buzz` with the Quickstart profile (in-cluster Postgres + Redis + MinIO) — values in `deploy/local/values-arrowhead.yaml`. |

## Bootstrap

```sh
just wb-bootstrap     # kubectl apply -f deploy/dev/*.yaml
# first start installs kubectl/helm/buildctl to the PVC; watch with:
kubectl -n buzz logs -f deploy/workbench
```

Images go to the in-cluster registry (`registry.feeds.relay.tools`, plain
`registry:3` in the feeds-dev namespace behind ingress + htpasswd) — internal
testing only. To publish publicly instead, create a GitLab project under
`opensauce/` on code.relay.tools and point `wb_image` (wb.just) + the values
file at `artifacts.relay.tools/opensauce/buzz`.

One-time registry auth (pull + push):

```sh
# pull secret for the relay Deployment (copy from an existing namespace)
kubectl get secret regcred -n newlay -o yaml \
  | sed 's/namespace: newlay/namespace: buzz/' | kubectl apply -f -

# push auth for buildctl inside the workbench (DOCKER_CONFIG=/work/.docker)
WB=$(kubectl -n buzz get pod -l app=workbench -o jsonpath='{.items[0].metadata.name}')
kubectl get secret regcred -n buzz -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d \
  | kubectl -n buzz exec -i "$WB" -- bash -c 'mkdir -p /work/.docker && cat > /work/.docker/config.json'
```

DNS (once): create an A record for the relay host (e.g. `buzz.relay.tools`)
pointing at the cluster's ingress IP; cert-manager issues TLS via the
`letsencrypt-prod` ClusterIssuer referenced in the values file.

## Day-to-day (from repo root)

```sh
just wb-sync          # tar local source into the workbench (/work/src/buzz)
just wb-test          # unit tests in-cluster (no infra needed)
just wb-check         # full `just ci` in-cluster
just wb-image [tag]   # buildctl build + push registry.feeds.relay.tools/opensauce/buzz:<tag>
just wb-deploy [tag]  # helm upgrade --install into the buzz namespace
just wb [tag]         # sync → image → deploy in one shot
just wb-cli           # build buzz-cli in-cluster → .devlogs/buzz
just wb-desktop       # build the Tauri desktop client in-cluster → .devlogs/buzz-desktop
just wb-apk           # build the Flutter debug APK in-cluster → .devlogs/buzz-mobile-debug.apk
just apk-install      # adb install + launch on the attached phone (device=<serial> to override)
just apk-logs         # stream the app's logcat from the phone
just wb-mobile        # wb-apk + apk-install in one shot
just wb-shell         # interactive shell in the workbench
just wb-logs          # tail the deployed relay
```

Per repo policy (`AGENTS.md`), `flutter build` never runs on the local
machine — `wb-apk` runs it inside the workbench pod only. iOS builds need
macOS and are out of scope here.

The first `wb-image` is a cold cargo build (long); later builds reuse the
buildkitd cache PVC + the `:buildcache` registry cache.

Integration tests (`just test`) need Postgres/Redis — point `DATABASE_URL` /
`REDIS_URL` at a scratch database, never at the deployed relay's quickstart
Postgres database.
