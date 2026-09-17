# Charging for voice

A design note, not a built feature. Nothing here is implemented; the voice
assistant is free while it lives on the `voice-live` branch. Written
2026-09-13.

If voice is ever sold, it is sold as prepaid **Voice Credits** through an Apple
consumable in-app purchase, and that needs two pieces of backend that drover
does not have:

- **Firebase Functions v2 + Firestore** for purchase verification, the wallet,
  an immutable ledger, and refunds.
- **Cloud Run** as a Voice Gateway: the app connects there instead of to Gemini,
  and the relay meters the session and cuts it off when the balance runs out.

Today the client talks to Firebase AI Logic directly. That is fine for a free
or invite-only beta, but it is not a boundary anyone can be charged against —
see "Why the direct connection cannot enforce a balance" below.

## Credits, not minutes

Sell consumables (`drover_voice_credits_100`, `_500`, `_1200`), not a
subscription: this is a prepaid balance that drains with use, it needs no
monthly contract or renewal handling, and the user buys only when they need to.

Denominate in credits rather than minutes. Gemini Live is priced on audio and
text tokens and on accumulated context, so wall-clock time and real cost do not
track each other closely enough to sell by the minute.

Under App Store Review Guideline 3.1.1, purchased credits never expire. The
only thing with an expiry is the lease a session takes out against the balance
while it runs.

## Purchase

StoreKit completes the purchase, the app sends the signed transaction to
Functions, and the server verifies it against the App Store Server API before
crediting the wallet. Only after the wallet write succeeds does the app finish
the StoreKit transaction.

The server checks that Apple's signature is valid, that the product ID is one
of ours, that the transaction ID has not already been processed, that
`appAccountToken` matches the Firebase user, and that the purchase has not been
refunded or revoked. `transactionId` is the idempotency key, so a replay
credits nothing twice.

App Store Server Notifications V2 feed the same ledger code path. Assume they
arrive late, duplicated, and out of order.

## Identity

Drover uses anonymous auth. That is enough to authenticate against Firebase AI
Logic, but too weak to restore a balance against. So the flow is anonymous on
first launch, Sign in with Apple before the first
purchase, and `appAccountToken` bound to the Firebase UID at purchase time. If
purchasing while anonymous is ever allowed, the app has to say plainly that the
balance may not survive a reinstall or a new device.

## Voice Gateway

A paid session runs through Cloud Run, not straight to Gemini:

```text
1. App connects to Cloud Run
2. Gateway verifies Firebase Auth and App Check
3. Gateway reads the balance from Firestore
4. Gateway reserves credits for the session
5. Gateway opens the Gemini Live connection
6. Audio is relayed over the WebSocket
7. Usage is metered as it goes
8. The session is cut off if the balance runs out
9. On close, actual usage is settled and the unused reservation returned
```

Do not write to Firestore per audio chunk. Reserve a block, top it up while the
session runs, and touch the ledger only at start, top-up and settlement.

Cloud Run rather than Functions because it supports WebSockets and long-lived
connections as a first-class case. It still caps connection lifetime, so the
relay has to implement Live API session resumption and reconnect.

## Firestore model

```text
users/{uid}/wallet
  available
  reserved
  updatedAt

users/{uid}/walletTransactions/{transactionId}
  type: purchase | consume | refund
  credits
  productId
  appleTransactionId
  createdAt

voiceSessions/{sessionId}
  uid
  reservedCredits
  consumedCredits
  status
  startedAt
  endedAt
```

Every balance change happens inside a Firestore transaction, keyed for
idempotency on the Apple transaction ID, the voice session ID, or the
settlement sequence number. A crashed relay leaves a lease behind; the
recovery path is to detect expiry and return the unused reservation.

If a refund lands after the credits were already spent, do not delete history.
Write a negative ledger event, and if that leaves the balance short, either
stop new sessions or hand it to support.

## Why the direct connection cannot enforce a balance

The shortcut — check the balance in Functions, let the client connect to AI
Logic itself, report usage afterwards — reads like it works and does not. A
modified client skips the check, an old build ignores whatever limit was added
later, the server never sees the audio it is billing for, and nothing can hang
up on a session whose credits ran out. It is fine for a free beta and unusable
as a paywall.

Underneath that sits a harder limit. As of `firebase_ai` 4.0.0, checked
2026-09-17, the SDK never surfaces `usageMetadata` on the Live path: `api.dart`
parses it for `generateContent`, but `LiveServerResponse` carries nothing but a
`LiveServerMessage`, no variant of that sealed type holds usage, and the string
does not appear in `live_api.dart`, `live_session.dart` or `live_model.dart` at
all. The app therefore cannot see what a voice session cost, at any point on
the client path. So the relay is not only where a balance can be enforced — it
is the only place a meter can exist, because only a raw Live WebSocket sees the
field. Re-check this against a newer `firebase_ai` before relying on it.

## Before setting a price

Measure first: input audio tokens, output audio tokens, input and output text
tokens, session length, usage after context compression, Cloud Run's
concurrency and egress, and the gap between reported usage and what Cloud
Billing settles at. None of it can be measured from the app, for the reason
above — it takes either a raw Live WebSocket probe, which is the relay's first
slice rather than throwaway work, or cost deltas read out of the billing
export. See [billing-cli-setup.md](billing-cli-setup.md) for the latter.

The price then has to cover the Gemini cost plus Apple's cut, Firebase and
Cloud Run, headroom for refunds and abuse, and headroom for model price and
exchange-rate moves.

`gemini-3.1-flash-live-preview` is a preview model. Confirm a stable Live model
is available before selling anything against it; while it is still preview,
voice stays on an invite-only TestFlight beta.

## Order of work

Free beta first: measure the real cost, add explicit consent for sending audio
to an AI service, turn on AI monitoring and the billing export, verify the
production App Check configuration, and cap session length. Then the billing
control plane — `in_app_purchase`, consumable products, server-side transaction
verification, `appAccountToken` binding, the wallet and ledger, Server
Notifications V2, refund and revoke handling. The paid gateway comes last:
the Cloud Run relay, auth and App Check checks, reserve/settle/return, stored
`usageMetadata`, disconnect on empty balance, crash recovery, and a daily
reconciliation against Cloud Billing. All three are validated in the StoreKit
sandbox and on TestFlight.

## References

- [App Store Review Guidelines 3.1.1](https://developer.apple.com/app-store/review/guidelines/)
- [App Store Server API](https://developer.apple.com/documentation/appstoreserverapi)
- [App Store Server Notifications](https://developer.apple.com/documentation/appstoreservernotifications)
- [Cloud Run WebSockets](https://cloud.google.com/run/docs/triggering/websockets)
