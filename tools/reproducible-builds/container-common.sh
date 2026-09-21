# shellcheck shell=bash
#
# Shared by build-in-container.sh (the release path) and run-in-container.sh
# (tests, lint, and debug APKs in CI). Sourced, never executed.
#
# Everything the two drivers must agree on lives here and only here: which image
# they build and run, and the container environment around the build. If the
# two drifted apart, CI would quietly test on a different toolchain than the one
# that produces releases, which is the gap this image exists to close.
#
# The caller sets SCRIPT_DIR before sourcing this file.

PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck disable=SC2034 # used by both callers, not in this file
CONTAINER_LOCAL_PROPERTIES="$SCRIPT_DIR/container-local.properties"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/TOOLCHAIN.env"

# The Flutter version is part of the tag: bumping either half of the toolchain
# has to produce a different image. Old tags are left behind as dangling
# <none> images of several gigabytes each; `docker image prune` reclaims them.
IMAGE_NAME="bitchat-android-reproducible-builder:${JAVA_VERSION%%+*}-flutter${FLUTTER_VERSION}"

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

require_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "error: Docker is required for the canonical toolchain" >&2
    exit 1
  fi
}

# resolve_gradle_home DEFAULT_NAME
#
# Sets gradle_home to a Gradle user home under .reproducible-build/ and creates
# it. BITCHAT_CONTAINER_GRADLE_HOME_NAME overrides the name, so that two builds
# can be given independent caches.
resolve_gradle_home() {
  local name="${BITCHAT_CONTAINER_GRADLE_HOME_NAME:-$1}"
  if ! [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "error: BITCHAT_CONTAINER_GRADLE_HOME_NAME must be a simple directory name" >&2
    exit 1
  fi
  gradle_home="$PROJECT_ROOT/.reproducible-build/$name"
  mkdir -p "$gradle_home"
}

build_toolchain_image() {
  docker build \
    --platform linux/amd64 \
    --file "$SCRIPT_DIR/Dockerfile" \
    --tag "$IMAGE_NAME" \
    "$PROJECT_ROOT"
}

# run_toolchain_container [DOCKER_RUN_OPTION...] IMAGE [COMMAND...]
#
# `docker run` with the settings both drivers share: the platform, the calling
# user's IDs, the scratch HOME, and the Gradle user home from
# resolve_gradle_home. Callers append their own options, then the image and the
# command.
run_toolchain_container() {
  "${MSYS_DOCKER_ENV[@]}" docker run \
    --rm \
    --platform linux/amd64 \
    --user "$(id -u):$(id -g)" \
    --env BITCHAT_GRADLE_USER_HOME=/gradle-home \
    --env HOME=/tmp/build-home \
    --volume "$(docker_host_path "$gradle_home"):/gradle-home" \
    "$@"
}
