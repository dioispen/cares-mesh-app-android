#!/usr/bin/env bash

# Installs the Firebase configuration the com.google.gms.google-services plugin
# reads. The file is deliberately not version controlled, so it is injected:
# a read-only bind mount for container builds, a repository secret in CI.
#
# Its contents reach the release artifacts — the plugin turns project_id,
# project_number, the app id, the API key and the storage bucket into string
# resources that end up in resources.arsc. Two builds of the same commit with
# different Firebase projects therefore produce different bytes, which is why
# build-release.sh records the file's SHA-256 in BUILDINFO.json.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DESTINATION="$PROJECT_ROOT/app/google-services.json"
SOURCE="${1:-${BITCHAT_GOOGLE_SERVICES_JSON:-}}"

if [ -n "$SOURCE" ]; then
  if [ ! -f "$SOURCE" ]; then
    echo "error: injected google-services.json not found: $SOURCE" >&2
    exit 1
  fi
  if [ "$(cd "$(dirname "$SOURCE")" && pwd)/$(basename "$SOURCE")" != "$DESTINATION" ]; then
    cp "$SOURCE" "$DESTINATION"
  fi
fi

if [ ! -f "$DESTINATION" ]; then
  cat >&2 <<'EOF'
error: app/google-services.json is missing.

The com.google.gms.google-services plugin cannot configure the build without it,
and the file is not version controlled. Supply it with one of:

  * point BITCHAT_GOOGLE_SERVICES_JSON at a copy on the host, or
  * place it at app/google-services.json before building, or
  * in CI, write it from the GOOGLE_SERVICES_JSON repository secret.

See docs/reproducible-builds.md, "Firebase configuration".
EOF
  exit 1
fi

if ! grep -q '"project_id"' "$DESTINATION"; then
  echo "error: app/google-services.json does not look like a Firebase config" >&2
  exit 1
fi

sha256sum "$DESTINATION" | awk '{print $1}'
