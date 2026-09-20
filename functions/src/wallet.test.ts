import assert from "node:assert/strict";
import test from "node:test";

import {
  debitedMint,
  voiceCallCost,
  voiceLedgerEntry,
  voiceMintDecision,
  voiceSessionReuseMs,
  walletCredits,
} from "./wallet.js";

const now = 1_700_000_000_000;

function decide(
  credits: unknown,
  session: { uid: unknown; startedAtMs: unknown } | null = null,
) {
  return voiceMintDecision({ uid: "user-1", credits, session, nowMs: now });
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
