#!/usr/bin/env bash
# REL-1313 verification:
#   provenance <image-ref>      — no-boot check: manifest/config shows the native
#                                 PAPERCLIP_BUILD_COMMIT env stamp (full 40-hex)
#                                 matching org.opencontainers.image.revision.
#                                 Pass a TAG or PER-ARCH digest, not a multi-arch index.
#   inpod                       — run INSIDE the deployed pod (needs HEALTH_URL,
#                                 EXPECT_SHA): Do-2 acceptance.
# Registry auth: ghcr.io is anonymous-pull; private registries: set REG_USER/REG_TOKEN
# or rely on ~/.docker/config.json (this script only reads manifests via HTTPS).
set -euo pipefail

MODE="${1:?mode: provenance|inpod}"
REF="${2:-}"

die(){ echo "FAIL: $*" >&2; exit 1; }

manifest_fetch(){ # url accept outfile [tok]
  local url="$1" accept="$2" out="$3" tok="${4:-}" attempt authh
  [[ -n "$tok" ]] && authh=(-H "Authorization: Bearer $tok") || authh=()
  for attempt in 1 2 3 4 5; do
    # ghcr blobs 307 to a signed URL; curl -f can write 0 bytes when forwarding
    # the bearer there, so fetch a manifest-redirect manually without auth.
    if curl -fsS --max-time 30 "${authh[@]}" -H "Accept: $accept" "$url" -o "$out" \
       && python3 -m json.tool "$out" >/dev/null 2>&1; then return 0; fi
    loc=$(curl -sS --max-time 30 "${authh[@]}" -H "Accept: $accept" -o /dev/null -w '%{redirect_url}' "$url" || true)
    if [[ -n "$loc" ]] && curl -fsS --max-time 30 "$loc" -o "$out" \
       && python3 -m json.tool "$out" >/dev/null 2>&1; then return 0; fi
    sleep $((attempt*2))
  done
  return 1
}

split_ref(){ # sets HOST/REPO/TAGORIGEST
  local r="$REF"
  HOST="${r%%/*}"; local rest="${r#*/}"
  if [[ "$HOST" == "$r" ]]; then HOST="docker.io"; rest="$r"; fi
  if [[ "$rest" == *"@"* ]]; then REPO="${rest%@*}"; TAGORIGEST="${rest##*@}";
  elif [[ "$rest" == *":"* && "$rest" != *":"*"/"* ]]; then REPO="${rest%:*}"; TAGORIGEST=":${rest##*:}";
  else REPO="$rest"; TAGORIGEST=":latest"; fi
}

provenance(){
  [[ -n "$REF" ]] || die "usage: verify-derived.sh provenance <image-ref (tag or per-arch digest)>"
  split_ref
  case "$HOST" in
    ghcr.io) BASE="https://ghcr.io";
             TOK=$(curl -fsS --max-time 20 "https://ghcr.io/token?scope=repository:$REPO:pull" | python3 -c 'import json,sys;print(json.load(sys.stdin)["token"])') ;;
    docker.io) BASE="https://registry-1.docker.io"
             TOK=$(curl -fsS --max-time 20 "https://auth.docker.io/token?service=registry.docker.io&scope=repository:$REPO:pull" | python3 -c 'import json,sys;print(json.load(sys.stdin)["token"])') ;;
    *) BASE="https://$HOST"
       if [[ -n "${REG_USER:-}" ]]; then
         TOK=$(curl -fsS --max-time 20 -u "$REG_USER:${REG_TOKEN:-}" "https://$HOST/v2/token?scope=repository:$REPO:pull" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("token",""))' )
         [[ -n "$TOK" ]] || TOK="${REG_TOKEN:-}"
       else TOK="" ; fi ;;
  esac
  AUTH="Authorization: Bearer $TOK"
  ACCEPT_M="application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json"
  W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
  manifest_fetch "$BASE/v2/$REPO/manifests/$TAGORIGEST" "$ACCEPT_M,application/vnd.oci.image.index.v1+json" "$W/m.json" "$TOK" \
    || die "cannot fetch manifest for $REF"
  mt=$(python3 -c 'import json;print(json.load(open("'"$W"'/m.json")).get("mediaType",""))')
  case "$mt" in
    *index*|*manifest.list*)
  [[ -n "${PUSH_REPO:-}" && -n "${PUSH_TAG:-}" ]] && hint=" (e.g. ${PUSH_REPO}:${PUSH_TAG}-amd64)" || hint=" (a per-arch manifest digest)"
  die "$REF is a multi-arch index — pass a per-arch digest$hint or a single-arch tag" ;;
  esac
  cfg=$(python3 -c 'import json;print(json.load(open("'"$W"'/m.json"))["config"]["digest"])')
  manifest_fetch "$BASE/v2/$REPO/blobs/$cfg" "application/vnd.oci.image.config.v1+json, application/octet-stream" "$W/cfg.json" "$TOK" \
    || die "cannot fetch config blob $cfg"
  python3 - "$W/cfg.json" <<'PY'
