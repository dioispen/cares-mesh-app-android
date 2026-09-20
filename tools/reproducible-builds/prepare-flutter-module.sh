#!/usr/bin/env bash

# Regenerates flutter_ui/.android/ inside the canonical build container.
#
# settings.gradle.kts applies flutter_ui/.android/include_flutter.groovy during
# settings evaluation, and that script asserts on flutter_ui/.android/
# local.properties. Both are `flutter pub get` output and are gitignored, so the
# tree produced by `git archive` in build-in-container.sh does not contain them
# and every Gradle invocation has to be preceded by this script.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FLUTTER_MODULE_DIR="$PROJECT_ROOT/flutter_ui"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/TOOLCHAIN.env"

if [ -z "${FLUTTER_ROOT:-}" ]; then
  echo "error: FLUTTER_ROOT is not set; run this inside the canonical container" >&2
  exit 1
fi
if [ ! -x "$FLUTTER_ROOT/bin/flutter" ]; then
  echo "error: no Flutter SDK at $FLUTTER_ROOT" >&2
  exit 1
fi

android_sdk="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
if [ -z "$android_sdk" ]; then
  echo "error: ANDROID_SDK_ROOT is not set" >&2
  exit 1
fi

# The container is started with HOME pointing at a scratch directory that does
# not exist yet. The Flutter tool and pub both refuse to run without one.
export HOME="${HOME:-/tmp/build-home}"
mkdir -p "$HOME"
export FLUTTER_SUPPRESS_ANALYTICS=true

# The eight io.flutter:*:1.0.0-<engine revision> entries in app/gradle.lockfile
# are STRICT-locked, so a Flutter SDK whose engine revision differs fails the
# build later with an opaque lock error. Fail here with a useful message.
installed_engine_revision="$(cat "$FLUTTER_ROOT/bin/internal/engine.version")"
if [ "$installed_engine_revision" != "$FLUTTER_ENGINE_REVISION" ]; then
  echo "error: Flutter engine revision mismatch" >&2
  echo "  expected (TOOLCHAIN.env, app/gradle.lockfile): $FLUTTER_ENGINE_REVISION" >&2
  echo "  installed at $FLUTTER_ROOT:                    $installed_engine_revision" >&2
  exit 1
fi

pub_get_args=(--no-version-check pub get --enforce-lockfile)
if [ "${BITCHAT_PUB_GET_OFFLINE:-1}" = "1" ]; then
  # The image prewarms PUB_CACHE from the same flutter_ui/pubspec.lock, so the
  # canonical build resolves without reaching pub.dev at all.
  pub_get_args+=(--offline)
fi

(
  cd "$FLUTTER_MODULE_DIR"
  "$FLUTTER_ROOT/bin/flutter" "${pub_get_args[@]}"
)

# Third-party packages that do not build against this toolchain are repaired
# here, after pub has extracted them and before Gradle configures the generated
# plugin projects.
"$SCRIPT_DIR/apply-pub-cache-patches.sh"

generated_local_properties="$FLUTTER_MODULE_DIR/.android/local.properties"
if [ ! -f "$FLUTTER_MODULE_DIR/.android/include_flutter.groovy" ]; then
  echo "error: flutter pub get did not generate flutter_ui/.android" >&2
  exit 1
fi
if [ ! -f "$generated_local_properties" ]; then
  echo "error: flutter pub get did not generate $generated_local_properties" >&2
  exit 1
fi

generated_flutter_sdk="$(sed -n 's/^flutter\.sdk=//p' "$generated_local_properties" | head -1)"
generated_sdk_dir="$(sed -n 's/^sdk\.dir=//p' "$generated_local_properties" | head -1)"

if [ "$generated_flutter_sdk" != "$FLUTTER_ROOT" ] ||
  [ "$generated_sdk_dir" != "$android_sdk" ]; then
  echo "note: normalising generated flutter_ui/.android/local.properties" >&2
  echo "  flutter.sdk: '$generated_flutter_sdk' -> '$FLUTTER_ROOT'" >&2
  echo "  sdk.dir:     '$generated_sdk_dir' -> '$android_sdk'" >&2
fi

# Written unconditionally: the generated values are only as good as the ambient
# environment, and verify-no-host-paths.sh rejects host paths in the output.
cat > "$generated_local_properties" <<EOF
sdk.dir=$android_sdk
flutter.sdk=$FLUTTER_ROOT
EOF

echo "Flutter module prepared: engine $FLUTTER_ENGINE_REVISION, SDK $FLUTTER_ROOT"
