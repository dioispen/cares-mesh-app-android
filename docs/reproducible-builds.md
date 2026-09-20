# Reproducible builds

Bitchat's canonical release build produces byte-for-byte reproducible unsigned
phone and Wear OS APKs and Android App Bundles (AABs). CI builds the release
twice in independent jobs and exposes a verified release artifact only when
every canonical byte matches.

Signing remains local: no keystore or signing password is stored in or exposed
to GitHub Actions. Anyone can reproduce the unsigned artifacts; maintainers
download the verified CI output, sign the selected GitHub APKs and Play upload
AABs locally, then manually publish those exact files.

Maintainers should use the complete
[Android maintainer release guide](maintainer-release-guide.md) for the
step-by-step release procedure, artifact inventory, local signing commands, and
GitHub/Google Play publication checklist.

## What is pinned

- Gradle wrapper version and distribution SHA-256
- dependency versions, strict Gradle dependency locks, and downloaded-artifact
  SHA-256 verification metadata
- exact Temurin JDK release and digest-pinned Linux builder image
- Android platform, Platform Tools, Build Tools, and side-by-side NDK archives
  by filename and SHA-256, plus the accepted SDK license-text SHA-1 required to
  use them
- the Flutter SDK release archive by filename and SHA-256, plus the framework
  and engine revisions the extracted SDK must report
- Dart package versions and their `sha256:` content hashes in
  `flutter_ui/pubspec.lock`
- Kotlin/JVM toolchain and bytecode target
- Arti source tag and full commit, stable native build epoch, Rust, `cargo-ndk`,
  Android NDK, Cargo lockfile, digest-pinned Rust builder image, and immutable
  Debian package snapshot
- immutable full commit SHAs for every third-party GitHub Action

The build uses a clean source tree, an isolated Gradle user home, UTC, a stable
locale, `SOURCE_DATE_EPOCH` from the Git commit, no Gradle build or configuration
cache, fresh tasks, a non-incremental in-process Kotlin compiler, and R8's
deterministic-debugging mode. The R8 mode uses one compiler thread and disables
randomized input shuffling. The regular R8 ProGuard map remains embedded in each
AAB. Kotlin 2.4.10's optional Compose group-key mapping augmentation is disabled
because its duplicate-key selection depends on unspecified class-file iteration
order across clean builds. Native builds remap source paths and release
validation rejects host paths in packaged libraries. The container overlays a
canonical `local.properties`, so an ignored Android Studio file cannot redirect
Gradle to a host-specific SDK. The embedded Flutter module has a second,
independent `flutter_ui/.android/local.properties`; the container regenerates
that one with container paths for both `sdk.dir` and `flutter.sdk`.

AGP's embedded VCS record is disabled because its Git discovery depends on the
host checkout layout. The canonical `BUILDINFO.json` and GitHub provenance
attestation record the host-verified commit instead.

The authoritative pins are:

- `gradle/wrapper/gradle-wrapper.properties`
- `gradle/libs.versions.toml`
- `settings-gradle.lockfile`
- `app/gradle.lockfile`
- `wear/gradle.lockfile`
- `gradle/verification-metadata.xml`
- `tools/reproducible-builds/TOOLCHAIN.env`
- `tools/arti-build/TOOLCHAIN.env`
- `tools/arti-build/Cargo.lock`
- `flutter_ui/pubspec.lock`

## One image for local builds, CI, and releases

`tools/reproducible-builds/Dockerfile` is the only supported build environment.
Two drivers use it:

- `build-in-container.sh` — the release path. It builds from `git archive` of
  the committed tree, refuses a dirty checkout, and runs `build-release.sh` as
  the image entrypoint.
- `run-in-container.sh` — the everyday path. It bind-mounts the working tree and
  runs any command inside the image:

  ```bash
  tools/reproducible-builds/run-in-container.sh ./gradlew testDebugUnitTest
  tools/reproducible-builds/run-in-container.sh \
    bash -c 'cd flutter_ui && flutter --no-version-check test'
  ```

  It swaps the canonical `local.properties` in for the duration of the run and
  restores the host one afterwards, and regenerates `flutter_ui/.android` before
  the requested command (skip with `BITCHAT_SKIP_FLUTTER_PREPARE=1`).

  Because the working tree is bind-mounted, that leaves `flutter_ui/.android`
  and `flutter_ui/.dart_tool` pointing at container paths. Both are gitignored
  build state; run `flutter pub get` in `flutter_ui/` again to restore the IDE
  setup on the host.

`.github/workflows/android-build.yml` runs the unit tests, `flutter test`, lint,
and the debug APK through `run-in-container.sh`, so CI, a developer machine, and
the release build share one toolchain. There is no `actions/setup-java` step:
the JDK comes from the image. The image build is layer-cached within a job but
not between jobs, so every job pays to build it once.

