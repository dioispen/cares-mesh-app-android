#!/usr/bin/env bash

# Runs an arbitrary command inside the canonical toolchain image against the
# current working tree.
#
# build-in-container.sh is the release path: it builds from `git archive` of the
# committed tree and refuses a dirty checkout. This script is the everyday path
# used by CI for tests, lint, and debug APKs, so it bind-mounts the checkout as
# it is. Both use the same image, so local, CI, and release share one toolchain.
#
#   tools/reproducible-builds/run-in-container.sh ./gradlew testDebugUnitTest
#   tools/reproducible-builds/run-in-container.sh bash -c 'cd flutter_ui && flutter test'

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONTAINER_LOCAL_PROPERTIES="$SCRIPT_DIR/container-local.properties"
GRADLE_HOME_NAME="${BITCHAT_CONTAINER_GRADLE_HOME_NAME:-gradle-home-ci}"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/TOOLCHAIN.env"

IMAGE_NAME="bitchat-android-reproducible-builder:${JAVA_VERSION%%+*}-flutter${FLUTTER_VERSION}"

# See build-in-container.sh: Git Bash rewrites the container side of --volume
# into a Windows path, leaving /workspace empty. No-op on Linux.
if command -v cygpath >/dev/null 2>&1; then
  MSYS_DOCKER_ENV=(env "MSYS2_ARG_CONV_EXCL=*")
  docker_host_path() { cygpath -w "$1"; }
else
  MSYS_DOCKER_ENV=()
  docker_host_path() { printf '%s' "$1"; }
fi

if [ "$#" -eq 0 ]; then
  echo "usage: run-in-container.sh COMMAND [ARG...]" >&2
  exit 1
fi
if ! command -v docker >/dev/null 2>&1; then
  echo "error: Docker is required for the canonical toolchain" >&2
  exit 1
fi
if ! [[ "$GRADLE_HOME_NAME" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "error: BITCHAT_CONTAINER_GRADLE_HOME_NAME must be a simple directory name" >&2
  exit 1
fi

if [ "${BITCHAT_SKIP_IMAGE_BUILD:-0}" != "1" ]; then
  docker build \
    --platform linux/amd64 \
    --file "$SCRIPT_DIR/Dockerfile" \
    --tag "$IMAGE_NAME" \
    "$PROJECT_ROOT"
fi

# Gradle reads the repository-root local.properties, which is gitignored and on
# a developer machine points at a host Android SDK. Swap in the canonical one
# for the duration of the run and put the original back afterwards.
mkdir -p "$PROJECT_ROOT/.reproducible-build"

host_local_properties="$PROJECT_ROOT/local.properties"
backup_local_properties=""
restore_local_properties() {
  if [ -n "$backup_local_properties" ]; then
    mv -f "$backup_local_properties" "$host_local_properties"
  else
    rm -f "$host_local_properties"
  fi
}
if [ -f "$host_local_properties" ]; then
  backup_local_properties="$PROJECT_ROOT/.reproducible-build/local.properties.host-backup"
  mv -f "$host_local_properties" "$backup_local_properties"
fi
trap restore_local_properties EXIT
cp "$CONTAINER_LOCAL_PROPERTIES" "$host_local_properties"

gradle_home="$PROJECT_ROOT/.reproducible-build/$GRADLE_HOME_NAME"
mkdir -p "$gradle_home"

# HOME is a scratch path that does not exist in the image, and flutter_ui/
# .android is `flutter pub get` output that settings.gradle.kts needs during
# settings evaluation. Both are prepared before the requested command runs;
# BITCHAT_SKIP_FLUTTER_PREPARE=1 skips the second for non-Gradle commands.
container_script='mkdir -p "$HOME"; '
if [ "${BITCHAT_SKIP_FLUTTER_PREPARE:-0}" != "1" ]; then
  container_script+='tools/reproducible-builds/prepare-flutter-module.sh; '
fi
container_script+="$(printf '%q ' "$@")"

"${MSYS_DOCKER_ENV[@]}" docker run \
  --rm \
  --platform linux/amd64 \
  --user "$(id -u):$(id -g)" \
  --env BITCHAT_ALLOW_DIRTY=1 \
  --env BITCHAT_GRADLE_USER_HOME=/gradle-home \
  --env GRADLE_USER_HOME=/gradle-home \
  --env HOME=/tmp/build-home \
  --volume "$(docker_host_path "$PROJECT_ROOT"):/workspace" \
  --volume "$(docker_host_path "$gradle_home"):/gradle-home" \
  --entrypoint /bin/bash \
  "$IMAGE_NAME" \
  -euo pipefail -c "$container_script"
