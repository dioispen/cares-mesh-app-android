#!/usr/bin/env bash

# Applies the project's patches to third-party Dart packages in PUB_CACHE.
#
# pub has no patch mechanism, so a package that does not build against this
# project's toolchain can only be fixed by editing the extracted cache copy.
# Doing that by hand is how this repository ended up in a state where the build
# worked on one developer machine and nowhere else: the edit lives outside
# version control, is invisible to CI, and disappears on `pub cache clean` or a
# new checkout. Every such edit belongs here instead.
#
# Each patch pins both checksums. An upstream release that changes the file
# fails loudly rather than being silently re-patched, and an already-patched
# cache is left alone, so the script is idempotent.

set -euo pipefail

pub_cache="${PUB_CACHE:-$HOME/.pub-cache}"
if [ ! -d "$pub_cache" ]; then
  echo "error: PUB_CACHE not found at $pub_cache" >&2
  exit 1
fi

# patch_package_file PACKAGE RELATIVE_PATH PRISTINE_SHA256 PATCHED_SHA256 SED_SCRIPT
patch_package_file() {
  local package="$1" relative_path="$2" pristine="$3" patched="$4" sed_script="$5"
  local target="$pub_cache/hosted/pub.dev/$package/$relative_path"

  if [ ! -f "$target" ]; then
    echo "error: $package is not in PUB_CACHE; run flutter pub get first" >&2
    return 1
  fi

  local actual
  actual="$(sha256sum "$target" | cut -d' ' -f1)"

  if [ "$actual" = "$patched" ]; then
    return 0
  fi
  if [ "$actual" != "$pristine" ]; then
    echo "error: unexpected contents for $package/$relative_path" >&2
    echo "  expected pristine: $pristine" >&2
    echo "  expected patched:  $patched" >&2
    echo "  found:             $actual" >&2
    echo "  The package changed upstream. Re-review the patch and update both" >&2
    echo "  checksums in $(basename "${BASH_SOURCE[0]}")." >&2
    return 1
  fi

  sed "$sed_script" "$target" > "$target.patched"
  actual="$(sha256sum "$target.patched" | cut -d' ' -f1)"
  if [ "$actual" != "$patched" ]; then
    rm -f "$target.patched"
    echo "error: patching $package/$relative_path produced unexpected bytes" >&2
    echo "  expected: $patched" >&2
    echo "  produced: $actual" >&2
    return 1
  fi
  mv -f "$target.patched" "$target"
  echo "patched $package/$relative_path"
}

# No patches are currently needed. The flutter_inappwebview_android patch
# (getDefaultProguardFile under AGP 9) went away with that dependency; add new
# patch_package_file calls here when another package needs one.
