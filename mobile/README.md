# Cobridey mobile apps

## Android beta

The first Android package is a Trusted Web Activity using Google's Android Browser
Helper 2.7.4. It opens the existing HTTPS application at
`https://www.cobridey.com/journey.html#home`. No separate database, copied wedding
data, embedded service key, or WebView authentication implementation is introduced.
Website fixes appear in the app through the live site. An internet connection is
required for cloud operations. Existing opt-in offline preparation remains separate.

`com.cobridey.app.beta` is an internal-test package; the eventual store identifier is
`com.cobridey.app`. Minimum Android version is 7.0 (API 24). A current TWA-capable
browser is required; use current Chrome for the first test. Other origins display
browser controls deliberately. No certificate or origin-verification bypass is used.

The Android beta GitHub Actions workflow builds a signed debug APK and runs Android
Lint on Ubuntu with JDK 17, Gradle 8.13, Android platform 36 and AGP 8.13.2. It does
not publish to a store. The artifact contains the APK, build hash, public signing
certificate, candidate website association and installation notes; no private key.

### Website association

Full-screen trust requires the exact APK certificate at
`https://www.cobridey.com/.well-known/assetlinks.json`. Only publish the generated
`assetlinks.beta.json` after verifying its APK/build provenance. Do not use invented
fingerprints. The website build copies `.well-known/assetlinks.json` when present.
Until association succeeds the browser can show its address bar.

The first successful internal build is GitHub Actions run `43806124730`, from
commit `1d99b2de26a8105c6c659fda78a7c9db8fea6cd9`. Its verified APK SHA-256 is
`4cb482f2231970606ea96fdb76ac26d90069d31ec4ba5b5e06a89fdab5ec1d63`.
The checked-in asset link authorizes only that beta signing certificate. This
does not authorize future CI debug keys or the eventual Play signing key.

The CI debug key is temporary, so later test builds may need reinstalling. Do not
uninstall with pending unsynced work. Before ongoing beta distribution, establish
an owner-controlled protected signing key and backup; before Play release, use the
Play App Signing certificate in the website association. Never commit a keystore.

### Local build

Install Android Studio/SDK platform 36 and JDK 17, set the SDK path locally, then run
`gradle :app:assembleDebug :app:lintDebug` from `mobile/android` with Gradle 8.13.
The repository currently does not bundle a Gradle wrapper; CI installs pinned Gradle.
No Android SDK licenses are silently accepted by repository scripts.

### Required device testing

- New-account onboarding and empty workspace; existing-account data and isolation.
- Password login, Google login, logout, process death/reopen, password-reset email.
- Mobile menu, Android back, keyboard, orientation, dialogs and screen cutouts.
- Image/file uploads, camera/file picker, PDF/Word/image exports and downloads.
- Instagram/Pinterest embeds, retailer links, WhatsApp links and website sharing.
- Offline launch/reconnect and pending-save recovery without data loss.

The launcher does not intercept email/OAuth callback intents. Keep Google consent
in the browser and retain PKCE verification; never put OAuth secrets into the APK.
App lifecycle/session persistence must be proven on a real device, not inferred
from a successful package build. Push notifications, share-to-app and native billing
are not included. No public launch-readiness or store approval is implied.

## Installable web app

The shared manifest supplies app identity and icons. On compatible browsers users
can install from the browser menu; no promotional install UI is added. A minimal
service worker caches only the public reconnect page. It never caches account/API
responses or replaces an existing opt-in offline worker. It does not change quotas.

## iPhone

The Android TWA cannot be reused as an iPhone binary. The planned iPhone container
requires a separate Capacitor build, API-origin/auth/download adapters, native
sign-in review, macOS/Xcode build infrastructure, signing and physical-device tests.
Neither an iOS project nor a signed iPhone build is delivered by the Android workflow.
Apple Developer/Google Play accounts will be needed for store distribution. Do not
promise a paid cloud provider, store acceptance, or push notifications until chosen
and implemented. Existing web billing must be reviewed against store rules before
selling digital plans inside store-distributed apps.

References:
- https://developer.chrome.com/docs/android/trusted-web-activity/integration-guide
- https://github.com/GoogleChrome/android-browser-helper
- https://capacitorjs.com/docs/getting-started/environment-setup
