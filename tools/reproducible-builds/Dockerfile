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

# The Flutter SDK is installed from the official pinned stable archive and
# verified by SHA-256, exactly like the Android SDK packages above. Deliberately
# not `git clone`: a channel checkout floats, while app/gradle.lockfile locks the
# eight io.flutter engine artifacts to one engine revision under STRICT locking.
#
# git       the flutter entrypoint runs `git rev-parse HEAD` and
#           `git ls-files bin/internal/engine.version` inside FLUTTER_ROOT on
#           every invocation, so the SDK has to stay a usable Git checkout
# xz-utils  the official Flutter archive is .tar.xz
# unzip     verify-no-host-paths.sh prefers it over `jar` when inspecting
#           release APK and AAB payloads
#
# The base image's ubuntu.sources is replaced, not supplemented: with the live
# archive still listed, apt would pick whatever is newest there and the
# snapshot would pin nothing. Snapshot Release files carry an expired
# Valid-Until by design, hence Check-Valid-Until: no; every package is still
# verified against the snapshot's index signed by the Ubuntu archive key.
RUN source /tmp/TOOLCHAIN.env \
    && printf '%s\n' \
        'Types: deb' \
        "URIs: https://snapshot.ubuntu.com/ubuntu/${UBUNTU_SNAPSHOT}" \
        'Suites: noble noble-updates noble-security' \
        'Components: main' \
        'Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg' \
        'Check-Valid-Until: no' \
        > /etc/apt/sources.list.d/ubuntu.sources \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        git \
        unzip \
        xz-utils \
    && rm -rf /var/lib/apt/lists/*

# The generated Flutter module declares `ndkVersion = flutter.ndkVersion`, so
# AGP resolves that exact side-by-side NDK while configuring :flutter and tries
# to install it when it is absent — which fails against a read-only SDK and
# would reach the network anyway. Pin it like every other SDK package.
# `unzip` rather than `jar`: the NDK archive carries symlinks and executable
# bits that `jar` silently drops.
RUN source /tmp/TOOLCHAIN.env \
    && curl -fsSL \
        "https://dl.google.com/android/repository/${ANDROID_NDK_ARCHIVE}" \
        -o "/tmp/${ANDROID_NDK_ARCHIVE}" \
    && echo "${ANDROID_NDK_SHA256}  /tmp/${ANDROID_NDK_ARCHIVE}" | sha256sum -c - \
    && mkdir -p "$ANDROID_HOME/ndk" \
    && unzip -qq "/tmp/${ANDROID_NDK_ARCHIVE}" -d "$ANDROID_HOME/ndk" \
    && mv "$ANDROID_HOME/ndk/${ANDROID_NDK_ARCHIVE_ROOT}" \
        "$ANDROID_HOME/ndk/${ANDROID_NDK_VERSION}" \
    && cp "/tmp/sdk-metadata/ndk-${ANDROID_NDK_VERSION}.xml" \
        "$ANDROID_HOME/ndk/${ANDROID_NDK_VERSION}/package.xml" \
    && rm -f "/tmp/${ANDROID_NDK_ARCHIVE}" \
    && test -x "$ANDROID_HOME/ndk/${ANDROID_NDK_VERSION}/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip"

# The `jni` Dart package builds native code, so AGP runs its own default CMake
# while configuring :jni and :flutter for release. Same sealed-SDK problem as the
# NDK above, same fix. The archive unpacks flat into cmake/<version>/ and carries
# bin/ninja alongside bin/cmake. `unzip` rather than `jar`: executable bits again.
RUN source /tmp/TOOLCHAIN.env \
    && curl -fsSL \
        "https://dl.google.com/android/repository/${ANDROID_CMAKE_ARCHIVE}" \
        -o "/tmp/${ANDROID_CMAKE_ARCHIVE}" \
    && echo "${ANDROID_CMAKE_SHA256}  /tmp/${ANDROID_CMAKE_ARCHIVE}" | sha256sum -c - \
    && mkdir -p "$ANDROID_HOME/cmake/${ANDROID_CMAKE_VERSION}" \
    && unzip -qq "/tmp/${ANDROID_CMAKE_ARCHIVE}" \
        -d "$ANDROID_HOME/cmake/${ANDROID_CMAKE_VERSION}" \
    && cp "/tmp/sdk-metadata/cmake-${ANDROID_CMAKE_VERSION}.xml" \
        "$ANDROID_HOME/cmake/${ANDROID_CMAKE_VERSION}/package.xml" \
    && rm -f "/tmp/${ANDROID_CMAKE_ARCHIVE}" \
    && test -x "$ANDROID_HOME/cmake/${ANDROID_CMAKE_VERSION}/bin/cmake" \
    && test -x "$ANDROID_HOME/cmake/${ANDROID_CMAKE_VERSION}/bin/ninja"

ENV FLUTTER_ROOT=/opt/flutter
ENV PUB_CACHE=/opt/pub-cache
ENV PATH=/opt/flutter/bin:/opt/flutter/bin/cache/dart-sdk/bin:${PATH}
ENV FLUTTER_SUPPRESS_ANALYTICS=true

# The container runs as an arbitrary non-root uid, so every path the Flutter
# tool writes to at build time has to be writable by that uid: bin/cache holds
# the startup lockfile and the engine.stamp that update_engine_version.sh
# rewrites on every invocation, and Gradle builds the flutter-gradle-plugin
# included build underneath packages/flutter_tools/gradle. The tool snapshot and
# every artifact are generated here so that no runtime invocation needs network.
RUN source /tmp/TOOLCHAIN.env \
    && test "$FLUTTER_SDK_DIR" = "$FLUTTER_ROOT" \
    && test "$PUB_CACHE_DIR" = "$PUB_CACHE" \
    && curl -fsSL \
        "https://storage.googleapis.com/flutter_infra_release/releases/${FLUTTER_ARCHIVE}" \
        -o /tmp/flutter-sdk.tar.xz \
    && echo "${FLUTTER_SHA256}  /tmp/flutter-sdk.tar.xz" | sha256sum -c - \
    && tar -xJf /tmp/flutter-sdk.tar.xz -C /opt \
    && rm -f /tmp/flutter-sdk.tar.xz \
    && git config --system --add safe.directory '*' \
    && test "$(git -C "$FLUTTER_ROOT" rev-parse HEAD)" = "$FLUTTER_FRAMEWORK_REVISION" \
    && test "$(cat "$FLUTTER_ROOT/bin/internal/engine.version")" = "$FLUTTER_ENGINE_REVISION" \
    && flutter --no-version-check --disable-analytics --version \
    && grep -Fq "\"frameworkVersion\": \"$FLUTTER_VERSION\"" \
        "$FLUTTER_ROOT/bin/cache/flutter.version.json" \
    && grep -Fq "\"engineContentHash\": \"$FLUTTER_ENGINE_CONTENT_HASH\"" \
        "$FLUTTER_ROOT/bin/cache/flutter.version.json" \
    && flutter --no-version-check precache \
        --universal \
        --android \
        --android_gen_snapshot \
        --android_maven \
        --android_internal_build \
        --no-ios \
        --no-web \
        --no-linux \
        --no-macos \
        --no-windows \
        --no-fuchsia \
    && rm -rf "$FLUTTER_ROOT/bin/cache/flutter_web_sdk" \
        "$FLUTTER_ROOT/bin/cache/downloads" \
    && chmod -R a+rwX "$FLUTTER_ROOT"

# `docker run --rm` throws the container layer away, so anything that is not
# baked into the image is downloaded again on every single build. Resolving the
# module's dependencies here lets the build stage run `pub get --offline`
# against a warm PUB_CACHE. Only the two pubspec files are copied, so this layer
# is invalidated by a dependency change and not by every source edit.
COPY flutter_ui/pubspec.yaml flutter_ui/pubspec.lock /tmp/pub-warmup/

RUN cd /tmp/pub-warmup \
    && flutter --no-version-check pub get --enforce-lockfile \
    && cd / \
    && rm -rf /tmp/pub-warmup \
    && chmod -R a+rwX "$PUB_CACHE" "$FLUTTER_ROOT/bin/cache"

ENV TZ=UTC
ENV LC_ALL=C.UTF-8

WORKDIR /workspace

ENTRYPOINT ["/bin/bash", "tools/reproducible-builds/build-release.sh"]
