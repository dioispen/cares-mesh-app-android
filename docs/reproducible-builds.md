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
- Android platform, Platform Tools, and Build Tools archives by filename and
  SHA-256, plus the accepted SDK license-text SHA-1 required to use them
- the Flutter SDK archive by version and SHA-256, with its framework revision
  re-checked after extraction, and the Dart package set resolved from
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
Gradle to a host-specific SDK.

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

## The embedded Flutter module

`settings.gradle.kts` applies `flutter_ui/.android/include_flutter.groovy`. The
Flutter tool generates that file from the module's pubspec, and it is not version
controlled, so Gradle cannot even configure the build until
`tools/reproducible-builds/prepare-flutter.sh` has run. The canonical container
build calls it from `build-release.sh`; CI calls it from `ci-prepare.sh`.

`prepare-flutter.sh` refuses to continue unless the Flutter SDK on `PATH` is the
version `TOOLCHAIN.env` names, and it runs `flutter pub get --enforce-lockfile`,
so a resolution that would drift from `flutter_ui/pubspec.lock` fails the build
instead of silently succeeding.

### Where the hermeticity boundary sits

Two Flutter inputs would otherwise be fetched while the build runs, and both are
moved into the image instead:

- the Flutter engine and tool artifacts, downloaded by `flutter precache` during
  the image build;
- the Dart package set, downloaded by a `flutter pub get` that runs during the
  image build against a copy of `flutter_ui/pubspec.yaml` and
  `flutter_ui/pubspec.lock` and leaves the packages in `PUB_CACHE`
  (`/opt/pub-cache`).

The build stage therefore runs `flutter pub get --offline` and needs no pub.dev
access. Because only the pubspec pair is copied into that layer, editing Dart
sources reuses the cache and changing a dependency correctly invalidates it.

The boundary stops there, and it stops in the same place it already did for
Gradle. The build stage still resolves Maven dependencies over the network —
including the Flutter engine AARs from
`https://storage.googleapis.com/download.flutter.io`, which
`settings.gradle.kts` declares as an ordinary repository. Those are covered by
`gradle/verification-metadata.xml` checksums and the Gradle lockfiles, which is
how every other Maven input is handled. So the honest statement is: pub and the
Flutter tool are hermetic once the image exists; Maven is pinned but not
offline. Making the whole build offline would mean pre-seeding a Gradle
dependency cache in the image, which is a separate change affecting every
dependency, not just Flutter's.

A checkout without the warmed cache — a developer building outside the
container — can populate it from pub.dev with
`BITCHAT_FLUTTER_PUB_OFFLINE=0 tools/reproducible-builds/prepare-flutter.sh`.

## Firebase configuration

`app/google-services.json` is required: the `com.google.gms.google-services`
plugin fails at configuration time without it. It is **not** version controlled,
so it is injected rather than checked out.

**It changes the release bytes.** The plugin turns `project_id`,
`project_number`, `mobilesdk_app_id`, the API key and `storage_bucket` into
string resources (`google_app_id`, `google_api_key`, `gcm_defaultSenderId`,
`project_id`, `google_storage_bucket`), which are compiled into `resources.arsc`
inside every APK and AAB. Two builds of the same commit configured against
different Firebase projects therefore do not produce identical bytes. A third
party can only reproduce the published release bytes if it builds with the same
`google-services.json` the release was built with. `BUILDINFO.json` records that
file's SHA-256 as `googleServicesSha256` so the mismatch is diagnosable rather
than mysterious.

Supply it in one of three ways:

- **Local container build** — leave it at `app/google-services.json`, or point
  `BITCHAT_GOOGLE_SERVICES_JSON` at a copy elsewhere.
  `build-in-container.sh` mounts it read-only at `/injected/google-services.json`
  and `build-release.sh` installs it into the staging tree. It is deliberately
  not a nested bind mount over `/workspace`, which is not portable across
  Docker runtimes.