The image tag carries both pinned versions,
`bitchat-android-reproducible-builder:<jdk>-flutter<flutter>`. Changing either
version — or anything else in the `Dockerfile` — leaves the previous image
behind as an untagged `<none>` image of several gigabytes. Reclaim them with:

```bash
docker image prune
```

## The embedded Flutter module

`settings.gradle.kts` applies `flutter_ui/.android/include_flutter.groovy`
during settings evaluation. That directory is `flutter pub get` output and is
gitignored, so it is absent from the `git archive` tree the canonical build
uses, and `include_flutter.groovy` itself asserts on a separate
`flutter_ui/.android/local.properties` that has to carry `flutter.sdk`.

`tools/reproducible-builds/prepare-flutter-module.sh` closes that gap. It runs
inside the container before any Gradle invocation and:

1. refuses to continue unless `$FLUTTER_ROOT/bin/internal/engine.version`
   equals `FLUTTER_ENGINE_REVISION` from `TOOLCHAIN.env`;
2. runs `flutter pub get --enforce-lockfile --offline` in `flutter_ui/`; and
3. rewrites `flutter_ui/.android/local.properties` with the container's
   `sdk.dir` and `flutter.sdk`.

The generated `flutter_ui/.android/Flutter/build.gradle` also declares
`ndkVersion = flutter.ndkVersion`, so AGP resolves one exact side-by-side NDK
while configuring `:flutter`. That version is chosen by the pinned Flutter
release, not by this repository, and it is installed into the image from a
SHA-256-pinned archive: without it the build fails with
`InstallFailedException: The SDK directory is not writable`. A Flutter upgrade
can therefore require a new `ANDROID_NDK_*` block in `TOOLCHAIN.env` and a new
`sdk-metadata/ndk-<version>.xml`.

The engine check in step 1 is not a formality. `app/gradle.lockfile` STRICT-locks
eight `io.flutter:*:1.0.0-<engine revision>` coordinates, so any Flutter release
other than the pinned one fails the build with an opaque lock error. The Flutter
version in `TOOLCHAIN.env` is a hard requirement, not a recommendation.

Step 2 is offline because the image prewarms `PUB_CACHE` from the same
`flutter_ui/pubspec.lock`. Set `BITCHAT_PUB_GET_OFFLINE=0` to allow network
resolution, which should only ever be needed while changing dependencies.

## Firebase configuration

`app/google-services.json` is tracked in version control. It is a build input,
not a secret:

- `app/build.gradle.kts` applies `com.google.gms.google-services`, which turns
  the file into Android string resources. Those resources end up in
  `resources.arsc` inside every release APK and AAB, so the file's contents
  change the release bytes. A third party cannot reproduce a release without
  the exact same file.
- Every value in it already ships inside every published APK, so committing it
  discloses nothing that a download does not.

`.gitignore` still ignores `google-services.json` everywhere else; only
`app/google-services.json` is excepted. Forks that point at their own Firebase
project will produce different, internally consistent release bytes.

## Hermeticity boundary

Reproducibility is only as strong as the weakest pin. These inputs are pinned by
content, so substitution is detected during the build:

| Input | Pinned by |
| --- | --- |
| Builder base image | image digest in `Dockerfile` |
| Gradle distribution | SHA-256 in `gradle-wrapper.properties` |
| Android platform, Platform Tools, Build Tools, NDK | SHA-256 in `TOOLCHAIN.env` |
| Flutter SDK (and the Dart SDK inside it) | SHA-256 in `TOOLCHAIN.env` |
| Dart packages | `sha256:` per package in `flutter_ui/pubspec.lock`, enforced with `--enforce-lockfile` |
| Most Maven artifacts | `gradle/verification-metadata.xml` |
| Arti native libraries | `tools/arti-build/SHA256SUMS` |
| Source tree | commit SHA in `BUILDINFO.json` |

These inputs are pinned only by version or URL. Their bytes are taken on trust
from the server that serves them:

- **`io.flutter:*` engine AARs.** `gradle/verification-metadata.xml` carries
  `<trust group="io.flutter"/>`, so the eight engine artifacts resolved from
  `https://storage.googleapis.com/download.flutter.io` are *not* checksum
  verified. Their version string embeds the engine revision, so a substitution
  has to keep the same coordinates, but nothing in this repository would notice
  different bytes under them. Closing this means recording their checksums in
  the verification metadata; it is deliberately out of scope here.

  The neighbouring `<trust group="dev.flutter"/>` rule is a weaker concern: the
  Flutter Gradle plugin is built from `packages/flutter_tools/gradle` inside the
  SDK, and the SDK archive is checksum-verified.
- **Flutter engine artifacts under `bin/cache/artifacts/engine`.** The Flutter
  tool fetches these by engine revision without a checksum this repository
  controls. They are downloaded once while the image is built, so any given
  image is fixed, but rebuilding the image refetches them.
