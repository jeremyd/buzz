# In-cluster development workbench (deploy/dev/README.md). Everything — builds,
# tests, image builds, helm deploys — runs inside the `buzz` namespace; the local
# machine only holds source text. Point KUBECONFIG at the cluster first.

wb_ns := "buzz"
# In-cluster registry (feeds-dev ns, exposed at this host via ingress + htpasswd;
# `regcred` holds the creds). Internal testing only — not a public registry.
wb_image := "registry.feeds.relay.tools/opensauce/buzz"
wb_values := "deploy/local/values-arrowhead.yaml"

# pod name of the workbench (resolved lazily inside recipes)
_wb_pod := 'kubectl -n ' + wb_ns + ' get pod -l app=workbench -o jsonpath={.items[0].metadata.name}'

# Apply the dev-namespace manifests (namespace, workbench, buildkitd, RBAC)
wb-bootstrap:
    kubectl apply -f deploy/dev/00-namespace.yaml
    kubectl apply -f deploy/dev/10-workbench.yaml -f deploy/dev/20-buildkitd.yaml -f deploy/dev/50-workbench-nginx-rbac.yaml

# Sync local source into the workbench at /work/src/buzz (prune first so
# locally-deleted files don't linger; target/ and node_modules are pod-side).
# The synced tree is committed to a pod-local git repo so the file-size
# ratchet (scripts/check-file-sizes-core.mjs) has a resolvable base — wb-run
# pins CHECK_FILE_SIZES_BASE=HEAD, making the in-cluster check a no-op while
# GitLab CI (which has real history) still enforces the ratchet.
wb-sync:
    #!/usr/bin/env bash
    set -euo pipefail
    WB=$({{_wb_pod}})
    kubectl -n {{wb_ns}} exec "$WB" -- runuser -u dev -- bash -c \
      'cd /work/src/buzz 2>/dev/null && find . -maxdepth 1 ! -name . ! -name .git ! -name .hermit ! -name target ! -name node_modules ! -name .env -exec rm -rf {} + || true'
    tar -C . -cf - \
      --exclude .git --exclude .claude --exclude .hermit --exclude target --exclude node_modules \
      --exclude 'desktop/src-tauri/target' --exclude 'desktop/node_modules' \
      --exclude 'web/node_modules' --exclude 'admin-web/node_modules' \
      --exclude 'web/dist' --exclude 'admin-web/dist' \
      . | kubectl -n {{wb_ns}} exec -i "$WB" -- runuser -u dev -- bash -c 'mkdir -p /work/src/buzz && tar -xf - -C /work/src/buzz'
    kubectl -n {{wb_ns}} exec "$WB" -- runuser -u dev -- env HOME=/home/dev bash -c \
      'cd /work/src/buzz && { [ -d .git ] || git init -q -b main; } \
       && git add -A \
       && git -c user.email=wb@localhost -c user.name=workbench commit -q --allow-empty -m wb-sync'

# Run a command in the workbench with the repo's hermit env active. Runs as
# the non-root `dev` user — root would bypass file-permission semantics that
# several desktop tests depend on (chmod 000 → expect a read error).
wb-run cmd:
    #!/usr/bin/env bash
    set -euo pipefail
    WB=$({{_wb_pod}})
    kubectl -n {{wb_ns}} exec "$WB" -- runuser -u dev -- env HOME=/home/dev CHECK_FILE_SIZES_BASE=HEAD bash -c 'cd /work/src/buzz && . ./bin/activate-hermit && {{cmd}}'

# Fast unit tests in-cluster (no infrastructure needed)
wb-test: wb-sync (wb-run "just test-unit")

# fmt + clippy + unit tests + builds in-cluster
wb-check: wb-sync (wb-run "just ci")

# Build the relay image in-cluster via buildkitd and push to the registry
wb-image tag="dev": wb-sync
    #!/usr/bin/env bash
    set -euo pipefail
    WB=$({{_wb_pod}})
    kubectl -n {{wb_ns}} exec "$WB" -- bash -c '\
      cd /work/src/buzz && buildctl build \
        --frontend dockerfile.v0 \
        --local context=. --local dockerfile=. \
        --export-cache type=registry,ref={{wb_image}}:buildcache,mode=max \
        --import-cache type=registry,ref={{wb_image}}:buildcache \
        --output type=image,name={{wb_image}}:{{tag}},push=true'

