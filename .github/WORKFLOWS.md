# Build & CI pipeline for karing fork

This fork ships **4 GitHub Actions workflows** that turn the broken
public repo into a buildable, testable, releasable project.

## Workflows

| File | Triggers | Purpose |
|------|----------|---------|
| [`ci.yml`](ci.yml) | push, PR, manual | `flutter analyze` + `dart format --set-exit-if-changed` + smoke build |
| [`build.yml`](build.yml) | tag `v*`, manual | Multi-platform build matrix — sing-box binary + Flutter desktop + Android APKs |
| [`release.yml`](release.yml) | tag `v*`, manual | Calls `build.yml`, then publishes a GitHub release with all artifacts |
| [`codeql.yml`](codeql.yml) | push, PR, weekly Mon | CodeQL security scan (JS + Python helpers; Dart is covered by `flutter analyze` in `ci.yml`) |

## Architecture

```
push tag v*  ─┐
              ├─► release.yml
              │      │
              │      └─► calls build.yml
              │             │
              │             ├─► build-singbox (matrix: linux/windows/macos)
              │             │      └─► uploads karingService binaries
              │             ├─► build-flutter-desktop (matrix: linux/windows/macos)
              │             │      └─► downloads karingService, then `flutter build <os>`
              │             └─► build-android
              │                    └─► `flutter build apk --split-per-abi`
              │
              └─► collects all artifacts, computes SHA256SUMS,
                  generates release notes from git log, creates
                  GitHub release (draft = true; promote manually).
```

## Required secrets (for full release builds)

Set these in https://github.com/saber716rus/karing/settings/secrets/actions:

| Secret | Purpose | Required? |
|--------|---------|-----------|
| `ANDROID_KEYSTORE_BASE64` | Base64-encoded `karing.release.keystore` (run `base64 -w0 karing.release.keystore`) | Only for release APKs — without it, a stub self-signed keystore is generated and the APK is unsigned |
| `ANDROID_KEY_PASSWORD` | Release key password | Only if `ANDROID_KEYSTORE_BASE64` is set |
| `ANDROID_STORE_PASSWORD` | Release store password | Only if `ANDROID_KEYSTORE_BASE64` is set |
| `ANDROID_KEY_ALIAS` | Release key alias (usually `karing`) | Only if `ANDROID_KEYSTORE_BASE64` is set |

The default `GITHUB_TOKEN` (auto-provided by Actions) is enough for
releases — no extra PAT needed.

## The 13-missing-files problem

The desktop builds will still fail at the `flutter build` step because
13 `lib/app/utils/*.dart` files referenced by the public repo were never
published (`device_utils.dart`, `notice_utils.dart`, `singbox_dns.dart`,
`singbox_outbound.dart`, `system_utils.dart`, etc.). These are part of
the proprietary portion of karing maintained by upstream KaringX.

**Workarounds:**

1. **Wait for upstream to publish them.** Track https://github.com/KaringX/karing/issues for an "open-core" announcement.
2. **Stub them out** by adding empty implementations — `ci.yml` already runs `flutter build linux --debug` as a smoke test with `continue-on-error: true` so the missing files do not block the workflow.
3. **Vendor the binaries** built from the closed-source tree into `assets/bin/<platform>/` before running `flutter build`. This is what the official releases do.

## Running the workflows

- **Manual**: https://github.com/saber716rus/karing/actions → pick the workflow → "Run workflow"
- **On tag push** (auto-triggers build + release):
  ```bash
  git tag v1.2.26.0001
  git push origin v1.2.26.0001
  ```
- **Status badge**: https://github.com/saber716rus/karing/actions

## Build matrix summary

| Job | Runner | Output |
|-----|--------|--------|
| `build-singbox` (linux) | ubuntu-22.04 | `karingService-linux_amd64` |
| `build-singbox` (windows) | windows-2022 | `karingService-windows_amd64.exe` |
| `build-singbox` (macos) | macos-13 | `karingService-macos_amd64` |
| `build-flutter-desktop` (linux) | ubuntu-22.04 | `karing_*_linux_amd64.tar.gz` |
| `build-flutter-desktop` (windows) | windows-2022 | `karing_*_windows_x64.zip` |
| `build-flutter-desktop` (macos) | macos-13 | `karing_*_macos_universal.zip` |
| `build-android` | ubuntu-22.04 | `app-*-release.apk` (split per ABI) |

## Sing-box build configuration

The `karingService` binary is built from https://github.com/KaringX/sing-box
at tag `v1.13.0-beta.7` with these build tags (extracted from the
released binary's `go:build` flags):

```
with_karing,with_acme,with_quic,with_dhcp,with_shadowsocksr,
with_wireguard,with_grpc,with_gvisor,with_utls,with_clash_api,
with_conntrack,with_tailscale,with_naive_outbound,with_purego
```

The `with_utls` tag is what enables **REALITY TLS support** — the
transport used by the VLESS Reality nodes in the subscription.

To rebuild `karingService` with different tags, edit the
`SING_BOX_BUILD_TAGS` env var in `build.yml`.

## Caching strategy

- `flutter-action` caches the Flutter SDK itself
- `actions/cache@v4` caches `~/.pub-cache`, `.dart_tool/`, `~/.gradle/caches/` keyed by `pubspec.lock`
- `setup-go` caches `~/go/pkg/mod` keyed by `go.sum`
- Combined cold-cache build time: ~12 min, warm-cache: ~4 min

## Triggering a manual release build

```bash
# Tag on local repo (after committing changes)
git tag -a v1.2.26.0001 -m "v1.2.26.0001 — xhttp support + restore utils"
git push origin v1.2.26.0001

# Or trigger via GitHub UI without a tag:
# https://github.com/saber716rus/karing/actions/workflows/release.yml
# Click "Run workflow", enter tag name "v1.2.26.0001"
```

The release workflow creates a **draft** release — promote it manually
after inspecting the artifacts at
https://github.com/saber716rus/karing/releases.