- **Ubuntu packages added to the image** (`git`, `unzip`, `xz-utils`). The base
  image digest is pinned; the apt archive state at image-build time is not.
  None of these programs contributes bytes to the release artifacts.

The build container itself is therefore not byte-reproducible — the release
artifacts it produces are. The canonical build stage performs no pub.dev access
at all: `PUB_CACHE` and the Flutter engine artifacts are baked into the image,
and `docker run --rm` would otherwise re-download roughly 900 MB on every build.

## Reproduce a release locally

Requirements are Git, Docker with Linux/amd64 support, more than 8 GiB of memory
available to the Docker VM (16 GiB recommended), and enough free space for the
Android and Gradle images and dependencies. R8's single-threaded deterministic
mode can exceed an 8 GiB Docker memory limit while optimizing the phone app.

```bash
git clone https://github.com/permissionlesstech/bitchat-android.git
cd bitchat-android
git checkout vX.Y.Z
tools/reproducible-builds/build-in-container.sh \
  .reproducible-build/local-vX.Y.Z
```

The output contains:

- unsigned APKs for arm64, armv7, x86, x86_64, and universal installs
- `bitchat-android-release-unsigned.aab`
- `bitchat-android-wear-unsigned.apk`
- `bitchat-android-wear-release-unsigned.aab`
- `BUILDINFO.json`
- `SHA256SUMS.unsigned`

The output directory must not already contain files. The script rejects a dirty
checkout so the commit in `BUILDINFO.json` identifies all source inputs.

To test reproducibility yourself, build into two empty directories and compare:

```bash
BITCHAT_CONTAINER_GRADLE_HOME_NAME=gradle-home-first \
  tools/reproducible-builds/build-in-container.sh .reproducible-build/first
BITCHAT_CONTAINER_GRADLE_HOME_NAME=gradle-home-second \
  tools/reproducible-builds/build-in-container.sh .reproducible-build/second
tools/reproducible-builds/compare-release.sh \
  .reproducible-build/first \
  .reproducible-build/second
```

If a comparison fails and `diffoscope` is installed, the comparison script
automatically reports the first differing artifact.

## Verify a GitHub release

Install the GitHub CLI, authenticate it if necessary, check out the release tag,
and run:

```bash
git checkout vX.Y.Z
tools/reproducible-builds/verify-github-release.sh vX.Y.Z
```

That command:

1. downloads all release APKs, AABs, build information, and checksum files;
2. verifies the canonical unsigned build's GitHub artifact-attestation subjects
   against this repository;
3. verifies `BITCHAT_SHA256SUMS`;
4. checks that the local source commit is the release commit;
5. rebuilds in the pinned container; and
6. byte-compares every unsigned APK, both unsigned AABs, build information, and
   the unsigned checksum manifest.

To verify the published checksums and attestations without rebuilding:

```bash
tools/reproducible-builds/verify-github-release.sh vX.Y.Z --no-rebuild
```

For a manual signature check, use the exact `apksigner` from Android Build Tools
37.0.0:

```bash
apksigner verify --verbose --print-certs bitchat-android-universal.apk
```

Compare the reported signer certificate SHA-256 with
`BITCHAT_GITHUB_RELEASE_CERT_SHA256` in `gradle.properties`. A matching
certificate proves who signed the APK; the checksum, attestation, and local
unsigned rebuild establish which source and build produced it. A third party
cannot recreate the signed bytes without the private release key.

You can also prove that the signed APK contains the same archive entries and
uncompressed payload bytes as the reproduced unsigned APK:

```bash
tools/reproducible-builds/compare-archive-payloads.sh \
  .reproducible-build/local-vX.Y.Z/bitchat-android-universal-unsigned.apk \
  bitchat-android-universal.apk
```

GitHub's manual equivalents are:

```bash
gh release download vX.Y.Z
sha256sum -c BITCHAT_SHA256SUMS
gh attestation verify bitchat-android-universal-unsigned.apk \
  --repo permissionlesstech/bitchat-android
```

## Verify a Google Play release

Google Play App Signing changes the verification boundary:

- maintainers upload signed phone and Wear AABs using the upload key;
- Google Play generates optimized, device-specific APK splits from those AABs;
- Google signs the delivered APKs with the app-signing key.

Consequently, a Play-delivered APK is not expected to be byte-identical to the
GitHub universal APK or to a locally built APK. Use this procedure instead:

1. In Play Console, open **Test and release > App bundle explorer**, select the
   release/version code, and download the original app bundle if that option is
   available to your account. Compare its unsigned payload with the matching
   reproduced phone or Wear AAB:

   ```bash
   tools/reproducible-builds/compare-archive-payloads.sh \
     .reproducible-build/local-vX.Y.Z/bitchat-android-release-unsigned.aab \
     downloaded-from-play.aab
   ```

   The helper excludes JAR-signing metadata and compares every other entry name
   and uncompressed byte.
