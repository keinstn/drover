# Reading voice usage and cost from the CLI

What the voice assistant costs, and how to see it without opening a console.
The assistant itself is described in [voice-live.md](voice-live.md). Facts
below were recorded on 2026-09-17 unless noted otherwise.

Three different numbers live in three different places, and only two of them
are reachable from a shell:

- **Prepaid balance** — Google AI Studio only. There is no CLI for it.
- **Requests and tokens** — Cloud Monitoring.
- **Settled cost** — Cloud Billing, once it has been exported to BigQuery.

Identifiers are kept out of this repo, for the same reason `.firebaserc` and
`GoogleService-Info.plist` are gitignored. Substitute your own; the values are
readable from `gcloud billing projects describe <PROJECT_ID>` and friends.

Before anything else, confirm in AI Studio that the Gemini API project behind
Firebase AI Logic is on **paid services**. This is not only about quota: on
the unpaid tier Google may train on both the input and the output, which for a
voice assistant means the user's speech.

## Billing export to BigQuery

```sh
bq --location=US mk -d --description "Cloud Billing export" <PROJECT_ID>:billing_export
```

The export itself is switched on in the billing console, not from a CLI. Point
**Standard usage cost**, **Detailed usage cost** and **Pricing** at that one
dataset. Google creates the tables; the first rows usually appear the next day.

- Without **Pricing** there is no way to check a unit price against a charge.
- **Detailed** adds almost nothing over Standard for the Gemini API, but export
  data is never backfilled — enabling it later would leave a hole covering
  everything up to that day, so it goes on up front as insurance.
- **FOCUS usage cost** is a repackaging of Standard and Detailed, and
  **Committed use discounts** stays empty without a CUD. Both are skipped.
- Leave the service account field on the Pricing export empty. Google adds
  `cloud-account-pricing@cloud-account-pricing.iam.gserviceaccount.com` as an
  owner of the dataset and writes as that.

The export lives in the Firebase project rather than a dedicated one. A
separate project is the usual advice, for two reasons: the export carries every
project under the billing account, so read access to one product's project
would otherwise mean read access to the entire invoice, and the
dataset's location is then free to differ. Neither applies to a personal
billing account with effectively one product on it. The destination can be
changed later, at the price of copying the existing tables — again, no backfill.

Cost by service for the last 30 days:

```sh
bq query --use_legacy_sql=false '
SELECT
  service.description,
  SUM(cost) AS cost
FROM
  `<PROJECT_ID>.billing_export.gcp_billing_export_v1_<BILLING_ACCOUNT_ID>`
WHERE
  usage_start_time >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 30 DAY)
GROUP BY service.description
ORDER BY cost DESC
'
```

The table name spells the billing account ID with underscores, not the hyphens
the ID itself is written with — pasting it verbatim will not resolve.

## Budget alert

```sh
gcloud services enable billingbudgets.googleapis.com --project=<PROJECT_ID>
gcloud billing budgets create \
  --billing-account=<BILLING_ACCOUNT_ID> \
  --display-name="drover monthly" \
  --budget-amount=3000JPY \
  --filter-projects=projects/<PROJECT_ID> \
  --threshold-rule=percent=0.5 \
  --threshold-rule=percent=0.9 \
  --threshold-rule=percent=1.0 \
  --threshold-rule=percent=1.0,basis=forecasted-spend
```

The currency has to match the billing account's — JPY here.

**A budget notifies; it does not stop anything.** Google publishes a recipe
that wires the budget's Pub/Sub topic to a function that disables billing on
the project, and drover deliberately does not use it: Firestore, Functions and
push for the shipped 1.0.x app sit in this same project, so a runaway voice
bill would take the released app down with it.

## Quota cap

There is very little to turn. The live preview model has **no quota bucket of
its own** — `gcloud alpha services quota list` shows nothing for
`gemini-3.1-flash-live-preview`. The only lever that reaches Live sessions is
the project-wide `bidi_generate_content_paid_tier_3_sessions` metric, in units
of `1/10min/{project}`, and its default is `-1`, meaning unlimited.

```sh
gcloud components install alpha   # the quota API is alpha-only
gcloud alpha services quota update \
  --service=generativelanguage.googleapis.com \
  --consumer=projects/<PROJECT_ID> \
  --metric=generativelanguage.googleapis.com/bidi_generate_content_paid_tier_3_sessions \
  --unit='1/10min/{project}' --value=20 --force
```

`--force` is required because dropping from unlimited counts as a reduction of
more than 10% and trips `COMMON_QUOTA_UNSAFE_OVERRIDE`. 20 is a judgement
call: high enough not to interrupt development, low enough that a modified
client cannot open hundreds of sessions.

Only the tier 3 metric is exposed. If the project is billed under a different
tier the override may not bind at all, so read the effective value back after
setting it:

```sh
gcloud alpha services quota list \
  --service=generativelanguage.googleapis.com \
  --consumer=projects/<PROJECT_ID> --format=json
```

And note what this does not do: it bounds the rate at which sessions start, not
the money. A per-user ceiling is the app's job — see
[voice-billing.md](voice-billing.md) for how that is meant to work.
