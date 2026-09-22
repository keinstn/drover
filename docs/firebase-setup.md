# Firebase and Google Cloud setup

This guide creates the Firebase and Google Cloud resources used by Drover's
anonymous authentication, push notifications, and notification relay.

Use placeholders such as `<PROJECT_ID>` in commands. Do not commit project
identifiers, service-account credentials, APNs keys, App Check debug tokens,
pairing codes, host credentials, or `GoogleService-Info.plist` files.

## Prerequisites

Install and authenticate the Firebase CLI and Google Cloud CLI:

```sh
firebase login
gcloud auth login
gcloud auth application-default login
```

Create or select a Google Cloud project, then create its Firebase project.
Cloud Functions deployment requires the Blaze billing plan. Grant deployment
users the Firebase and Google Cloud roles required to deploy Functions; do not
create or commit a service-account key just for local development.

Select the local Firebase CLI project alias after cloning:

```sh
firebase use --add
```

The resulting `.firebaserc` is intentionally ignored because it identifies a
deployment environment.

## Firebase products

Enable these products in Firebase Console:

1. **Authentication** — enable the Anonymous provider.
2. **Cloud Firestore** — create the default database. Choose a location that
   fits the deployment before creation; the location cannot be changed later.
3. **Cloud Messaging** — configure the Apple APNs authentication key for the
   iOS app.
4. **App Check** — register each distributed Apple app. Drover uses App Attest
   on iOS Release builds. Register the Debug provider separately for local
   debug builds.

Register the iOS app in Firebase and place its downloaded configuration file at:

```text
app/ios/Runner/GoogleService-Info.plist
```

The file is excluded from Git. For CI/Xcode Cloud, inject it using that
platform's secret or secure-file facility. A fresh clone or worktree cannot
build for iOS until it is copied in — and, since the artwork below joined it,
cannot run `fvm flutter test` either: the asset bundle is built before any
test runs, so a missing file aborts the whole suite rather than one target. Register the macOS app and add its
plist only when distributing the macOS target; App Check is currently
activated only on iOS.

## Sign in with Apple artwork

The second file a fresh clone or worktree needs, for the same reason: Apple's
licence for their design resources forbids redistributing the artwork, and
this repository is public, so the Sign in with Apple mark is gitignored too.
Without it `flutter build` and `flutter test` both stop at the missing asset.

Download [Logo - Sign in with
Apple](https://devimages-cdn.apple.com/design/resources/download/Logo-Sign-in-with-Apple.dmg)
and mount it, which means accepting Apple's licence. From
`Sign in with Apple - Logo Only/PNG`, copy the logo-only marks — the app draws
its own localised title, so the left-aligned logo-with-text files are the
wrong ones — into `app/assets/sign_in_with_apple`:

```text
1x/Logo - SIWA - Logo-only - Black@1x.png -> mark_black.png
1x/Logo - SIWA - Logo-only - White@1x.png -> mark_white.png
2x/Logo - SIWA - Logo-only - Black@2x.png -> 2.0x/mark_black.png
2x/Logo - SIWA - Logo-only - White@2x.png -> 2.0x/mark_white.png
3x/Logo - SIWA - Logo-only - Black@3x.png -> 3.0x/mark_black.png
3x/Logo - SIWA - Logo-only - White@3x.png -> 3.0x/mark_white.png
```

For Xcode Cloud the six travel as a single base64'd archive in the
`SIGN_IN_WITH_APPLE_ASSETS_BASE64` environment secret, which
`app/ios/ci_scripts/ci_pre_xcodebuild.sh` unpacks. Produce its value from a
checkout that already has them:

```sh
COPYFILE_DISABLE=1 tar -czf - -C app/assets sign_in_with_apple | base64 | pbcopy
```

In the Apple Developer portal, enable Push Notifications and App Attest for
the iOS App ID. The iOS target already contains the corresponding
entitlements. Enable the iOS Remote notifications Background Mode in Xcode.

## Deploy backend resources

Install Functions dependencies, then deploy the checked backend:

```sh
just functions-get
firebase deploy --only functions
```

Firestore client access is intentionally denied by `firestore.rules`; Cloud
Functions use the Admin SDK to access notification data.

Configure Firestore TTL for notification-event deduplication. This policy is
not represented in `firebase.json`, so configure it once using the Google
Cloud CLI or Console:

```sh
gcloud firestore fields ttls update expiresAt \
  --collection-group=events \
  --enable-ttl \
  --project=<PROJECT_ID>
```

`pairingCodes` documents carry `expiresAt` too, and abandoned pairing attempts
accumulate permanently without a matching policy:

```sh
gcloud firestore fields ttls update expiresAt \
  --collection-group=pairingCodes \
  --enable-ttl \
  --project=<PROJECT_ID>
```

Check both policies:

```sh
gcloud firestore fields ttls list --project=<PROJECT_ID>
```

Confirm `events` and `pairingCodes` both appear in the output.

TTL deletion is asynchronous. `events` and `pairingCodes` documents remain
harmless after their `expiresAt` value until Firestore's background cleanup
deletes them.

## App Check verification and enforcement

First distribute an iOS Release build, start Drover, and perform an app-facing
Callable Function action such as creating a pairing code. Confirm App Check
before enabling enforcement:

```sh
gcloud logging read '
  labels."firebase-log-type"="callable-request-verification"
' \
  --project=<PROJECT_ID> \
  --limit=20 \
  --format=json
```

The latest relevant entry must contain:

```json
{
  "verifications": {
    "app": "VALID",
    "auth": "VALID"
  }
}
```

After that verification, deploy the Functions version that sets
`enforceAppCheck: true` for app-facing Callable Functions. Do not enforce App
Check for the plugin's HTTP endpoints: `completePairing` is protected by a
short-lived one-time pairing code, and `sendBlockedNotification` is protected
by its paired-host credential.

## Continue with host pairing

After Firebase resources are deployed, follow
[Push notifications](push-notifications.md) to link and pair the Herdr plugin.
