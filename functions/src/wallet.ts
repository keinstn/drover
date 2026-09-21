// The wallet's arithmetic and its one idempotency decision, kept apart from
// Firestore so they can be tested with `node --test` and no emulator.

// What one voice call costs. A constant here, not a product ID and not a
// number in the app: Apple's product IDs are immutable, so what a credit
// buys has to be able to change without an App Store release.
export const voiceCallCost = 1;

// How long one session ID keeps minting without being charged again.
//
// A conversation re-mints — before the token expires, and after a genuine
// drop — and all of those carry the session ID the app made when the call
// started. Every mint inside this window is the same call.
//
// A little longer than `kVoiceSessionCap` (5 minutes, in
// app/lib/src/voice/voice_session.dart), which ends the conversation: long
// enough to cover one call including its reconnects, short enough that a
// session ID cannot be talked on indefinitely for one credit.
//
// ponytail: the window bounds duration, not concurrency — a modified client
// could mint many tokens inside it and run them at once, and cost grows with
// speech seconds times turns. The shipped app opens one socket at a time.
// Count the mints on the session document if that ever stops being true.
export const voiceSessionReuseMs = 6 * 60 * 1000;

// The free campaign: a few credits per account, and a ceiling on the whole
// thing so the bill cannot run away.
//
// The numbers here are only the fallback. The live ones are in
// `config/voiceCampaign`, edited by hand in the Firebase console the same way
// credits are — a budget that needs a deploy to move is a budget that moves
// too late.

// The ceiling, counted in calls. A ~¥2,000 budget at a conservative ¥15 a
// call; measured cost is about ¥6 on average and ¥25 at the worst modelled
// case. A call count is a stand-in for money, not a measure of it: the billing
// export lags about a day, so spend cannot be metered live.
export const voiceCampaignCallLimit = 130;

// What one account is topped up to at the start of each month.
export const voiceCampaignFreeGrant = 5;

export interface VoiceCampaign {
  callsUsed: number;
  callLimit: number;
  enabled: boolean;
  freeGrant: number;
}

// A campaign number as stored: a whole count, never negative. Anything else
// falls back to the default — the same refusal to believe a hand-edited
// document that `walletCredits` makes about a balance. Zero is a real value
// here, though: an untouched counter, not junk.
function campaignCount(value: unknown, fallback: number): number {
  return typeof value === "number" && Number.isFinite(value) && value >= 0
    ? Math.floor(value)
    : fallback;
}

// Reads `config/voiceCampaign`, field by field, each one falling back on its
// own. A missing document is a running campaign on the defaults: nobody should
// have to create a document by hand before the first call works.
export function voiceCampaign(
  fields: {
    callsUsed: unknown;
    callLimit: unknown;
    enabled: unknown;
    freeGrant: unknown;
  } | null,
): VoiceCampaign {
  return {
    callsUsed: campaignCount(fields?.callsUsed, 0),
    callLimit: campaignCount(fields?.callLimit, voiceCampaignCallLimit),
    enabled: typeof fields?.enabled === "boolean" ? fields.enabled : true,
    freeGrant: campaignCount(fields?.freeGrant, voiceCampaignFreeGrant),
  };
}

// Whether the campaign can still pay for one more call.
export function voiceCampaignOpen(campaign: VoiceCampaign): boolean {
  return (
    campaign.enabled && campaign.callsUsed + voiceCallCost <= campaign.callLimit
  );
}

// The UTC year-month a moment falls in, "2026-09". Stamped on the wallet as
// `campaignGrantPeriod`, it is what says which month's grant an account has
// already had.
//
// UTC, not the account's own month: the Function has no idea where the account
// is, and one instant the world over is easier to reason about than a boundary
// that depends on a guess. In Japan the refill lands at 09:00 on the 1st.
export function voiceCampaignPeriod(nowMs: number): string {
  return new Date(nowMs).toISOString().slice(0, 7);
}

// What to top this account up by for the current month — `null` when nothing
// should be written at all, otherwise the credits to add, which may be 0.
//
// Monthly rather than once for the account's whole life. A one-time grant only
// ever answers "did they use it up"; a monthly one shows the sustained rate,
// which is the number a price has to be set against, and it bounds an account
// to `freeGrant` calls a month rather than `freeGrant` ever.
//
// A *top-up*, not an addition: the figure is `freeGrant` less what is already
// there, so somebody holding 3 gets 2 and somebody holding 5 gets nothing.
// That is what keeps a month's allowance at `freeGrant` however long the
// account has been away — credits do not pile up across months — and it can
// never reduce a balance, which will matter the day purchased credits share
// this field.
//
// 0 is not the same answer as `null`. A balance that already covers the month
// has had its allowance, so the period is stamped and nothing else happens;
// the caller writes no ledger row, because "granted 0 credits" is a blank line
// in the activity list. `null` means this account is not owed a grant at all.
//
// Never to an anonymous one: an anonymous install that is deleted and
// reinstalled comes back under a fresh uid, so granting to it would be a
// faucet rather than a campaign, and signing in with Apple is what makes an
// account outlive a reinstall. An anonymous caller gets nothing and no error
// — a zero balance, and the ordinary refusal when it tries to call.
//
// The caller stamps the period in the same commit as the credits, which is
// what keeps two concurrent calls from both granting.
//
// The ceiling does not bound any of this: an unspent credit costs nothing, and
// `callsUsed` counts calls made, not credits handed out. `enabled: false`
// does, because the emergency stop means the campaign is over and credits
// nobody may spend are only a confusing balance.
export function voiceCampaignGrant(input: {
  signInProvider: unknown;
  grantedPeriod: unknown;
  credits: unknown;
  campaign: VoiceCampaign;
  nowMs: number;
}): number | null {
  if (!voiceGrantEligible(input.signInProvider)) return null;
  if (!input.campaign.enabled) return null;
  // An allowance of nothing is the way to switch the grant off on its own,
  // so it writes nothing at all — not even a stamp, which would otherwise be
  // one pointless wallet write per account per month forever.
  if (input.campaign.freeGrant <= 0) return null;
  // Absent, stale, or hand-edited into something that is not this month: all
  // of them mean the month's grant has not been handed out yet.
  if (input.grantedPeriod === voiceCampaignPeriod(input.nowMs)) return null;
  return Math.max(0, input.campaign.freeGrant - walletCredits(input.credits));
}

