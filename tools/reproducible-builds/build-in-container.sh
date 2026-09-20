#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONTAINER_LOCAL_PROPERTIES="$SCRIPT_DIR/container-local.properties"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/TOOLCHAIN.env"

# The Flutter version is part of the tag: bumping either half of the toolchain
# has to produce a different image. Old tags are left behind as dangling
# <none> images of several gigabytes each; `docker image prune` reclaims them.
IMAGE_NAME="bitchat-android-reproducible-builder:${JAVA_VERSION%%+*}-flutter${FLUTTER_VERSION}"
OUTPUT_DIR="${1:-$PROJECT_ROOT/.reproducible-build/release}"
GRADLE_HOME_NAME="${BITCHAT_CONTAINER_GRADLE_HOME_NAME:-gradle-home-container}"

# Under Git Bash (MSYS2) every argument that looks like an absolute POSIX path
# is rewritten before it reaches a native Windows executable, and that includes
# the container side of `--volume host:/workspace`. The mount then lands on a
# translated host path instead, so /workspace comes up empty and the entrypoint
# dies with "No such file or directory". Disabling the rewrite for the docker
# invocation means the host half has to be converted explicitly. Both the
# variable and cygpath are absent on Linux, where this collapses to a no-op.
if command -v cygpath >/dev/null 2>&1; then
  MSYS_DOCKER_ENV=(env "MSYS2_ARG_CONV_EXCL=*")
  docker_host_path() { cygpath -w "$1"; }
else
  MSYS_DOCKER_ENV=()
  docker_host_path() { printf '%s' "$1"; }
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "error: Docker is required for the canonical container build" >&2
  exit 1
fi
if [ ! -f "$CONTAINER_LOCAL_PROPERTIES" ]; then
  echo "error: missing canonical container local.properties" >&2
  exit 1
fi

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

docker build \
  --platform linux/amd64 \
  --file "$SCRIPT_DIR/Dockerfile" \
  --tag "$IMAGE_NAME" \
  "$PROJECT_ROOT"

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"

"${MSYS_DOCKER_ENV[@]}" docker run \
  --rm \
  --platform linux/amd64 \
  --user "$(id -u):$(id -g)" \
  --env BITCHAT_ALLOW_DIRTY="${BITCHAT_ALLOW_DIRTY:-0}" \
  --env BITCHAT_GRADLE_USER_HOME=/gradle-home \
  --env BITCHAT_SOURCE_COMMIT="$source_commit" \
  --env BITCHAT_SOURCE_TREE_VERIFIED=1 \
  --env HOME=/tmp/build-home \
  --env SOURCE_DATE_EPOCH="$source_date_epoch" \
  --volume "$(docker_host_path "$staging_root"):/workspace" \
  --volume "$(docker_host_path "$gradle_home"):/gradle-home" \
  --volume "$(docker_host_path "$OUTPUT_DIR"):/output" \
  "$IMAGE_NAME" \
  /output
