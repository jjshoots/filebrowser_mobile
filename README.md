# File Browser — Android client (Flutter)

A self-hosted [File Browser](https://github.com/filebrowser/filebrowser) mobile
client for Android. Built and tested with **Flutter 3.44.4 / Dart 3.12**
(`flutter analyze` is clean and the test suite is green).

It pairs biometric-gated, captcha-friendly login with a full file-management UI:
browse, multiselect batch operations, move/copy with conflict handling, search,
share links, server status, background uploads/downloads, share-into-app, and
open-with hand-off.

## Features

- **Login**
  - **Biometric / device-credential unlock** — credentials live in the Android
    Keystore / EncryptedSharedPreferences (`flutter_secure_storage`) and unlock
    with fingerprint/face or device PIN (`local_auth`).
  - **Captcha-friendly WebView login** — the first login (and any forced
    re-login) happens in an in-app WebView so reCAPTCHA / login pages render
    normally; the app then **harvests the JWT** from the authenticated session.
  - **Captcha-free keep-alive** — the cached JWT is refreshed via `/api/renew`
    (no captcha) before it expires and on a 401, so day-to-day use never bounces
    back to the WebView. Only an unrecoverable session sends you back there.
- **Browse**
  - Directory listing with **breadcrumb** navigation.
  - **Persisted sort** by name / size / date (client-side, natural order),
    remembered across launches (`shared_preferences`).
  - **Multiselect** with batch **copy / move / delete / download**, plus a
    **destination picker** for copy/move targets.
  - **New folder** and single-item **rename**.
- **Search** — full-text search under the current directory.
- **File details** — size, timestamps, and an on-demand **checksum**
  (md5/sha1/sha256/sha512) fetched only when requested.
- **Status page** — server **disk usage**, signed-in user, and server
  capabilities (including the tus chunk size when advertised).
- **Share links** — create/list/delete public share links, optional password and
  expiry; the link is handed to the system share sheet (`share_plus`).
- **In-app media** — zoomable image gallery (`photo_view`,
  `cached_network_image`) and a video player (`video_player` + `chewie`),
  streaming straight from `/api/raw`.
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

| Action       | Request                                                               |
| ------------ | --------------------------------------------------------------------- |
| Login        | Captcha WebView session → JWT harvested (server `POST /api/login`)     |
| Renew        | `POST /api/renew` with `X-Auth` (captcha-free keep-alive)             |
| List dir     | `GET /api/resources/<path>` → JSON listing                            |
| Download     | `GET /api/raw/<path>` (`?algo=zip`, or `?files=` to bundle entries)   |
| Upload       | `POST /api/resources/<path>?override=…`, raw bytes as the body        |
| Move / copy  | `PATCH /api/resources/<src>?action=rename|copy&destination=…`         |
| New folder   | `POST /api/resources/<path>/`                                         |
| Delete       | `DELETE /api/resources/<path>`                                        |
| Search       | `GET /api/search/<path>?query=…` (newline-delimited JSON)             |
| Checksum     | `GET /api/resources/<path>?checksum=<algo>`                          |
| Disk usage   | `GET /api/usage/<path>` → `{total, used}`                            |
| Shares       | `GET/POST/DELETE /api/shares` & `/api/share/<path|hash>`             |
| Settings     | `GET /api/settings` (admin-only capabilities/branding)               |
| Preview      | `GET /api/preview/<thumb|big>/<path>`                                |

All authenticated requests send the JWT in the `X-Auth` header. Token renewal is
handled by an interceptor that performs at most one renew + replay per request.

## Project layout

```
lib/
  main.dart
  src/
    app.dart                     # MaterialApp + auth gate (setup/lock/browser)
    api/
      models.dart                # FbResource, FbUser, FbUsage, FbShare,
                                 #   FbServerCaps/FbTusConfig, FbSearchResult
      filebrowser_client.dart    # HTTP client: auth/renew, list, raw/bundle
                                 #   download, upload, move/copy, search,
                                 #   usage, shares, settings, checksum
      share_link.dart            # public share-link URL builder
    auth/
      secure_store.dart          # Keystore-backed credential storage
      auth_controller.dart       # biometric gate + JWT lifecycle/renew
    data/
      preferences_store.dart     # typed non-secret UI prefs (sort order)
    transfers/
      transfer_record.dart       # transfer model + progress state
      transfer_service.dart      # background_downloader wrapper + updates
    ui/
      login_screen.dart          # first-run setup + biometric lock screen
      webview_login_screen.dart  # captcha WebView login + JWT harvest
      browser_screen.dart        # directory browser
      breadcrumbs.dart           # path breadcrumb bar
      selection_controller.dart  # multiselect state
      batch_ops.dart             # batch copy/move/delete/download
      destination_picker.dart    # folder picker for copy/move
      search_screen.dart         # full-text search
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
| `webview_flutter`         | Captcha login WebView + JWT harvest                   |
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
| `shared_preferences`      | Typed non-secret UI preferences (sort order)          |
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

## Android configuration (already present)

`android/app/src/main/AndroidManifest.xml` ships with:

- Permissions: `INTERNET`, `USE_BIOMETRIC`, `POST_NOTIFICATIONS`,
  `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_DATA_SYNC` (the last two for the
  `background_downloader` foreground service).
- **Share-into-app intent filters** on `MainActivity`: `SEND` and `SEND_MULTIPLE`
  for `image/*`, `video/*`, `audio/*`, and `application/*`.
- `android:usesCleartextTraffic="true"` so plain-HTTP File Browser instances work
  (use HTTPS in production).

`local_auth` requires the host Activity to extend `FlutterFragmentActivity`, and
`minSdkVersion` is set to 23+ for biometrics — both are already configured.

## Known device-only caveats

- **No resumable uploads.** Uploads go out as a single `POST` of raw bytes via
  `background_downloader`; a plain POST can't be paused/resumed, so an
  interrupted large upload restarts. The server's tus endpoint is not used (the
  advertised tus chunk size is shown on the Status page for reference only).
- **Downloads / save location** rely on Android SAF and scoped storage; the
  exact destination depends on the folder you grant, and behaviour varies by
  Android version.
- **Share-into-app and open-with** depend on the device's installed apps and
  Android intent routing; these flows are verified on a physical device, not in
  the widget tests.
