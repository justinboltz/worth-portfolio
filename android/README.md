# Worth for Android

An installable Hotwire Native app using the same Rails pages, accounts, and database
as the web app. The local debug build is named **Worth Dev**, with package ID
`app.worth.mobile.debug`. It supports Android 9/API 28 or later.

## Try it on a Pixel

1. Run Worth on your Mac at `http://localhost:3000` (`bin/demo`).
2. Enable Developer options on the Pixel by tapping **Settings → About phone →
   Build number** seven times, then enable **System → Developer options → USB
   debugging**.
3. Connect a data-capable USB cable, unlock the phone, and accept the Mac's USB
   debugging authorization prompt.
4. From the repository root, run:

   ```sh
   bin/android build
   bin/android devices
   bin/android install
   ```

The install command forwards the Pixel's port 3000 to your Mac, installs the APK,
and launches Worth Dev. Sign in with the same fictional account shown by the demo.
Sessions are separate; transactions, categories, budgets, imports, and assets are
shared immediately through Rails. Refresh a screen to see changes from another device.

Keep the Mac and Rails server running. If USB forwarding is lost after reconnecting
or restarting the phone, run `bin/android connect`. With more than one connected
device, pass its serial to `install` or `connect`.

The standalone APK is written to `tmp/android-builds/Worth-debug.apk`. It can also
be installed manually, but it still needs the forwarded connection to your Mac.
An emulator can use the same `adb reverse` connection.

## Included

- Shared responsive Rails screens and sign-in.
- Native back navigation, loading and connection-error screens, and retry.
- Pull-to-refresh on browsing screens; disabled on new/edit/import-review screens.
- A native toolbar menu with Refresh and Open in browser.
- The Android file picker for CSV uploads.
- A launcher icon and local debug signing.

Bank linking and CSV exports open in a browser tab for now. The browser has a
separate session: sign in with the same Worth account there if prompted. After an
initial browser sign-in, navigate to Connect a bank or Export CSV again if Rails
returns you to Overview. Return to Worth Dev and refresh to see changes.
Native Plaid Link/OAuth, native downloads, push, biometrics, offline operation,
subscriptions, and Play Store release setup are not implemented.

## Build tools

`bin/android` uses JDK 17+, the Gradle wrapper, and an Android SDK with platform 36,
build-tools 36.0.0, and platform-tools. Set `ANDROID_HOME` to an SDK installed
through Android Studio or the command-line tools. Open this `android` directory in Android Studio
after the first command-line build.

With the official Android command-line tools installed:

```sh
sdkmanager --licenses
sdkmanager 'platform-tools' 'platforms;android-36' 'build-tools;36.0.0'
```

`bin/android check` runs JVM unit tests and Android lint. Build outputs, local SDK
paths, caches, device authorization keys, and the debug keystore are ignored by Git.
Keep `android/.local/debug.keystore` to install future debug updates without
uninstalling the app. This key is for local development, not a Play Store release.

## Hosted backend later

```sh
bin/android build -PworthBaseUrl=https://your-worth-host.example
```

The URL is compiled into the APK. Use the origin only, without credentials, a path,
or query parameters. HTTP is limited to localhost, 127.0.0.1, and the emulator's
10.0.2.2 alias in debug builds. The main network policy requires HTTPS; release
variants are disabled until an HTTPS backend is explicitly configured. Release
signing and publication are separate work.

No Rails credentials or Plaid secrets are included in the Android app. The server
continues to own authentication, database access, and all Plaid API requests.

References: [Hotwire Native](https://native.hotwired.dev/android/getting-started),
[Android USB debugging](https://developer.android.com/studio/debug/dev-options).
