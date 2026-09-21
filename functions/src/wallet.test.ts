import assert from "node:assert/strict";
import test from "node:test";

import {
  debitedMint,
  type VoiceCampaign,
  voiceCallCost,
  voiceCampaign,
  voiceCampaignCallLimit,
  voiceCampaignFreeGrant,
  voiceCampaignGrant,
  voiceLedgerEntry,
  voiceMintDecision,
  voiceSessionReuseMs,
  walletCredits,
} from "./wallet.js";

const now = 1_700_000_000_000;

// A campaign with room left, so the tests that are about the balance stay
// about the balance.
const openCampaign = voiceCampaign(null);

function decide(
  credits: unknown,
  session: { uid: unknown; startedAtMs: unknown } | null = null,
  campaign: VoiceCampaign = openCampaign,
) {
  return voiceMintDecision({
    uid: "user-1",
    credits,
    session,
    campaign,
    nowMs: now,
  });
}

function campaignAt(fields: Partial<Record<string, unknown>>): VoiceCampaign {
  return voiceCampaign({
    callsUsed: fields.callsUsed,
    callLimit: fields.callLimit,
    enabled: fields.enabled,
    freeGrant: fields.freeGrant,
  });
}

void test("charges the first mint of a session and no later one", () => {
  assert.equal(decide(2), "debit");
  assert.equal(
    decide(2, { uid: "user-1", startedAtMs: now - 1000 }),
    "reuse",
    "a re-mint for the same conversation must not be charged again",
  );
});

void test("charges again once the session is older than the reuse window", () => {
  assert.equal(
    decide(2, { uid: "user-1", startedAtMs: now - voiceSessionReuseMs }),
    "debit",
  );
});

void test("refuses a mint the balance does not cover", () => {
  assert.equal(decide(0), "empty");
  assert.equal(decide(undefined), "empty");
  assert.equal(decide(voiceCallCost), "debit");
});

void test("refuses somebody else's session ID", () => {
  assert.equal(
    decide(2, { uid: "user-2", startedAtMs: now - 1000 }),
    "foreign",
  );
});

void test("reads only a sane balance out of the wallet", () => {
  assert.equal(walletCredits(3), 3);
  assert.equal(walletCredits(2.7), 2);
  assert.equal(walletCredits(-5), 0);
  assert.equal(walletCredits("10"), 0);
  assert.equal(walletCredits(Number.POSITIVE_INFINITY), 0);
  assert.equal(walletCredits(undefined), 0);
});

void test("hands the credit back when the mint fails after a debit", async () => {
  const calls: string[] = [];
  await assert.rejects(
    debitedMint(
      async () => {
        calls.push("debit");
        return true;
      },
      async () => {
        calls.push("mint");
        throw new Error("mint failed");
      },
      async () => {
        calls.push("refund");
      },
    ),
    /mint failed/,
  );
  assert.deepEqual(calls, ["debit", "mint", "refund"]);
});

void test("refunds nothing when the mint was free or succeeded", async () => {
  const calls: string[] = [];
  const refund = async () => {
    calls.push("refund");
  };
  await assert.rejects(
    debitedMint(
      async () => false,
      async () => {
        throw new Error("mint failed");
      },
      refund,
    ),
    /mint failed/,
  );
  assert.equal(
    await debitedMint(
      async () => true,
      async () => "token",
      refund,
    ),
    "token",
  );
  assert.deepEqual(calls, []);
});

void test("hands the app a ledger row it can render", () => {
  assert.deepEqual(
    voiceLedgerEntry({ type: "voiceCall", credits: -1, createdAtMs: now }),
    { type: "voiceCall", credits: -1, at: now },
  );
  assert.deepEqual(
    voiceLedgerEntry({
      type: "voiceCallRefund",
      credits: 1,
      createdAtMs: now,
    }),
    { type: "voiceCallRefund", credits: 1, at: now },
  );
});

void test("drops a ledger row the app could not label or count", () => {
  assert.equal(
    voiceLedgerEntry({ type: "", credits: -1, createdAtMs: now }),
    null,
  );
  assert.equal(
    voiceLedgerEntry({ type: undefined, credits: -1, createdAtMs: now }),
    null,
  );
  assert.equal(
    voiceLedgerEntry({ type: "voiceCall", credits: "-1", createdAtMs: now }),
    null,
  );
  assert.equal(
    voiceLedgerEntry({
      type: "voiceCall",
      credits: Number.POSITIVE_INFINITY,
      createdAtMs: now,
    }),
    null,
  );
});

