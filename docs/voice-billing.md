# Charging for voice

Part record, part design note. The gate is built: a session opens only on a
token from `mintVoiceToken`, which debits a credit wallet and refuses when the
balance is empty (#267, #269, #274), and the wallet, its ledger and the Sign in
with Apple identity they hang off exist too — see "Identity", built 2026-09-20.
What is still a design note is everything that would put credits in that
wallet: the in-app purchase, `verifyPurchase`, Server Notifications V2 and
refunds, and the Cloud Run relay. Nothing is sold — credits get in by hand in
the Firebase console, or from the free campaign below — and the voice assistant
is free while it lives on the `voice-live` branch. Written 2026-09-13, revised
2026-09-18 after the ephemeral-token measurements below, 2026-09-19 with the
four flows drawn, and 2026-09-21 after the move to `gemini-3.8-live`, to record
what had shipped, and again for the free campaign.

If voice is ever sold, it is sold as prepaid **Voice Credits** through an Apple
consumable in-app purchase. One piece of backend is needed whatever else is
decided:

- **Firebase Functions v2 + Firestore** for purchase verification, the wallet,
  an immutable ledger, and refunds.

How a session is gated against that wallet is a separate choice, and there are
two designs rather than one:

- **An ephemeral Live API token**, minted by a Function that checks the balance
  first. The app still connects to Gemini itself, with a credential that is
  good for one bounded window. Measured 2026-09-18 and it holds — see "Gating
  a direct connection with an ephemeral token". What it sells is one call: one
  mint grants one window, and nothing inside it can extend it.
- **Cloud Run** as a Voice Gateway: the app connects there instead of to Gemini,
  and the relay meters the session and cuts it off when the balance runs out.
  This is the only design that meters what was actually consumed.

The minted token is the one that shipped. The client connects to the Gemini API
itself, and a session opens only on a token minted after the balance was
checked — so a call is already a boundary that can be charged against, and what
is missing is only a way to buy the credits. A relay is required only to sell
consumption rather than calls.

## Shape

```mermaid
flowchart LR
  subgraph device[Device]
    App[drover app]
    SK[StoreKit]
  end
  subgraph ours[Ours]
    Verify[verifyPurchase Function]
    Notify[appleNotifications Function]
    Mint[mintVoiceToken Function]
    FS[(Firestore wallet and ledger)]
  end
  subgraph apple[Apple]
    ASS[App Store Server]
  end
  Auth[Gemini auth tokens endpoint]
  Gemini[[Gemini Live API]]

  SK -->|signed transaction| App
  App -->|signed transaction| Verify
  Verify -->|check the transaction| ASS
  ASS -.->|Server Notification, late| Notify
  Verify --> FS
  Notify --> FS
  App -->|balance check and one mint| Mint
  Mint --> FS
  Mint -->|mint a token before the call| Auth
  Auth -.->|token| Mint
  App <-->|audio| Gemini
```

Of those boxes only the app, `mintVoiceToken` and Gemini exist today, and the
mint checks nothing but auth and App Check. Everything else is this note.

The only hop we own is the mint, and it happens once, before the call. The
audio itself runs from the device to Gemini with no server of ours in the path
— which is the whole reason the relay below is optional rather than assumed.

## Credits, not minutes

Sell consumables (`drover_voice_credits_<count>`), not a subscription: this is
a prepaid balance that drains with use, it needs no monthly contract or renewal
handling, and the user buys only when they need to.

Denominate in credits rather than minutes. Gemini Live is priced on audio and
text tokens and on accumulated context, so wall-clock time and real cost do not
track each other closely enough to sell by the minute.

The count a pack grants lives in its product id; what a credit *buys* lives on
the server. Apple's product ids are immutable, so a number of minutes baked
into one is a promise the runtime cannot keep — the model changes price, the
cap moves, and the cost of a turn depends on how late in the conversation it
falls. Keeping the conversion server-side means what a credit buys can change
without an App Store release.

Under App Store Review Guideline 3.1.1, purchased credits never expire. The
only thing with an expiry is what a session holds while it runs — a lease
against the balance under the relay design, the minted token itself under the
other.

The ephemeral-token design cuts across this and the tension is real rather than
cosmetic. A minted token bounds a window of time, so time is the only thing it
can meter; but cost is quadratic in turn count (below), so a window of fixed
length costs a variable amount. Under that design the session cap
(`kVoiceSessionCap`) stops being only a safety rail and becomes the thing that
bounds the variance. Credits that drain with measured use need the relay.

## The free campaign

Nothing is sold yet, but the app ships publicly, so credits have to get into a
wallet without somebody typing them. The campaign is that: a handful of free
credits per account per month, and one ceiling over the whole thing so the
bill cannot run away while nobody is watching.

Its dials live in `config/voiceCampaign`, a document edited by hand in the
Firebase console the same way credits are:

```text
config/voiceCampaign
  callsUsed   number   calls the campaign has paid for so far
  callLimit   number   the ceiling                    (default 130)
  enabled     boolean  false is the emergency stop     (default true)
  freeGrant   number   the monthly per-account allowance (default 5)
```

Every field is optional and every one has a default in `functions/src/wallet.ts`
next to `voiceCallCost`. A missing document is a running campaign on the
defaults — nobody should have to create one before the first call works — and a
field that is missing or malformed falls back on its own, the same refusal to
believe a hand-edited document that `walletCredits` already makes about a
balance. The constants in code are only that fallback: the *limit* has to be
movable without a deploy, which is why it lives in the document.

**The ceiling is a call count standing in for a budget.** 130 calls is a
¥2,000 budget at a conservative ¥15 a call, against a measured ~¥6 on average
and ~¥25 at the worst modelled case. It is a count and not an amount of money
because money cannot be metered live: the billing export lags about a day, so
by the time spend is visible it has already happened. That makes the number a
calibration knob, not a measurement — it has to be re-checked against the real
per-call cost as calls accumulate, and moved in the console when the two drift
apart.

`callsUsed` moves in the same commit as the wallet debit and the ledger row,
inside `claimVoiceCall`'s existing transaction, and a failed mint gives the
call back in the same batch that refunds the credit. Counted apart, a crash
between the two would leave the campaign and the wallets disagreeing.

### Two refusals that look alike

Both come back as `resource-exhausted`, and the app has to tell them apart,
because "you are out of credits" and "the free campaign has ended" ask the
reader to do different things. `HttpsError`'s third argument carries which:

- `details: { reason: "noCredits" }` — this account's balance is empty.
- `details: { reason: "campaignOver" }` — the ceiling is reached, or `enabled`
  is `false`.

`campaignOver` is checked first, so somebody who still holds credits is not
told they have none when the campaign is what ended.

Neither refusal can reach a call that is already running. The campaign is
checked *below* the reuse branch in `voiceMintDecision`: a conversation
re-mints to carry on, every re-mint carries the session ID the call started
with, and those return `reuse` before the ceiling is ever consulted. So the
call that spends the campaign's last credit finishes normally, and a re-mint
neither counts nor is refused. That ordering is the whole point of the
function's shape, and it is asserted in `wallet.test.ts` rather than left to
be noticed.

### Who gets the free credits

`freeGrant` credits a month, and only to an account that is **not anonymous**.
The app signs in anonymously at launch and links Sign in with Apple later, and
an anonymous install that is deleted and reinstalled comes back under a fresh
uid — granting to it would be a faucet rather than a campaign. Being linked to
Apple is what makes an account outlive a reinstall, and so what makes a
per-account allowance mean anything. A callable reads this off the verified ID
token as `request.auth.token.firebase.sign_in_provider`, which is
`"anonymous"` until the link and `"apple.com"` after. An anonymous caller gets
nothing and no error: a zero balance, and the ordinary `noCredits` refusal when
it tries to call.

**Monthly rather than once for the life of the account**, because a one-time
grant only ever answers "did they use it up", where a monthly one shows the
*sustained* rate — calls per account per month is the number a price has to be
set against, and it is invisible if everyone is spending a one-off allowance.
It also bounds each account's exposure per month instead of for all time.

The month is a UTC year-month stamped on the wallet as `campaignGrantPeriod`
(`"2026-09"`). A grant is due when that stamp is absent, stale, or anything
other than the current month. UTC rather than the account's own month because
the Function has no idea where the account is, and one instant the world over
is easier to reason about than a boundary that depends on a guess — in Japan
the refill lands at 09:00 on the 1st.

**It tops up to `freeGrant`; it does not add `freeGrant`.** The figure written
is `freeGrant` less what is already there, so a balance of 3 gets 2, a balance
of 0 gets 5, and a balance already at or above the allowance gets nothing.
Credits therefore do not pile up across months in which nobody called: however
long an account has been away, its month is worth `freeGrant` calls. The rule
also cannot ever *reduce* a balance, which is what makes it safe the day
purchased credits share this field.

A top-up of nothing still stamps the month — that account has had its
allowance — but writes no ledger row: the row records the actual delta, and
"granted 0 credits" is a blank line in the activity list. The rows it does
write are `campaignGrant`, like every other movement, so the credits are
reconcilable rather than unexplained.

The grant happens lazily, at either of the two places a signed-in user touches
the wallet — the `voiceWallet` callable, so Settings shows a real balance the
moment it is opened, and `mintVoiceToken`, so somebody who never opens Settings
still gets their calls. It runs in a transaction that reads the stamp, which is
the only thing stopping two concurrent calls from both granting.

It does **not** touch `callsUsed`. That counter tracks calls spent; an unspent
grant has cost nothing, and bounding grants by the ceiling would reserve budget
against credits that may never be used. `enabled: false` does stop granting —
the emergency stop means the campaign is over, and handing out credits nobody
may spend is only a confusing balance. To stop the grant alone, set `freeGrant`
to 0.

One consequence worth planning for: a monthly allowance makes `callLimit` the
binding constraint far sooner than a one-off did. At the defaults the campaign
funds 26 account-months, so a dozen active accounts exhaust it in a couple of
months. Expect to re-calibrate the ceiling on roughly that rhythm rather than
setting it once.

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

```mermaid
sequenceDiagram
    participant App as drover app
    participant SK as StoreKit
    participant Fn as verifyPurchase
    participant ASS as App Store Server
    participant FS as Firestore

    App->>SK: buy a pack, carrying appAccountToken
    SK-->>App: signed transaction
    App->>Fn: signed transaction
    Fn->>ASS: verify signature, product and state
    ASS-->>Fn: genuine, not refunded, not revoked
    Fn->>FS: one transaction keyed on transactionId
    Note over Fn,FS: grant the credits and write the ledger row together, or neither
    FS-->>Fn: new balance
    Fn-->>App: new balance
    App->>SK: finish the transaction
    Note over App,SK: finishing last is deliberate. A crash before it replays the purchase on next launch, and the replay grants nothing
    ASS-->>Fn: Server Notification for the same transactionId, later
    Fn->>FS: same key, nothing changes
```

Two things that drawing exists to make unmissable: the StoreKit finish comes
*after* the grant, and `transactionId` is the idempotency key — which is what
makes the notification arriving later a no-op rather than a second grant.

## A refund that arrives late

Apple can refund a consumable days after it was bought and spent, and the
notification saying so may land after the user deleted their account.

```mermaid
sequenceDiagram
    participant ASS as App Store Server
    participant Fn as appleNotifications
    participant FS as Firestore
    participant App as drover app

    Note over ASS,Fn: days later, out of order, possibly more than once
    ASS->>Fn: REFUND, carrying its own notificationUUID
    Fn->>FS: negative ledger row keyed on notificationUUID
    alt the account still exists
        FS-->>Fn: balance reduced, possibly below zero
        App->>Fn: start a call
        Fn-->>App: refused while the balance is short
    else the account is gone
        FS-->>Fn: row recorded anonymised, no wallet to touch
    end
    ASS->>Fn: the same notification again
    Fn->>FS: same key, nothing changes
```

Money events are idempotent, arrive out of order, and must not require the
account to still exist.

## Identity

Drover uses anonymous auth. That is enough to authenticate against
`mintVoiceToken`, but too weak to restore a balance against. So the flow is
anonymous on first launch, Sign in with Apple before the first purchase, and
`appAccountToken` bound to the Firebase UID at purchase time. If purchasing
while anonymous is ever allowed, the app has to say plainly that the
balance may not survive a reinstall or a new device.

Offering Sign in with Apple obliges in-app account deletion, and deletion has
to revoke the Apple token. That turned out to need no key of ours: the app
hands Firebase the authorization code from a reauthentication and Firebase
revokes with Apple itself, from the Sign in with Apple key already configured
on the provider in its console. Decided 2026-09-19: a balance at deletion is
**lost, not refunded**, and the purchase screen says so before the sale rather
than at the end.

Built 2026-09-20, and two details moved. The confirm dialog first shipped
naming no count, because `firestore.rules` denies the client every read and the
device could not see its own balance to quote. Settings has to show that
balance anyway, so a `voiceWallet` callable now reads the wallet and its twenty
newest ledger rows against the auth context — the rules stay shut, and the
Function is the only way through them. The dialog names the number when there
is one to name; a balance that is zero, still loading, or failed to load keeps
the vaguer sentence, so the warning never waits on a round trip to appear. And
the wallet and ledger go with the account rather than staying anonymised — a
refund arriving for a deleted account has nowhere to land and nobody to pay,
which is the price of deleting on request. Revisit when the purchase path
exists, not before.

One thing is open rather than decided. `linkAppleAccount` falls back to signing
in when the Apple ID already belongs to an older Firebase user; that is the
reinstall recovery path, and the anonymous uid created on that launch is
dropped. Harmless today, because nothing hangs off it. Once a wallet exists,
whatever that uid accrued before the user signed in is a merge question.

## Starting a session

Session start *is* the balance check and the debit. There is no other moment at
which either happens.

```mermaid
sequenceDiagram
    participant App as drover app
    participant Fn as mintVoiceToken
    participant FS as Firestore
    participant G as Gemini Live

    App->>Fn: start a call
    Fn->>FS: read the wallet
    alt balance empty
        Fn-->>App: refused, nothing minted
    else credits available
        Fn->>FS: debit one call's worth of credits and write the ledger row, one transaction
        Fn->>G: mint a token whose expireTime outlives kVoiceSessionCap
        G-->>Fn: token
        Fn-->>App: token
        App->>G: connect directly and talk
        G-->>App: audio
        App->>G: resumption reconnect, same token
        Note over App,G: the window cannot be extended from inside. Continuing means another mint, which is another balance check and another debit
    end
```

One mint is one call is one debit. Nothing the client does inside the session
extends it — `kVoiceSessionCap` ends it first, and the token's `expireTime`
ends it regardless — which is why the unit sold is a call rather than a minute.
How many credits a call costs is the server-side conversion above.

On the app's side that moment gets a tap of its own. The herd screen's voice
button opens the voice screen and does nothing else; a new call begins when
Start is tapped there. Navigation is not a charge, so a mis-tap on the way in
costs nothing — which matters because there is no undo: a debit is only ever
given back when the mint that caused it fails. Arriving at a call that is
still going, or at one parked by a backgrounding that kept its resumption
handle, continues it with no tap: the session id is the one already paid for,
so the re-mint lands inside the reuse window and costs nothing.

A park that caught the call without a handle — the first seconds of a call,
and every mid-call reconnect, since a reconnect consumes the handle it had —
continues for free too, wherever it is picked up from. The session id survives
any park, so the re-mint lands inside the reuse window; what the handle decides
is only whether the Live conversation resumes or the user has to tap Restart.
So `_openVoice` keeps a retained session while it is `resumable` *or* `parked`
— the same call, still inside its cap — and a handle-less park costs one credit
however the user navigates. Past the cap there is nothing left to continue and
the next call pays.

## Voice Gateway

Needed only if credits are denominated in consumption rather than in calls
granted; the token design above covers the latter without any of this. Where it
is needed, a paid session runs through Cloud Run rather than straight to Gemini:

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

The wallet and the ledger are needed either way. The reservation fields and
the whole `voiceSessions` collection below belong to the relay: they exist to
settle a session against what it actually consumed, which is the thing a
minted token cannot tell you. Under the token design a session records the
window it was granted instead, and there is nothing to settle.

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
Write a negative ledger event; the balance is allowed to go negative, and new
sessions are refused until it is positive again.

## What a long-lived credential cannot enforce

The shortcut — check the balance in Functions, let the client connect to AI
Logic on its own long-lived credential, report usage afterwards — reads like
it works and does not. A modified client skips the check, an old build ignores
whatever limit was added later, the server never sees the audio it is billing
for, and nothing can hang up on a session whose credits ran out. It is fine for
a free beta and unusable as a paywall.

Every one of those failures comes from the same place: the client holds a
credential that outlives the check. An ephemeral token removes exactly that, and
the section below is the measurement. A modified client cannot skip a check it
has to pass to obtain a credential at all; an old build cannot ignore a limit
that is enforced server-side at mint time; and a session does get hung up on,
because the token's expiry ends it in flight — though that hangs up at the end
of a granted window rather than at the moment credits run out, which is a
weaker promise than the relay's. What survives untouched is the third item: the
server still never sees the audio, so it still cannot bill for what was
consumed, only for what was granted.

Underneath that sits a separate limit, about the SDK rather than the design. As
of `firebase_ai` 4.0.0, checked 2026-09-17, the SDK never surfaces
`usageMetadata` on the Live path: `api.dart` parses it for `generateContent`,
but `LiveServerResponse` carries nothing but a `LiveServerMessage`, no variant
of that sealed type holds usage, and the string does not appear in
`live_api.dart`, `live_session.dart` or `live_model.dart` at all. Only a raw
Live WebSocket sees the field. That fact stands, but it does not make the relay
the only possible meter: under the token design the app itself holds the raw
socket, and `usageMetadata` arrives on it normally — confirmed over a token
connection on 2026-09-18. What the relay uniquely offers is a meter the *user's
device does not control*, which is a different property from seeing the number.
Re-check the SDK side against a newer `firebase_ai` before relying on it.

## Gating a direct connection with an ephemeral token

Measured 2026-09-18 against `models/gemini-3.1-flash-live-preview`, minting on
`v1alpha` and connecting on `v1beta`, with `app/tool/token_probe.dart`. A
Function can check the wallet and mint a short-lived Live API token; the app
connects to Google with it and no relay sits in the audio path.

**`uses` counts session starts, not messages, and a resumption reconnect does
not consume one.** This is the trap that would quietly make a wallet check
useless. Three turns ran fine on a `uses: 1` token; a second connect without a
resumption handle was refused with `1011 "Token has been used too many times"`.
But the same spent token kept accepting reconnects that carried a resumption
handle, one after another, with the context growing each time. Do not treat
`uses` as a budget — it bounds only the first unhandled connect.

**`expireTime` is the real boundary.** It ends a session already in flight: a
session taking a turn every twenty seconds across its token's expiry was closed
by the server within a second of the stated time, with `1011 "auth token has
expired"`, and nothing after that was answered. It also refuses resumption
afterwards — reconnecting on a valid handle with the expired token gave `1011
"Token has expired"`. A freshly minted token resumed the same handle
immediately, and the conversation's context was still there. The mint will not
issue a token living longer than 20 hours (`expire_time is too far in the
future. Maximum lifetime is 20h`).

**So a mint is a genuine meter tick.** Each one grants exactly the window it was
minted for, the client cannot extend that window from inside it, and
continuing past it means coming back through the Function — which is another
balance check. The unit this can sell is a granted window — one call — not
tokens consumed.

**Session resumption survives all of it**, including being handed to a token
that did not create the handle. The app's existing reconnect
(`VoiceSession`) is compatible with a paid path; this was the risk that would
have killed the design outright, and it did not materialise.

What it does not give you is a closed loop. One granted window is a blank cheque
at whatever rate the client drives it, and there is no usage API on the token
resource at all — list and get, on both API versions, all return 404 with an
empty body. Reconciliation can therefore only come from the Cloud Billing
export, after the fact.

Two things the official documentation gets wrong, both of which cost an hour to
find and neither of which is written down anywhere else:

- An ephemeral token is **not** accepted on the `BidiGenerateContent` RPC that
  an API key uses. It goes to **`BidiGenerateContentConstrained`**, with the
  token's resource name in an `?access_token=` query parameter. Every form the
  docs suggest — `access_token` on the plain RPC, an `Authorization: Token`
  header, the token as an API key — is rejected, on both API versions.
- The mint field the docs call `liveConnectConstraints` does not exist over
  REST; sending it is a 400. The real field is **`bidiGenerateContentSetup`**
  plus a **`fieldMask`** naming which of its fields are frozen. That lock is
  enforced: on a token whose `model` is masked, a setup asking for a model that
  does not exist still connects, while the same request on an unconstrained
  token is refused with `1008 "models/... is not found"`. The client's value is
  ignored rather than honoured, which is what makes it a real constraint.

  Re-measured 2026-09-21, this time with a *real* alternate model as well as
  the nonexistent one: a masked token minted for one model answered a client
  naming another shipping Live model just as it answered `models/not-a-model`:
  both connected and were answered, while the unconstrained control refused
  the made-up name as before. So on the minted-token path the Function's
  constant alone decides which model bills, and the app's `kVoiceModel`
  decides nothing. The consequence worth keeping: a model can be switched
  server side, with no App Store release, which is the escape hatch when one
  is deprecated, and shipped builds keep working across the switch. The app
  sends `kVoiceModel` in the setup frame anyway — a *wrong* value is what was
  measured as accepted, an absent one was not — but the two no longer have to
  match.

Re-check all of this before relying on it; ephemeral tokens are a preview
feature of a preview API, and the documentation is already out of step with the
behaviour.

## Before setting a price

Measure first: input audio tokens, output audio tokens, input and output text
tokens, session length, usage after context compression, Cloud Run's
concurrency and egress, and the gap between reported usage and what Cloud
Billing settles at. None of it is visible through `firebase_ai`, for the reason
above — it takes either a raw Live WebSocket, which both the relay and the
token design end up holding, or cost deltas read out of the billing export. See
[billing-cli-setup.md](billing-cli-setup.md) for the latter.

Two probes do this already, neither of them throwaway work:
`app/tool/live_probe.dart` opens the raw Live WebSocket, bypassing
`firebase_ai`, and dumps every `usageMetadata` verbatim;
`app/tool/token_probe.dart` does the same over an ephemeral token and is where
the section above was measured.

What `live_probe.dart` measured against `gemini-3.1-flash-live-preview` on
2026-09-18, over five text-input turns with audio responses: **accumulated
context is re-billed at the modality it arrived in.** Each turn's
`promptTokensDetails` carried an AUDIO count equal to the running sum of every
prior response's audio tokens — 25, then 48, then 71, then 96 — while its
TEXT count grew separately. Audio history stays audio; it is not folded into
text. That was the open question, and it resolved to the expensive branch.

A separate single audio-input turn reported a prompt of TEXT 132 + AUDIO 72
for 2.95 s of speech — about **25 tokens per second of input audio** — and a
response of AUDIO 263 whose duration was not captured, so the output rate is
assumed symmetric until it is. The user's own speech therefore enters the
prompt as audio, and by the rule above is re-billed as audio for the rest of
the session.

The consequence that matters for pricing: a session's cost is **quadratic in
turn count**, at the audio rate, because every turn re-pays for all the audio
before it. This is why a credit cannot be denominated in minutes — the same
minute costs more the later in a conversation it falls. The session cap
(`kVoiceSessionCap`) is what bounds the quadratic.

Context-window compression is the second bound on it, and `live_probe.dart`
measured on 2026-09-21 how it actually behaves. It works, but it had been
shipping inert: `ContextWindowCompressionConfig` was sent with neither
`triggerTokens` nor `targetTokens`, and with both unset nothing ever fires, so
the prompt grew every turn for the whole session. Set them and the per-turn
prompt stops climbing and saw-tooths instead — up to the trigger, down to the
target, up again.

The trap is the floor. With `targetTokens` set far *below* the per-turn floor,
the prompt never drops below that floor: the system instruction and the tool
declarations cannot be compressed away, so the model simply discards the
conversation in full rather than trimming it to fit. Retained conversation is
therefore roughly **`targetTokens` minus the per-turn floor**, and a target at
or under the floor retains nothing. drover's floor is about 1,800 tokens —
system prompt, tool declarations and transcripts, derived from the billed text
tokens per turn — so the shipped `triggerTokens: 5000` with
`SlidingWindow(targetTokens: 3000)` keeps around 1,200 tokens of conversation
across a compression, which is the last two or three turns. That margin is what
`draft_message` → confirm → `send_message` needs to survive a clip, and it
shrinks every time the system prompt or the tool declarations grow.

Not yet measured: a multi-turn run with real audio *input*. Those runs are
closed by the server with `1008 The operation was aborted.` while text turns
succeed at the same moment, so it is not quota; the cause is unknown after
three attempts, most likely the VAD/activity signalling. It does not affect
the re-billing conclusion, but no end-to-end figure for a real session exists
yet.

The check against Cloud Billing that this note asks for has since been done,
on 2026-09-21: the export's tables were only lagging, not stopped, and the
September rows are all there. Dividing charge by tokens reproduces every list
price above at a consistent 159.4 JPY/USD, so the rates are confirmed against
an invoice rather than a documentation page. What the invoice settles is the
per-call figure the modelling could not: eight real conversations under the
five-minute cap cost between 1.09 and 11.54 JPY, averaging 5.9. The modelled
ceiling for a dense call, scaled from the one twelve-minute session that ran
under the old ten-minute cap, is about 25 JPY.

Re-check all of this against `gemini-3.8-live` before relying on it. The
re-billing and audio-rate figures above were measured on the legacy preview
model, and while the two sit in the same pricing row, the same rates are an
assumption until they are measured again — the migration does not carry the
measurements over with it.

The price then has to cover the Gemini cost plus Apple's cut, Firebase and
Cloud Run, headroom for refunds and abuse, and headroom for model price and
exchange-rate moves.

This no longer waits on a stable Live model. Voice moved to `gemini-3.8-live`
on 2026-09-21 — Google publishes it as stable and lists the model drover used
before it as the legacy preview one to migrate off — and both sit in the same
pricing row ($3.00/1M input audio, $12.00/1M output audio, $0.75/1M input
text), so the move cost nothing. Whether voice stays on an invite-only
TestFlight beta is now a question about the measurements and the price, not
about the model's maturity.

## Order of work

Free beta first: measure the real cost, turn on AI monitoring and the billing
export, and verify the production App Check configuration. Explicit consent for
sending audio to an AI service and a session cap both shipped in #254. Then the
billing control plane — `in_app_purchase`, consumable products, transaction
verification, `appAccountToken` binding, the wallet and ledger, Server
Notifications V2, refund and revoke handling. Then the gate: a Function that
checks the balance and mints an ephemeral token per call, which is a small
piece of work and enough to sell calls.

The Cloud Run relay is no longer on that path. It is what you build if credits
have to be denominated in consumption — the relay itself, auth and App Check
checks, reserve/settle/return, stored `usageMetadata`, disconnect on empty
balance, crash recovery, and a daily reconciliation against Cloud Billing. That
is a large, always-on service in the audio path, so decide what is being sold
before committing to it. Whatever ships is validated in the StoreKit sandbox and
on TestFlight.

## References

- [App Store Review Guidelines 3.1.1](https://developer.apple.com/app-store/review/guidelines/)
- [App Store Server API](https://developer.apple.com/documentation/appstoreserverapi)
- [App Store Server Notifications](https://developer.apple.com/documentation/appstoreservernotifications)
- [Cloud Run WebSockets](https://cloud.google.com/run/docs/triggering/websockets)
- [Live API ephemeral tokens](https://ai.google.dev/gemini-api/docs/live-api/ephemeral-tokens)
  — wrong about how a token is presented; see the section above.