- **CI** — the `GOOGLE_SERVICES_JSON` repository secret holds the file's
  contents. `ci-prepare.sh` writes it into the checkout for container jobs; the
  reproducible-build job writes it to a temporary file and passes the path
  through `BITCHAT_GOOGLE_SERVICES_JSON`.
- **Plain host build** — place it at `app/google-services.json` as usual.

If the project later decides to track the file, nothing above breaks: the
injected copy is simply identical to the one already in the tree, and
`install-google-services-json.sh` skips the copy when source and destination are
the same path.

## Reproduce a release locally

Requirements are Git, Docker with Linux/amd64 support, more than 8 GiB of memory
available to the Docker VM (16 GiB recommended), and enough free space for the
Android and Gradle images and dependencies. R8's single-threaded deterministic
mode can exceed an 8 GiB Docker memory limit while optimizing the phone app.

The builder image is about 6.1 GB, of which roughly 3.1 GB is the Flutter SDK,
its precached engine artifacts and the warmed `PUB_CACHE`. Budget disk
accordingly. The memory figures above are unchanged: the Flutter work is disk-
and network-bound, and R8 remains the peak-memory step.

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

## CI uses the same image

`.github/workflows/android-build.yml` builds
`tools/reproducible-builds/Dockerfile` once per run in the `toolchain-image`
job, pushes it to `ghcr.io/<owner>/<repo>/reproducible-builder:<sha>`, and runs
the test, lint and debug-build jobs inside that image. Local builds, CI and
releases therefore share one pinned toolchain rather than three.

The `reproducible-build` job is the exception: it drives Docker itself, so it
cannot be a container job. It pulls the same image, retags it to the name
`build-in-container.sh` expects, and sets `BITCHAT_REUSE_CONTAINER_IMAGE=1` so
the script uses it instead of rebuilding — which also guarantees both replicas
share one image.

Two consequences worth knowing:

- pushing to GHCR needs `packages: write`, which the `GITHUB_TOKEN` of a
  pull request from a **fork** does not have. Fork PRs cannot run this workflow
  as written; they need a variant that builds the image locally in each job.
- the image is built from the working tree, while the release artifacts are
  built from `git archive` of the commit. The only working-tree files the image
  consumes are `TOOLCHAIN.env`, `sdk-metadata/` and the `flutter_ui` pubspec
  pair, all of which are version controlled, and `build-in-container.sh` refuses
  a dirty tree, so the two agree.

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

The verification metadata deliberately trusts only IDE documentation and source
attachments (`*-javadoc.jar`, `*-sources.jar`, and Gradle's `*-src.zip`). Android
Studio resolves these outside the build dependency graph, and they are not build
inputs. Compiled artifacts and dependency metadata remain checksum-verified.

When changing Gradle, update the wrapper and independently verify the new
distribution SHA-256. When changing JDK or Android tools, update the exact
version, archive checksum, and base-image digest together. Native updates follow
[`tools/arti-build/README.md`](../tools/arti-build/README.md).

When changing Flutter, update `FLUTTER_VERSION`, `FLUTTER_ARCHIVE`,
`FLUTTER_SHA256`, `FLUTTER_FRAMEWORK_REVISION`, `FLUTTER_ENGINE_REVISION` and
`FLUTTER_DART_VERSION` in `tools/reproducible-builds/TOOLCHAIN.env` together.
The archive checksum is published in
`https://storage.googleapis.com/flutter_infra_release/releases/releases_linux.json`;
verify it independently. The image build re-checks the extracted framework
revision against `TOOLCHAIN.env`, so a mismatched pair fails there rather than
silently building against a different SDK.

When changing Dart dependencies, run `flutter pub get` in `flutter_ui/`, commit
the updated `flutter_ui/pubspec.lock`, and rebuild the image — the warmed
`PUB_CACHE` layer keys off that lockfile, and a stale image makes the build's
`--offline` resolution fail.

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
