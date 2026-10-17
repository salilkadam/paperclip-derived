#!/usr/bin/env bash
# REL-1313: build + push the derived bionic image (multi-arch, digest-pinned,
# COPY-only overlay => zero compile: buildx re-pushes unchanged base layers by
# digest reference and uploads only the new overlay layers).
#
# Requires: docker buildx (with a multi-platform builder), registry logins for
# pulling ghcr.io/paperclipai/paperclip and pushing $PUSH_REPO.
#
# Usage:
#   UPSTREAM_INDEX=<40-hex index digest> SOURCE_COMMIT=<40-hex> \
#     [OVERLAY_DIR=<repo root with deploy/ + docker-patch/>] \
#     [PUSH_REPO=docker4zerocool/bionic] [PUSH_TAG=derived-<shortsha>-<n>] \
#     [ARCHES="amd64 arm64"] deploy/docker/build-derived.sh
set -euo pipefail

: "${UPSTREAM_INDEX:?UPSTREAM_INDEX=<40-hex multi-arch index digest of ghcr.io/paperclipai/paperclip>}"
: "${SOURCE_COMMIT:?SOURCE_COMMIT=<40-hex upstream source SHA (org.opencontainers.image.revision)>}"
UPSTREAM_REPO="${UPSTREAM_REPO:-ghcr.io/paperclipai/paperclip}"
OVERLAY_DIR="${OVERLAY_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
PUSH_REPO="${PUSH_REPO:-docker4zerocool/bionic}"
PUSH_TAG="${PUSH_TAG:-derived-${SOURCE_COMMIT:0:9}-$(date -u +%Y%m%d%H%M)}"
ARCHES="${ARCHES:-amd64 arm64}"
BUILDER="${BUILDER:-}"

[[ "$UPSTREAM_INDEX" =~ ^[0-9a-f]{64}$ ]] || { echo "UPSTREAM_INDEX must be a 40-hex digest" >&2; exit 2; }
[[ "$SOURCE_COMMIT" =~ ^[0-9a-f]{40}$ ]] || { echo "SOURCE_COMMIT must be a 40-hex full SHA" >&2; exit 2; }
[[ -d "$OVERLAY_DIR/deploy" ]] || { echo "missing $OVERLAY_DIR/deploy" >&2; exit 2; }
[[ -f "$OVERLAY_DIR/docker-patch/private-hostname-guard.js" ]] || {
  echo "missing $OVERLAY_DIR/docker-patch/private-hostname-guard.js (mandatory guard patch)" >&2; exit 2; }

BUILDER_ARGS=()
[[ -n "$BUILDER" ]] && BUILDER_ARGS=(--builder "$BUILDER")

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> Resolving per-arch digests from index $UPSTREAM_INDEX"
for arch in $ARCHES; do
  digest=$(docker buildx imagetools inspect --raw "${UPSTREAM_REPO}@sha256:${UPSTREAM_INDEX}" \
    | python3 -c "
import json,sys
idx=json.load(sys.stdin)
for m in idx['manifests']:
    p=m.get('platform') or {}
    if p.get('os')=='linux' and p.get('architecture')=='$arch':
        print(m['digest']); break
")
  [[ -n "$digest" ]] || { echo "arch $arch not found in pinned index" >&2; exit 3; }
  echo "    linux/$arch -> $digest"
  echo "linux/$arch=$digest" >> "$WORK/arches"
done

echo "==> Building + pushing per-arch derived images"
for arch in $ARCHES; do
  digest=$(sed -n "s|linux/$arch=||p" "$WORK/arches")
  docker buildx build "${BUILDER_ARGS[@]}" \
    --platform "linux/$arch" \
    --file "$OVERLAY_DIR/deploy/docker/Dockerfile.derived" \
    --build-arg "UPSTREAM_REF=${UPSTREAM_REPO}@${digest}" \
    --build-arg "SOURCE_COMMIT=${SOURCE_COMMIT}" \
    --build-arg "UPSTREAM_INDEX=sha256:${UPSTREAM_INDEX}" \
    --tag "${PUSH_REPO}:${PUSH_TAG}-$arch" \
    --push \
    "$OVERLAY_DIR"
done

echo "==> Assembling multi-arch index"
IDX_ARGS=()
for arch in $ARCHES; do IDX_ARGS+=("${PUSH_REPO}:${PUSH_TAG}-$arch"); done
docker buildx imagetools create \
  "${BUILDER_ARGS[@]}" \
  --tag "${PUSH_REPO}:${PUSH_TAG}" \
  "${IDX_ARGS[@]}"

echo
echo "DONE: ${PUSH_REPO}:${PUSH_TAG} (linux/$ARCHES, base index sha256:${UPSTREAM_INDEX:0:12}…, source ${SOURCE_COMMIT:0:9})"
echo "Next: deploy/docker/verify-derived.sh provenance ${PUSH_REPO}:${PUSH_TAG}-amd64"
