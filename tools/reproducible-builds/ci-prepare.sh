#!/usr/bin/env bash

# Prepares a CI job that runs inside the pinned toolchain image: injects the
# Firebase configuration from the repository secret, puts the Flutter SDK on
# PATH for the steps that follow, and generates the embedded module's Gradle
# glue. Release builds do the same work through build-release.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

if [ -z "${GOOGLE_SERVICES_JSON:-}" ]; then
  echo "error: the GOOGLE_SERVICES_JSON repository secret is not set" >&2
  echo "       see docs/reproducible-builds.md, \"Firebase configuration\"" >&2
  exit 1
fi
printf '%s' "$GOOGLE_SERVICES_JSON" > "$PROJECT_ROOT/app/google-services.json"
"$SCRIPT_DIR/install-google-services-json.sh" > /dev/null

export PATH="${FLUTTER_ROOT:-/opt/flutter}/bin:$PATH"
if [ -n "${GITHUB_PATH:-}" ]; then
  echo "${FLUTTER_ROOT:-/opt/flutter}/bin" >> "$GITHUB_PATH"
fi

# actions/checkout leaves a repository owned by a different user than the one
# the container steps run as; the Flutter tool shells out to git.
git config --global --add safe.directory "$PROJECT_ROOT" || true

"$SCRIPT_DIR/prepare-flutter.sh"
