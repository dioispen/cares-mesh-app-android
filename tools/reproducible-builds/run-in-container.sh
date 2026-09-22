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
# shellcheck source=container-common.sh
source "$SCRIPT_DIR/container-common.sh"

if [ "$#" -eq 0 ]; then
  echo "usage: run-in-container.sh COMMAND [ARG...]" >&2
  exit 1
fi
require_docker
resolve_gradle_home gradle-home-ci

if [ "${BITCHAT_SKIP_IMAGE_BUILD:-0}" != "1" ]; then
  build_toolchain_image
fi

# Gradle reads the repository-root local.properties, which is gitignored and on
# a developer machine points at a host Android SDK. Swap in the canonical one
# for the duration of the run and put the original back afterwards.
mkdir -p "$PROJECT_ROOT/.reproducible-build"

host_local_properties="$PROJECT_ROOT/local.properties"
backup_local_properties="$PROJECT_ROOT/.reproducible-build/local.properties.host-backup"

# A leftover backup means an earlier run was killed before its trap could put
# the host file back, so the backup may be the only copy of it. Moving the
# current file over it would destroy it, and so would a concurrent run.
if [ -e "$backup_local_properties" ]; then
  echo "error: $backup_local_properties already exists" >&2
  echo "  An earlier run did not restore it. Move it back to local.properties" >&2
  echo "  (or delete it if it is stale) and try again." >&2
  exit 1
fi

# The trap is armed before anything is touched, so it must decide from what has
# actually happened rather than from which branch ran: an interrupt before the
# swap has to leave the host file exactly as it was.
installed_container_properties=0
restore_local_properties() {
  if [ -f "$backup_local_properties" ]; then
    mv -f "$backup_local_properties" "$host_local_properties"
  elif [ "$installed_container_properties" = 1 ]; then
    rm -f "$host_local_properties"
  fi
}
trap restore_local_properties EXIT

if [ -f "$host_local_properties" ]; then
  mv -f "$host_local_properties" "$backup_local_properties"
fi
installed_container_properties=1
cp "$CONTAINER_LOCAL_PROPERTIES" "$host_local_properties"

# HOME is a scratch path that does not exist in the image, and flutter_ui/
# .android is `flutter pub get` output that settings.gradle.kts needs during
# settings evaluation. Both are prepared before the requested command runs;
# BITCHAT_SKIP_FLUTTER_PREPARE=1 skips the second for non-Gradle commands.
# shellcheck disable=SC2016 # $HOME is meant to expand inside the container
container_script='mkdir -p "$HOME"; '
if [ "${BITCHAT_SKIP_FLUTTER_PREPARE:-0}" != "1" ]; then
  container_script+='tools/reproducible-builds/prepare-flutter-module.sh; '
fi
container_script+="$(printf '%q ' "$@")"

# Unlike the release path, the command here calls Gradle directly rather than
# through build-release.sh, so GRADLE_USER_HOME itself has to point at the mount.
run_toolchain_container \
  --env BITCHAT_ALLOW_DIRTY=1 \
  --env GRADLE_USER_HOME=/gradle-home \
  --volume "$(docker_host_path "$PROJECT_ROOT"):/workspace" \
  --entrypoint /bin/bash \
  "$IMAGE_NAME" \
  -euo pipefail -c "$container_script"
