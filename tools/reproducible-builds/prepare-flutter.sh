#!/usr/bin/env bash

# Prepares the embedded Flutter module so Gradle can configure the build.
#
# settings.gradle.kts applies flutter_ui/.android/include_flutter.groovy, which
# the Flutter tool generates from the module's pubspec. That directory is not
# version controlled, so every build environment — container, CI and a fresh
# developer checkout — has to run this before the first Gradle invocation.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FLUTTER_MODULE_DIR="$PROJECT_ROOT/flutter_ui"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/TOOLCHAIN.env"

if ! command -v flutter >/dev/null 2>&1; then
  echo "error: the Flutter SDK is required; expected flutter on PATH" >&2
  exit 1
fi
if [ ! -f "$FLUTTER_MODULE_DIR/pubspec.lock" ]; then
  echo "error: flutter_ui/pubspec.lock is missing; it must be version controlled" >&2
  exit 1
fi

actual_flutter_version="$(flutter --version | sed -n 's/^Flutter \([^ ]*\).*/\1/p' | head -1)"
if [ "$actual_flutter_version" != "$FLUTTER_VERSION" ]; then
  echo "error: Flutter $FLUTTER_VERSION is required; found ${actual_flutter_version:-none}" >&2
  exit 1
fi

# --enforce-lockfile fails instead of silently resolving to a newer plugin than
# the one the lockfile records. --offline keeps the build stage away from the
# network: the image pre-warms PUB_CACHE from this same lockfile. Outside the
# canonical image the cache may be cold, so BITCHAT_FLUTTER_PUB_OFFLINE=0 allows
# a developer checkout to populate it from pub.dev.
pub_get_args=(--enforce-lockfile)
if [ "${BITCHAT_FLUTTER_PUB_OFFLINE:-1}" = "1" ]; then
  pub_get_args+=(--offline)
fi

flutter pub get --directory "$FLUTTER_MODULE_DIR" "${pub_get_args[@]}"

if [ ! -f "$FLUTTER_MODULE_DIR/.android/include_flutter.groovy" ]; then
  echo "error: flutter pub get did not generate flutter_ui/.android/include_flutter.groovy" >&2
  exit 1
fi

echo "Flutter $FLUTTER_VERSION module prepared in $FLUTTER_MODULE_DIR"
