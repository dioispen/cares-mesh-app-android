# syntax=docker/dockerfile:1@sha256:87999aa3d42bdc6bea60565083ee17e86d1f3339802f543c0d03998580f9cb89
FROM eclipse-temurin:21.0.11_10-jdk-noble@sha256:35685c7e23352983a48882d97cd9875f5284c228db71d1e2476e5e6c1bab1080

SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

COPY tools/reproducible-builds/TOOLCHAIN.env /tmp/TOOLCHAIN.env
COPY tools/reproducible-builds/sdk-metadata /tmp/sdk-metadata

ENV ANDROID_HOME=/opt/android-sdk
ENV ANDROID_SDK_ROOT=/opt/android-sdk

RUN source /tmp/TOOLCHAIN.env \
    && mkdir -p "$ANDROID_HOME/build-tools" "$ANDROID_HOME/licenses" "$ANDROID_HOME/platforms" /tmp/android-packages \
    && printf '%s\n' "$ANDROID_SDK_LICENSE_SHA1" > "$ANDROID_HOME/licenses/android-sdk-license" \
    && curl -fsSL \
        "https://dl.google.com/android/repository/${ANDROID_BUILD_TOOLS_ARCHIVE}" \
        -o "/tmp/${ANDROID_BUILD_TOOLS_ARCHIVE}" \
    && echo "${ANDROID_BUILD_TOOLS_SHA256}  /tmp/${ANDROID_BUILD_TOOLS_ARCHIVE}" | sha256sum -c - \
    && mkdir -p /tmp/android-packages/build-tools \
    && cd /tmp/android-packages/build-tools \
    && jar xf "/tmp/${ANDROID_BUILD_TOOLS_ARCHIVE}" \
    && mv "/tmp/android-packages/build-tools/android-${ANDROID_PLATFORM_VERSION}" \
        "$ANDROID_HOME/build-tools/${ANDROID_BUILD_TOOLS_VERSION}" \
    && cp /tmp/sdk-metadata/build-tools-37.0.0.xml \
        "$ANDROID_HOME/build-tools/${ANDROID_BUILD_TOOLS_VERSION}/package.xml" \
    && find "$ANDROID_HOME/build-tools/${ANDROID_BUILD_TOOLS_VERSION}" \
        -maxdepth 1 -type f -exec chmod 755 {} + \
    && curl -fsSL \
        "https://dl.google.com/android/repository/${ANDROID_PLATFORM_ARCHIVE}" \
        -o "/tmp/${ANDROID_PLATFORM_ARCHIVE}" \
    && echo "${ANDROID_PLATFORM_SHA256}  /tmp/${ANDROID_PLATFORM_ARCHIVE}" | sha256sum -c - \
    && cd "$ANDROID_HOME/platforms" \
    && jar xf "/tmp/${ANDROID_PLATFORM_ARCHIVE}" \
    && cp /tmp/sdk-metadata/platform-37.0.xml \
        "$ANDROID_HOME/platforms/android-${ANDROID_PLATFORM_VERSION}/package.xml" \
    && test -f "$ANDROID_HOME/platforms/android-${ANDROID_PLATFORM_VERSION}/android.jar" \
    && curl -fsSL \
        "https://dl.google.com/android/repository/${ANDROID_PLATFORM_TOOLS_ARCHIVE}" \
        -o "/tmp/${ANDROID_PLATFORM_TOOLS_ARCHIVE}" \
    && echo "${ANDROID_PLATFORM_TOOLS_SHA256}  /tmp/${ANDROID_PLATFORM_TOOLS_ARCHIVE}" | sha256sum -c - \
    && cd "$ANDROID_HOME" \
    && jar xf "/tmp/${ANDROID_PLATFORM_TOOLS_ARCHIVE}" \
    && cp /tmp/sdk-metadata/platform-tools-37.0.0.xml \
        "$ANDROID_HOME/platform-tools/package.xml" \
    && find "$ANDROID_HOME/platform-tools" -maxdepth 1 -type f -exec chmod 755 {} + \
    && rm -rf /tmp/android-packages \
        "/tmp/${ANDROID_BUILD_TOOLS_ARCHIVE}" \
        "/tmp/${ANDROID_PLATFORM_ARCHIVE}" \
        "/tmp/${ANDROID_PLATFORM_TOOLS_ARCHIVE}"

ENV PATH=/opt/android-sdk/build-tools/37.0.0:${PATH}

# This fork embeds a Flutter module (flutter_ui). settings.gradle.kts applies
# flutter_ui/.android/include_flutter.groovy, which the Flutter tool generates
# from pubspec.lock, so the SDK has to exist before Gradle configures anything.
#
# The archive is pinned by version and SHA256 exactly like the Android packages
# above; it is never cloned from a moving channel. xz-utils unpacks the archive
# and git is required by the Flutter tool itself (it reads the SDK's own
# checkout to report its revision).
ENV FLUTTER_ROOT=/opt/flutter
ENV PUB_CACHE=/opt/pub-cache
ENV FLUTTER_SUPPRESS_ANALYTICS=true
ENV PATH=/opt/flutter/bin:/opt/flutter/bin/cache/dart-sdk/bin:${PATH}

# The canonical build runs as the invoking host UID, which does not own
# /opt/flutter. Both the safe.directory entry and the permission widening below
# are needed: git refuses "dubious ownership" repositories, and the Flutter tool
# writes stamp files into bin/cache on every invocation.
RUN source /tmp/TOOLCHAIN.env \
    && apt-get update \
    && apt-get install --no-install-recommends --yes git unzip xz-utils \
    && rm -rf /var/lib/apt/lists/* \
    && curl -fsSL \
        "https://storage.googleapis.com/flutter_infra_release/releases/${FLUTTER_ARCHIVE}" \
        -o /tmp/flutter-sdk.tar.xz \
    && echo "${FLUTTER_SHA256}  /tmp/flutter-sdk.tar.xz" | sha256sum -c - \
    && tar -xJf /tmp/flutter-sdk.tar.xz -C /opt \
    && rm /tmp/flutter-sdk.tar.xz \
    && test -d "$FLUTTER_ROOT/bin" \
    && git config --system --add safe.directory "$FLUTTER_ROOT" \
    && flutter precache --universal --android \
    && actual_flutter_revision="$(git -C "$FLUTTER_ROOT" rev-parse HEAD)" \
    && test "$actual_flutter_revision" = "$FLUTTER_FRAMEWORK_REVISION" \
    && mkdir -p "$PUB_CACHE" \
    && chmod -R a+rwX "$FLUTTER_ROOT" "$PUB_CACHE"

# Pre-warm PUB_CACHE so the build stage resolves Dart packages offline. Only the
# pubspec pair is copied, so editing Dart sources does not invalidate this layer;
# changing a dependency does, which is exactly when the cache must be refilled.
COPY flutter_ui/pubspec.yaml flutter_ui/pubspec.lock flutter_ui/.metadata /tmp/pub-warm/

RUN flutter pub get --directory /tmp/pub-warm --enforce-lockfile \
    && rm -rf /tmp/pub-warm \
    && chmod -R a+rwX "$PUB_CACHE" "$FLUTTER_ROOT"

ENV TZ=UTC
ENV LC_ALL=C.UTF-8

WORKDIR /workspace

ENTRYPOINT ["/bin/bash", "tools/reproducible-builds/build-release.sh"]
