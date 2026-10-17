#!/usr/bin/env bash
# sim-inpod.sh — run the Do-2 acceptance (verify-derived.sh inpod) WITHOUT a container
# runtime, by booting a faithful derived-FROM filesystem simulation and executing the
# real verify-derived.sh inpod checks against it. Validated 2026-10-16 (REL-1313 run
# 3b02ad90): reproduces INPOD VERIFY PASS with the compiled upstream server, the
# docker-patch guard layer, and the deploy/ overlay — the exact derived-image layering.
#
# What it simulates (and how each piece mirrors the derived image):
#   /app tree            = repo clone with compiled server/dist (upstream app layers)
#   guard .js            = docker-patch/private-hostname-guard.js (the mandatory COPY)
#   .paperclip-build-commit at the tree root = the upstream image marker
#     (/app/.paperclip-build-commit; readBuildCommit resolves ../../ from server/dist)
#   env                  = deliberately WITHOUT PAPERCLIP_BUILD_COMMIT: upstream's
#     derived image carries native provenance via the marker/config Env, NOT a
#     hand-set env, so the sim proves the real fallback chain.
#   DB                   = throwaway embedded-postgres (never the production DATABASE_URL!)
#   bind                 = 127.0.0.N loopback alias + deployment mode/exposure matching
#     the chart (authenticated/private) so the private-hostname guard is ACTIVE.
#
# Requires: node, a repo clone with server/dist built + node_modules (this pod's /app),
# and @embedded-postgres binaries present. Usage:
#   SIM_DIR=<scratch> sim-inpod.sh [repo_root=/app]
set -euo pipefail
REPO="${2:-/app}"
SIM="${SIM_DIR:?SIM_DIR required}"
PGPORT_SIM="${PGPORT_SIM:-54331}"
BIND_HOST="${BIND_HOST:-127.0.0.5}"
EXPECT_SHA="${EXPECT_SHA:?EXPECT_SHA=<40-hex upstream source SHA>}"
BUNDLE="$(cd "$(dirname "$0")/../.." && pwd)"
[[ "$EXPECT_SHA" =~ ^[0-9a-f]{40}$ ]] || { echo "EXPECT_SHA must be 40-hex" >&2; exit 2; }

echo "==> [1/6] isolated postgres on :$PGPORT_SIM (throwaway DB)"
PGBIN=$(ls -d /app/node_modules/.pnpm/@embedded-postgres+linux-x64@*/node_modules/@embedded-postgres/linux-x64/native/bin 2>/dev/null | head -1)
[[ -x "$PGBIN/pg_ctl" ]] || { echo "embedded-postgres binaries not found" >&2; exit 2; }
mkdir -p "$SIM/pg"
[[ -f "$SIM/pg/PG_VERSION" ]] || "$PGBIN/initdb" -D "$SIM/pg" -U bionic --auth=trust >/dev/null
"$PGBIN/pg_ctl" -D "$SIM/pg" start -o "-p $PGPORT_SIM -k $SIM -c listen_addresses='127.0.0.1'" -l "$SIM/pg.log" >/dev/null 2>&1 || true
node -e "
const P='/app/node_modules/.pnpm/postgres@3.4.9_patch_hash=sryle6qd5qfmnxvoebal4gashi/node_modules/postgres';
import('file:'+P+'/src/index.js').then(async m=>{
  const sql=m.default({host:'127.0.0.1',port:$PGPORT_SIM,user:'bionic',database:'postgres'});
  await sql\`DROP DATABASE IF EXISTS bionic_sim\`;
  await sql\`CREATE DATABASE bionic_sim\`;
  console.log('fresh DB ready'); await sql.end();
});"

echo "==> [2/6] derived-FROM tree (compiled app + guard layer + marker)"
if [[ ! -f "$SIM/app-root/server/dist/index.js" ]]; then
  mkdir -p "$SIM/app-root"
  cp -a "$REPO/server" "$REPO/package.json" "$REPO/deploy" "$SIM/app-root/"
  cp -a "$REPO/node_modules/." "$SIM/app-root/node_modules/"
  ln -sfn "$REPO/node_modules/.pnpm" "$SIM/app-root/node_modules/.pnpm"
  ln -sfn "$REPO/server/node_modules" "$SIM/app-root/server/node_modules"
fi
cp "$BUNDLE/docker-patch/private-hostname-guard.js" "$SIM/app-root/server/dist/middleware/private-hostname-guard.js"
sha_src=$(sha256sum "$BUNDLE/docker-patch/private-hostname-guard.js" | cut -d" " -f1)
sha_sim=$(sha256sum "$SIM/app-root/server/dist/middleware/private-hostname-guard.js" | cut -d" " -f1)
[[ "$sha_src" == "$sha_sim" ]] || { echo "guard layer hash mismatch" >&2; exit 1; }
echo "$EXPECT_SHA" > "$SIM/app-root/.paperclip-build-commit"

echo "==> [3/6] boot server (authenticated+private: guard ACTIVE; NO env stamp)"
mkdir -p "$SIM/home2/instances/default"
setsid nohup env -i PATH=/usr/local/bin:/usr/bin:/bin HOME=/paperclip \
  DATABASE_URL="postgres://bionic@127.0.0.1:$PGPORT_SIM/bionic_sim" \
  BETTER_AUTH_SECRET=sim-rel1313-secret \
  PAPERCLIP_DEPLOYMENT_MODE=authenticated PAPERCLIP_DEPLOYMENT_EXPOSURE=private \
  PAPERCLIP_BIND=custom PAPERCLIP_BIND_HOST="$BIND_HOST" \
  PAPERCLIP_HOME="$SIM/home2" \
  PAPERCLIP_MIGRATION_AUTO_APPLY=true PAPERCLIP_SECRETS_PROVIDER=local \
  node --import "$REPO/node_modules/.pnpm/tsx@4.23.12/node_modules/tsx/dist/loader.mjs" \
  "$SIM/app-root/server/dist/index.js" > "$SIM/sim-boot.log" 2>&1 < /dev/null &
SIM_PID=$!

echo "==> [4/6] wait for listen (migrations on first boot take ~2-3 min)"
for i in $(seq 1 30); do
  kill -0 $SIM_PID 2>/dev/null || { echo "sim server died:"; tail -3 "$SIM/sim-boot.log"; exit 1; }
  grep -q "recovery complete on $BIND_HOST" "$SIM/sim-boot.log" 2>/dev/null && break
  sleep 8
done
PORT=$(grep -o "recovery complete on $BIND_HOST:[0-9]*" "$SIM/sim-boot.log" | head -1 | cut -d: -f3)
[[ -n "$PORT" ]] || { echo "server did not bind" >&2; exit 1; }

echo "==> [5/6] verify-derived.sh inpod (the acceptance checks)"
# rewrite /app paths in the script to the sim root (script is otherwise unmodified)
sed "s|/app/|$SIM/app-root/|g" "$BUNDLE/deploy/docker/verify-derived.sh" > "$SIM/verify-sim.sh"
HEALTH_URL="http://$BIND_HOST:$PORT/api/health" EXPECT_SHA="$EXPECT_SHA" bash "$SIM/verify-sim.sh" inpod

echo "==> [6/6] cleanup"
kill $SIM_PID 2>/dev/null || true
"$PGBIN/pg_ctl" -D "$SIM/pg" stop -m fast >/dev/null 2>&1 || true
echo "SIM INPOD: PASS (native provenance, overlay, launcher, guard patch — no container needed)"