void test("keeps a row whose timestamp is not one", () => {
  assert.deepEqual(
    voiceLedgerEntry({ type: "voiceCall", credits: -1, createdAtMs: null }),
    { type: "voiceCall", credits: -1, at: null },
  );
});

void test("falls back to the defaults when the campaign document is missing", () => {
  assert.deepEqual(voiceCampaign(null), {
    callsUsed: 0,
    callLimit: voiceCampaignCallLimit,
    enabled: true,
    freeGrant: voiceCampaignFreeGrant,
  });
});

void test("falls back per field when the campaign document is garbage", () => {
  assert.deepEqual(
    campaignAt({
      callsUsed: "12",
      callLimit: -1,
      enabled: "yes",
      freeGrant: Number.NaN,
    }),
    {
      callsUsed: 0,
      callLimit: voiceCampaignCallLimit,
      enabled: true,
      freeGrant: voiceCampaignFreeGrant,
    },
    "a hand-edited field that makes no sense must not disable the ceiling",
  );
  // A sane hand edit is believed, and a fractional count is floored the way a
  // balance is.
  assert.equal(campaignAt({ callLimit: 40 }).callLimit, 40);
  assert.equal(campaignAt({ callsUsed: 7.9 }).callsUsed, 7);
  assert.equal(campaignAt({ freeGrant: 0 }).freeGrant, 0);
});

void test("allows the last call under the ceiling and refuses the next", () => {
  const limit = voiceCampaignCallLimit;
  assert.equal(
    decide(9, null, campaignAt({ callsUsed: limit - voiceCallCost })),
    "debit",
    "the call that spends the campaign's last credit must go through",
  );
  assert.equal(
    decide(9, null, campaignAt({ callsUsed: limit })),
    "campaignOver",
  );
});

void test("refuses a new call once the campaign is stopped by hand", () => {
  assert.equal(decide(9, null, campaignAt({ enabled: false })), "campaignOver");
});

void test("prefers the campaign refusal over the empty balance", () => {
  // Both are `resource-exhausted`, and the app tells them apart by `reason`.
  // "No credits left" would be the wrong thing to say when the campaign is
  // what ended.
  assert.equal(decide(0, null, campaignAt({ enabled: false })), "campaignOver");
});

void test("lets a paid-for call finish after the campaign closes", () => {
  const closed = campaignAt({ callsUsed: voiceCampaignCallLimit });
  assert.equal(
    decide(0, { uid: "user-1", startedAtMs: now - 1000 }, closed),
    "reuse",
    "a re-mint inside a live call must not be refused by the ceiling",
  );
  assert.equal(
    decide(
      0,
      { uid: "user-1", startedAtMs: now - 1000 },
      campaignAt({ enabled: false }),
    ),
    "reuse",
    "not even the emergency stop may cut off a conversation already charged for",
  );
  // And `reuse` is what `claimVoiceCall` reports as "took no credit", so
  // nothing increments the campaign counter either.
});

void test("grants the free credits once, and never to an anonymous account", () => {
  const grant = (signInProvider: unknown, grantedAt: unknown = null) =>
    voiceCampaignGrant({ signInProvider, grantedAt, campaign: openCampaign });

  assert.equal(grant("apple.com"), voiceCampaignFreeGrant);
  assert.equal(
    grant("apple.com", new Date()),
    0,
    "the mark on the wallet is what makes the grant happen only once",
  );
  assert.equal(
    grant("anonymous"),
    0,
    "an anonymous install comes back under a fresh uid, so granting is a faucet",
  );
  assert.equal(grant(undefined), 0);
  assert.equal(grant(42), 0);
});

void test("stops granting when the campaign is stopped, but not at the ceiling", () => {
  const grant = (campaign: VoiceCampaign) =>
    voiceCampaignGrant({
      signInProvider: "apple.com",
      grantedAt: null,
      campaign,
    });

  assert.equal(
    grant(campaignAt({ callsUsed: voiceCampaignCallLimit })),
    voiceCampaignFreeGrant,
    "an unspent credit costs nothing, so the call ceiling must not bound grants",
  );
  assert.equal(grant(campaignAt({ enabled: false })), 0);
  assert.equal(grant(campaignAt({ freeGrant: 0 })), 0);
});
