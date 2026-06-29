# Filebrowser Quantum — Android client (Flutter)

A self-hosted [Filebrowser Quantum](https://github.com/gtsteffaniak/filebrowser)
mobile client for Android. Built and tested with **Flutter 3.44.4 / Dart 3.12**
(`flutter analyze` is clean and the test suite is green).

It pairs biometric-gated direct login with a full file-management UI: browse
across one or more **sources**, multiselect batch operations, move/copy with
conflict handling, search, share links, server status, background
uploads/downloads, share-into-app, and open-with hand-off.

## Features

- **Login**
  - **Direct login behind a biometric gate** — credentials live in the Android
    Keystore / EncryptedSharedPreferences (`flutter_secure_storage`) and unlock
    with fingerprint/face or device PIN (`local_auth`). After unlock the app
    logs in directly via `POST /api/auth/login` (no WebView, no captcha) and
    holds a Bearer JWT.
  - **Token keep-alive** — the cached JWT is refreshed via `POST /api/auth/renew`
    before it expires and on a 401 (one renew + replay per request), so day-to-day
    use never re-prompts. An unrecoverable session simply re-runs the direct login
    from the stored credentials.
- **Multi-source** — quantum exposes one or more named sources. A single source
  is auto-selected; with several, a source picker is shown and the choice is
  remembered. Every path-scoped request carries the current `source`.
- **Browse**
  - Directory listing with **breadcrumb** navigation.
  - **Persisted sort** by name / size / date (client-side, natural order),
    remembered across launches (`shared_preferences`).
  - **Multiselect** with batch **copy / move / delete / download**, plus a
    **destination picker** for copy/move targets.
  - **New folder** and single-item **rename**.
- **Search** — search within the current source (minimum 3-character query).
- **File details** — size, timestamps, and an on-demand **checksum**
  (md5/sha1/sha256/sha512) fetched only when requested.
- **Status page** — server **disk usage** (real disk used vs. capacity),
  signed-in user, and server capabilities when available.
- **Share links** — create/list/delete public share links, optional password and
  expiry; the link is handed to the system share sheet (`share_plus`).
- **In-app media** — zoomable image gallery (`photo_view`,
  `cached_network_image`) and a video player (`video_player` + `chewie`),
  streaming from the resource download endpoint with a Bearer auth header.
- **Transfers**
  - **Background uploads/downloads** that keep running when the app is
    backgrounded or closed, via a native foreground service with progress
    notifications (`background_downloader`).
  - **Upload conflict handling** — existing remote paths are probed and you
    choose overwrite / skip / keep-both.
  - A dedicated **transfers screen** listening to live progress updates.
  - **Share-into-app** — accept files/images/videos shared from other apps
    (`SEND` / `SEND_MULTIPLE`), pick a destination, and upload.
  - **Download save-location** picking and **open-with** hand-off to a native
    app (`file_picker`, `open_filex`).

## How it talks to the server

All endpoints are under `/api`. `<S>` is the current source name; paths are
passed as query parameters (not URL segments), and every path-scoped call carries
`source=<S>`.

| Action       | Request                                                                  |
| ------------ | ------------------------------------------------------------------------ |
| Login        | `POST /api/auth/login?username=<u>` , headers `X-Password`, `X-Secret` → JWT text |
| Renew        | `POST /api/auth/renew` → JWT text                                         |
| Sources      | `GET /api/settings/sources` → `{ "<S>": { used, usedAlt, total, … } }`    |
| List dir     | `GET /api/resources?path=<p>&source=<S>` → `{folders[], files[]}`         |
| Checksum     | `GET /api/resources?path=<p>&source=<S>&checksum=<algo>`                  |
| Download     | `GET /api/resources/download?source=<S>&file=<p>` (repeat `file=` + `algo=zip` to bundle) |
| Preview      | `GET /api/resources/preview?source=<S>&path=<p>&size=<small\|large\|original>` |
| Upload       | `POST /api/resources?path=<p>&source=<S>&override=…`, raw bytes as the body |
| New folder   | `POST /api/resources?path=<p>&source=<S>&isDir=true`                      |
| Delete       | `DELETE /api/resources?path=<p>&source=<S>`                               |
| Move / copy  | `PATCH /api/resources`, JSON `{action, items:[{fromSource,fromPath,toSource,toPath}], overwrite, rename}` |
| Search       | `GET /api/tools/search?query=<q>&sources=<S>&scope=<base/>` → JSON array  |
| Disk usage   | `GET /api/settings/sources` → per-source `usedAlt` / `total`             |
| Shares       | `GET /api/share/list`, `GET/POST /api/share`, `DELETE /api/share?hash=…`  |
| Settings     | `GET /api/settings` (admin-only capabilities/branding; degrades on 403)   |

All authenticated requests send the JWT in the `Authorization: Bearer <jwt>`
header. Token renewal is handled by an interceptor that performs at most one
renew + replay per request. Public share pages are served at
`/public/share/<hash>`.

## Project layout

```
lib/
  main.dart
  src/
    app.dart                     # MaterialApp + auth gate (setup/lock/source/browser)
    api/
      models.dart                # FbResource, FbUser, FbUsage, FbShare, FbSource,
                                 #   FbServerCaps/FbTusConfig, FbSearchResult
      filebrowser_client.dart    # HTTP client: auth/renew, sources, list, download,
                                 #   bundle, upload, move/copy, search, usage,
                                 #   shares, settings, checksum
      share_link.dart            # public share-link URL builder
    auth/
      secure_store.dart          # Keystore-backed credential storage
      auth_controller.dart       # biometric gate + direct login + JWT lifecycle
    data/
      preferences_store.dart     # typed non-secret UI prefs (sort order, source)
    transfers/
      transfer_record.dart       # transfer model + progress state
      transfer_service.dart      # background_downloader wrapper + updates
    ui/
      login_screen.dart          # first-run setup, biometric lock, SourceSelectScreen
      browser_screen.dart        # directory browser
      breadcrumbs.dart           # path breadcrumb bar
      selection_controller.dart  # multiselect state
      batch_ops.dart             # batch copy/move/delete/download
      destination_picker.dart    # folder picker for copy/move
      search_screen.dart         # search within the source
      file_details_sheet.dart    # details + on-demand checksum
      status_screen.dart         # disk usage / user / server caps
      shares_screen.dart         # list/delete shares
      share_dialog.dart          # create share link (password/expiry)
      upload_conflict.dart       # overwrite/skip/keep-both resolution
      transfers_screen.dart      # live upload/download progress
      image_gallery_screen.dart  # zoomable photo viewer
      video_player_screen.dart   # in-app video playback
      error_display.dart         # copyable error view + retry
```

## Dependencies

| Package                   | Purpose                                               |
| ------------------------- | ----------------------------------------------------- |
| `dio`                     | HTTP client + interceptors (auth/renew)               |
| `cached_network_image`    | Gallery thumbnails / image caching                    |
| `photo_view`              | Zoomable image viewer                                  |
| `video_player` + `chewie` | In-app video playback                                 |
| `flutter_secure_storage`  | Keystore-backed credential storage                    |
| `local_auth`              | Biometric / device-credential unlock                  |
| `background_downloader`   | Foreground-service uploads/downloads + notifications   |
| `provider`                | State management / DI                                 |
| `file_picker`             | File picking + SAF directory targets                  |
| `open_filex`              | Open-with hand-off to native apps                     |
| `share_plus`              | System share sheet for share-link URLs                |
| `shared_preferences`      | Typed non-secret UI preferences (sort order, source)  |
| `receive_sharing_intent`  | Share-into-app (SEND / SEND_MULTIPLE)                 |
| `path` / `path_provider`  | Path utilities + app directories                      |

## Build & run

```bash
export PATH="$HOME/flutter/bin:$PATH"
flutter pub get
flutter analyze
flutter test
flutter run            # on a connected device/emulator
flutter build apk      # release APK in build/app/outputs/flutter-apk/
```

The native `android/` project is committed and already configured (see below);
no `flutter create` step is required.

## Development & testing

A `Makefile` wraps the common workflows (it prepends `$HOME/flutter/bin` to PATH
when flutter isn't already resolvable):

| Target         | What it does                                                      |
| -------------- | ---------------------------------------------------------------- |
| `make get`     | `flutter pub get`                                                |
| `make analyze` | static analysis                                                  |
| `make test`    | unit + widget tests (no server; integration tag excluded)        |
| `make ci`      | `get` + `analyze` + `test` — mirrors the PR `unit` gate           |
| `make serve`   | boot the official quantum test server on `:8080`                 |
| `make e2e`     | serve + run the integration-tagged tests, then stop the server   |
| `make clean`   | `flutter clean` + drop the test-server work dir                  |

- **Unit / widget tests** live under `test/` and run with a bare `flutter test`.
- **Integration tests** (`test/integration/quantum_api_test.dart`, tagged
  `@Tags(['integration'])`) are pure-Dart API tests with no emulator: they point a
  real `FileBrowserClient` at a running quantum server (`FB_TEST_URL`, default
  `http://localhost:8080`) and exercise the migrated contracts end-to-end — login,
  list, mkdir, upload, single + bundle download, checksum, copy/move/rename,
  delete, 409 conflict, search, and share create/list/delete. They are
  skip-by-default (`dart_test.yaml`) so a normal `flutter test` needs no server;
  opt in with `flutter test --tags integration --run-skipped`.
- **`tool/serve.sh {setup|run}`** downloads the official quantum release binary,
  writes a config, seeds a small data tree, and runs the server on `:8080`. All
  artifacts land under the gitignored `.quantum-test/`.
- **GitHub Actions** (`.github/workflows/ci.yml`) runs on push/PR: a fast `unit`
  job (pub get → analyze → `flutter test --exclude-tags integration`) and an
  `integration` job that boots the quantum server via `tool/serve.sh` and runs the
  integration-tagged tests against it.

## Android configuration (already present)

`android/app/src/main/AndroidManifest.xml` ships with:

- Permissions: `INTERNET`, `USE_BIOMETRIC`, `POST_NOTIFICATIONS`,
  `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_DATA_SYNC` (the last two for the
  `background_downloader` foreground service).
- **Share-into-app intent filters** on `MainActivity`: `SEND` and `SEND_MULTIPLE`
  for `image/*`, `video/*`, `audio/*`, and `application/*`.
- `android:usesCleartextTraffic="true"` so plain-HTTP quantum instances work
  (use HTTPS in production).

`local_auth` requires the host Activity to extend `FlutterFragmentActivity`, and
`minSdkVersion` is set to 23+ for biometrics — both are already configured.

## Known device-only caveats

- **No resumable uploads.** Uploads go out as a single `POST` of raw bytes via
  `background_downloader`; a plain POST can't be paused/resumed, so an
  interrupted large upload restarts.
- **Downloads / save location** rely on Android SAF and scoped storage; the
  exact destination depends on the folder you grant, and behaviour varies by
  Android version.
- **Share-into-app and open-with** depend on the device's installed apps and
  Android intent routing; these flows are verified on a physical device, not in
  the widget tests.