2. In **Setup > App integrity**, record the SHA-256 fingerprint under **App
   signing key certificate**. This is different from the upload-key certificate
   and may be different from the GitHub release certificate.
3. In App bundle explorer, download the Play-generated universal APK or the APKs
   for a representative device. Verify each APK:

   ```bash
   apksigner verify --verbose --print-certs downloaded-from-play.apk
   ```

   The signer SHA-256 must equal the Play Console app-signing certificate.
4. Confirm package name `com.bitchat.droid`, version code, version name, and
   manifest/security configuration with Android's `apkanalyzer` or `aapt2`.
5. Recreate Google's split-generation behavior from the reproduced AAB with the
   same `bundletool` version and a saved device specification:

   ```bash
   bundletool build-apks \
     --bundle=bitchat-android-release-unsigned.aab \
     --output=local.apks \
     --device-spec=device.json
   ```

This last check validates bundle-to-APK behavior, but it is not a byte-equality
claim: Play's server-side `bundletool` version, optimization, and signing inputs
are controlled by Google. The strongest public Play verification requires
maintainers to retain the uploaded AAB, publish its digest and provenance, and
record the Play version code and app-signing certificate fingerprint alongside
the release.

The GitHub workflow builds and attests both canonical unsigned AABs. A
maintainer locally creates `bitchat-android-play-upload.aab` and
`bitchat-android-wear-play-upload.aab` from those exact files and uploads them
manually to Google Play.

## Maintainer release process

Follow the
[Android maintainer release guide](maintainer-release-guide.md). It is the
authoritative operational runbook from version preparation through the signed
tag, GitHub Actions artifact download, local APK/AAB signing, GitHub draft,
Play internal test, public rollout, and post-release verification.

The workflow has no signing secrets and never publishes a release by itself.

## Updating dependencies or toolchains

Dependency changes must update and review both the lock state and verification
metadata:

```bash
./gradlew testDebugUnitTest lintDebug resolveIdeRuntimeClasspathCopyLocks \
  --write-locks \
  --write-verification-metadata sha256
```

`resolveIdeRuntimeClasspathCopyLocks` records the transient runtime classpath
copies that Android Studio resolves during model import. Their selected versions
are persisted under the generated copy configuration names while the canonical
debug and release runtime classpaths remain strictly locked.

Generate release lock entries in separate invocations because split APK and AAB
intermediates cannot coexist:

```bash
./gradlew :app:clean :app:bundleRelease \
  --write-locks \
  --write-verification-metadata sha256
./gradlew :app:clean :app:assembleRelease \
  --write-locks \
  --write-verification-metadata sha256
```

Review every new repository, component, artifact name, version, and checksum.
Do not accept verification metadata generated after an unexplained checksum
failure.

The Flutter Gradle plugin is an included build
(`$FLUTTER_ROOT/packages/flutter_tools/gradle`) and pins its own Kotlin plugin
version, so its plugin classpath needs verification-metadata entries too — a
Flutter upgrade can therefore require new checksums even when no project
dependency changed. A clean Gradle user home surfaces those immediately;
a warm developer cache can hide them, which is another reason to run the
container before pushing.

The verification metadata deliberately trusts only IDE documentation and source
attachments (`*-javadoc.jar`, `*-sources.jar`, and Gradle's `*-src.zip`). Android
Studio resolves these outside the build dependency graph, and they are not build
inputs. Compiled artifacts and dependency metadata remain checksum-verified.

When changing Gradle, update the wrapper and independently verify the new
distribution SHA-256. When changing JDK or Android tools, update the exact
version, archive checksum, and base-image digest together. Native updates follow
[`tools/arti-build/README.md`](../tools/arti-build/README.md).

## References

- [Gradle dependency locking](https://docs.gradle.org/current/userguide/dependency_locking.html)
- [Gradle dependency verification](https://docs.gradle.org/current/userguide/dependency_verification.html)
- [Gradle wrapper checksum verification](https://docs.gradle.org/current/userguide/best_practices_security.html#use_the_gradle_wrapper_and_verify_the_wrapper_checksum)
- [GitHub Actions security hardening](https://docs.github.com/en/actions/reference/security/secure-use)
- [GitHub artifact attestation verification](https://docs.github.com/en/actions/how-tos/secure-your-work/use-artifact-attestations/use-artifact-attestations)
- [Google Play App Signing](https://support.google.com/googleplay/android-developer/answer/9842756)
- [Play Console App bundle explorer](https://support.google.com/googleplay/android-developer/answer/9859152)
- [Android `bundletool`](https://developer.android.com/tools/bundletool)
- [Android `apksigner`](https://developer.android.com/tools/apksigner)