// Whether this sign-in could ever be granted to, from
// `firebase.sign_in_provider` off the verified ID token: "anonymous" until the
// account is linked to Apple, "apple.com" after.
//
// Split out of the decision above so the caller can answer it without reading
// anything. Most callers are anonymous — the app signs in that way at launch —
// and every re-mint of every live call asks again, so opening a transaction on
// the wallet and the campaign counter to find out would put pointless traffic
// on the one document whose write rate is the campaign's ceiling.
//
// A token minted before the link still says "anonymous", so a just-linked
// account can miss its grant by one call. That is why the grant is re-checked
// lazily on every wallet touch instead of run once at sign-up — the next call
// after the token rolls picks it up.
export function voiceGrantEligible(signInProvider: unknown): boolean {
  return typeof signInProvider === "string" && signInProvider !== "anonymous";
}

// What a mint should do about the balance:
// - `reuse`: this call was already paid for, mint again for free
// - `debit`: a new call, and the balance covers it
// - `empty`: a new call the balance does not cover
// - `foreign`: the session ID belongs to somebody else
// - `campaignOver`: the free campaign is spent, or stopped by hand
export type VoiceMintDecision =
  | "reuse"
  | "debit"
  | "empty"
  | "foreign"
  | "campaignOver";

// The stored balance. A missing, negative or malformed value is no credit at
// all — the wallet is written by this Function alone, so anything else is
// somebody having edited the document by hand.
//
// Credits are whole: a hand-typed fractional balance loses its fraction at the
// first debit, which writes this value back rounded down.
export function walletCredits(value: unknown): number {
  return typeof value === "number" && Number.isFinite(value) && value > 0
    ? Math.floor(value)
    : 0;
}

export function voiceMintDecision(input: {
  uid: string;
  credits: unknown;
  session: { uid: unknown; startedAtMs: unknown } | null;
  campaign: VoiceCampaign;
  nowMs: number;
}): VoiceMintDecision {
  const { session } = input;
  if (session != null) {
    if (session.uid !== input.uid) return "foreign";
    if (
      typeof session.startedAtMs === "number" &&
      input.nowMs - session.startedAtMs < voiceSessionReuseMs
    ) {
      return "reuse";
    }
  }
  // Below the reuse branch, deliberately, and this is the ordering the whole
  // campaign turns on: a conversation already paid for re-mints to carry on,
  // and if the ceiling could refuse those the campaign's last call would be
  // cut off mid-sentence. A call that has been charged for always finishes.
  //
  // Above the balance check, also deliberately: when the campaign is what
  // ended, "no credits left" is the wrong thing to tell somebody who has some.
  if (!voiceCampaignOpen(input.campaign)) return "campaignOver";
  return walletCredits(input.credits) >= voiceCallCost ? "debit" : "empty";
}

// Debits before minting, and hands the credit back when the mint then fails.
//
// The other order leaks a free call on any crash between a successful mint
// and its debit, which is the expensive way round to be wrong.
//
// ponytail: if the process dies between the debit and the compensation the
// credit is lost. A recovery job for one credit is more machinery than the
// loss; give the ledger a sweeper only once refunds exist anyway.
export async function debitedMint<T>(
  debit: () => Promise<boolean>,
  mint: () => Promise<T>,
  refund: () => Promise<void>,
): Promise<T> {
  const debited = await debit();
  try {
    return await mint();
  } catch (error) {
    if (debited) await refund();
    throw error;
  }
}

// One ledger row as the app is allowed to see it. `sessionId` stays behind:
// it correlates a row with one conversation, and the app has no use for it.
//
// A row that cannot be labelled or counted is dropped rather than returned —
// the app renders these, and a malformed one would be a blank line it has no
// words for. The ledger is written by this backend alone, so such a row means
// somebody edited a document by hand.
export function voiceLedgerEntry(row: {
  type: unknown;
  credits: unknown;
  createdAtMs: unknown;
}): { type: string; credits: number; at: number | null } | null {
  if (typeof row.type !== "string" || row.type.length === 0) return null;
  if (typeof row.credits !== "number" || !Number.isFinite(row.credits)) {
    return null;
  }
  return {
    type: row.type,
    credits: row.credits,
    // A row read back always has its timestamp — the server resolves it on
    // commit, and the query orders by it. Null is what a hand-edited row
    // whose `createdAt` is not a timestamp at all comes back as, and it
    // costs the row its date rather than its place in the list.
    at: typeof row.createdAtMs === "number" ? row.createdAtMs : null,
  };
}