import json,re,sys
c=json.load(open(sys.argv[1]))
env=dict(kv.split("=",1) for kv in c["config"].get("Env",[]) if "=" in kv)
rev=(c["config"].get("Labels") or {}).get("org.opencontainers.image.revision","")
bc=env.get("PAPERCLIP_BUILD_COMMIT","")
full=re.compile(r"^[0-9a-f]{40}$")
if not full.match(bc):
    print(f"FAIL: PAPERCLIP_BUILD_COMMIT missing/not-40-hex (got {bc!r}). This is a pre-stamp image — do NOT derive FROM it.")
    sys.exit(1)
if rev and rev != bc:
    print(f"FAIL: revision label {rev} != env stamp {bc}")
    sys.exit(1)
print(f"PASS: native provenance stamp {bc} (revision label agrees: {rev or 'n/a'})")
PY
}

inpod(){
  [[ "${EUID:-$(id -u)}" -ge 0 || -r /app/server/dist/middleware/private-hostname-guard.js ]] || true
  : "${HEALTH_URL:?HEALTH_URL=http://127.0.0.1:3100/api/health}"
  : "${EXPECT_SHA:?EXPECT_SHA=<upstream 40-hex SOURCE_COMMIT>}"
  [[ "$EXPECT_SHA" =~ ^[0-9a-f]{40}$ ]] || die "EXPECT_SHA must be 40-hex"
  h=$(mktemp); trap 'rm -f "$h"' EXIT
  curl -fsS --max-time 10 "$HEALTH_URL" -o "$h" || die "health endpoint unreachable"
  commit=$(python3 -c 'import json;print(json.load(open("'"$h"'")).get("commit") or "")')
  [[ "$commit" == "$EXPECT_SHA" ]] || die "health commit=$commit != EXPECT_SHA=$EXPECT_SHA"
  echo "PASS: /api/health commit == $EXPECT_SHA (native provenance)"
  ls /app/deploy/agents/*.md >/dev/null 2>&1 || die "/app/deploy/agents/*.md missing"
  echo "PASS: /app/deploy/* overlay present ($(ls /app/deploy/agents/*.md | wc -l) agent md files)"
  [[ -f /app/server/dist/index.js ]] || die "launcher server/dist/index.js missing"
  [[ -x /usr/local/bin/docker-entrypoint.sh || -f /usr/local/bin/docker-entrypoint.sh ]] || die "docker-entrypoint.sh missing"
  grep -q "/api/health" /app/server/dist/middleware/private-hostname-guard.js \
    || die "guard patch (health early-return) not applied in deployed image"
  echo "PASS: launcher paths intact + guard patch applied"
  echo "INPOD VERIFY: PASS"
}

case "$MODE" in
  provenance) provenance ;;
  inpod) inpod ;;
  *) die "unknown mode $MODE (provenance|inpod)" ;;
esac
