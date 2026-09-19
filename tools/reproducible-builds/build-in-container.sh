#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
IMAGE_NAME="${BITCHAT_CONTAINER_IMAGE:-bitchat-android-reproducible-builder:21.0.11}"
OUTPUT_DIR="${1:-$PROJECT_ROOT/.reproducible-build/release}"
GRADLE_HOME_NAME="${BITCHAT_CONTAINER_GRADLE_HOME_NAME:-gradle-home-container}"
CONTAINER_LOCAL_PROPERTIES="$SCRIPT_DIR/container-local.properties"
# app/google-services.json is not version controlled, so it never reaches the
# staging tree that git archive produces. It is injected instead: mounted
# read-only here, written from a repository secret in CI.
GOOGLE_SERVICES_JSON="${BITCHAT_GOOGLE_SERVICES_JSON:-$PROJECT_ROOT/app/google-services.json}"

if ! command -v docker >/dev/null 2>&1; then
  echo "error: Docker is required for the canonical container build" >&2
  exit 1
fi
if [ ! -f "$CONTAINER_LOCAL_PROPERTIES" ]; then
  echo "error: missing canonical container local.properties" >&2
  exit 1
fi
if [ ! -f "$GOOGLE_SERVICES_JSON" ]; then
  echo "error: missing google-services.json: $GOOGLE_SERVICES_JSON" >&2
  echo "       set BITCHAT_GOOGLE_SERVICES_JSON or see docs/reproducible-builds.md" >&2
  exit 1
fi
GOOGLE_SERVICES_JSON="$(cd "$(dirname "$GOOGLE_SERVICES_JSON")" && pwd)/$(basename "$GOOGLE_SERVICES_JSON")"

if [ "${BITCHAT_ALLOW_DIRTY:-0}" != "1" ] && [ -n "$(git -C "$PROJECT_ROOT" status --porcelain --untracked-files=normal)" ]; then
  echo "error: reproducible builds require a clean source tree" >&2
  exit 1
fi

source_commit="$(git -C "$PROJECT_ROOT" rev-parse HEAD)"
source_date_epoch="$(git -C "$PROJECT_ROOT" log -1 --format=%ct)"

if ! [[ "$GRADLE_HOME_NAME" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "error: BITCHAT_CONTAINER_GRADLE_HOME_NAME must be a simple directory name" >&2
  exit 1
fi

mkdir -p "$PROJECT_ROOT/.reproducible-build"
staging_root="$(mktemp -d "$PROJECT_ROOT/.reproducible-build/source.XXXXXX")"
cleanup() {
  rm -rf -- "$staging_root"
}
trap cleanup EXIT

# Build from the exact committed tree rather than the host checkout. This keeps
# ignored files and Android Studio state out of the canonical build and avoids
# nested bind mounts, which are not portable across Docker runtimes.
git -C "$PROJECT_ROOT" archive --format=tar "$source_commit" |
  tar -xf - -C "$staging_root"
cp "$CONTAINER_LOCAL_PROPERTIES" "$staging_root/local.properties"

gradle_home="$PROJECT_ROOT/.reproducible-build/$GRADLE_HOME_NAME"
mkdir -p "$gradle_home"

# CI builds the image once and shares it with the jobs that only need to run
# inside it, so it can point this script at the image it already has.
if [ "${BITCHAT_REUSE_CONTAINER_IMAGE:-0}" = "1" ]; then
  if ! docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
    echo "error: BITCHAT_REUSE_CONTAINER_IMAGE=1 but $IMAGE_NAME is not present" >&2
    exit 1
  fi
else
  docker build \
    --platform linux/amd64 \
    --file "$SCRIPT_DIR/Dockerfile" \
    --tag "$IMAGE_NAME" \
    "$PROJECT_ROOT"
fi

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"

docker run \
  --rm \
  --platform linux/amd64 \
  --user "$(id -u):$(id -g)" \
  --env BITCHAT_ALLOW_DIRTY="${BITCHAT_ALLOW_DIRTY:-0}" \
  --env BITCHAT_GOOGLE_SERVICES_JSON=/injected/google-services.json \
  --env BITCHAT_GRADLE_USER_HOME=/gradle-home \
  --env BITCHAT_SOURCE_COMMIT="$source_commit" \
  --env BITCHAT_SOURCE_TREE_VERIFIED=1 \
  --env HOME=/tmp/build-home \
  --env SOURCE_DATE_EPOCH="$source_date_epoch" \
  --volume "$staging_root:/workspace" \
  --volume "$GOOGLE_SERVICES_JSON:/injected/google-services.json:ro" \
  --volume "$gradle_home:/gradle-home" \
  --volume "$OUTPUT_DIR:/output" \
  "$IMAGE_NAME" \
  /output