# Install/upgrade the relay via the Helm chart (chart + values from the synced tree)
wb-deploy tag="dev":
    #!/usr/bin/env bash
    set -euo pipefail
    WB=$({{_wb_pod}})
    kubectl -n {{wb_ns}} exec "$WB" -- bash -c '\
      cd /work/src/buzz && helm dependency build deploy/charts/buzz \
      && helm upgrade --install buzz deploy/charts/buzz \
        -n {{wb_ns}} -f {{wb_values}} --set image.tag={{tag}} \
        --wait --timeout 300s'

# Build a workspace crate in the workbench and copy its binary to .devlogs/
wb-bin crate bin: (wb-run "cargo build --release -p " + crate)
    #!/usr/bin/env bash
    set -euo pipefail
    WB=$({{_wb_pod}})
    mkdir -p .devlogs
    kubectl -n {{wb_ns}} cp "$WB:/work/src/buzz/target/release/{{bin}}" ".devlogs/{{bin}}"
    chmod +x ".devlogs/{{bin}}"
    ls -la ".devlogs/{{bin}}"

# buzz CLI → .devlogs/buzz
wb-cli: (wb-bin "buzz-cli" "buzz")

# Build the Tauri desktop client in the workbench (raw binary, no bundling) and
# copy it to .devlogs/. Builds the real sidecar binaries first (Tauri's
# externalBin embeds buzz-acp/buzz-agent/buzz-dev-mcp/git-credential-nostr/buzz).
# Running locally needs webkit2gtk-4.1 + gtk3 installed.
wb-desktop: wb-sync (wb-run "cargo build --release -p buzz-acp -p buzz-agent -p buzz-dev-mcp -p git-credential-nostr -p buzz-cli && ./scripts/bundle-sidecars.sh && cd desktop && pnpm install --frozen-lockfile && pnpm tauri build --no-bundle")
    #!/usr/bin/env bash
    set -euo pipefail
    WB=$({{_wb_pod}})
    mkdir -p .devlogs
    kubectl -n {{wb_ns}} cp "$WB:/work/src/buzz/desktop/src-tauri/target/release/buzz-desktop" .devlogs/buzz-desktop
    chmod +x .devlogs/buzz-desktop
    ls -la .devlogs/buzz-desktop

# Build the Flutter debug APK in the workbench and copy it to .devlogs/.
# Per repo policy `flutter build` never runs on the local machine — the
# workbench pod is the only sanctioned place (user-approved exception).
wb-apk: wb-sync (wb-run "cd mobile && flutter pub get && flutter build apk --debug")
    #!/usr/bin/env bash
    set -euo pipefail
    WB=$({{_wb_pod}})
    mkdir -p .devlogs
    kubectl -n {{wb_ns}} cp \
      "$WB:/work/src/buzz/mobile/build/app/outputs/flutter-apk/app-debug.apk" \
      .devlogs/buzz-mobile-debug.apk
    ls -la .devlogs/buzz-mobile-debug.apk

# Default adb target: the Pixel 6 Pro (wireless adb). Override: just device=... apk-install
device := "10.0.0.161:33915"

# Install + launch the debug APK on the device (adb runs locally — the phone
# is attached to this machine, not the cluster)
apk-install:
    adb -s {{device}} install -r .devlogs/buzz-mobile-debug.apk
    adb -s {{device}} shell am start -n xyz.block.buzz.mobile/.MainActivity

# Stream the app's logcat from the device (Ctrl-C to stop)
apk-logs:
    adb -s {{device}} logcat -v time --pid="$(adb -s {{device}} shell pidof xyz.block.buzz.mobile | tr -d '\r')"

# One-shot mobile loop: build APK in-cluster → install + launch on the device
wb-mobile: wb-apk apk-install

# Interactive shell in the workbench
wb-shell:
    #!/usr/bin/env bash
    set -euo pipefail
    WB=$({{_wb_pod}})
    kubectl -n {{wb_ns}} exec -it "$WB" -- bash -l

# Tail the deployed relay's logs
wb-logs:
    kubectl -n {{wb_ns}} logs -f deploy/buzz

# One-shot inner loop: sync → image → deploy
wb tag="dev": (wb-image tag) (wb-deploy tag)
