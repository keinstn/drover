// The wallet's arithmetic and its one idempotency decision, kept apart from
// Firestore so they can be tested with `node --test` and no emulator.

// What one voice call costs. A constant here, not a product ID and not a
// number in the app: Apple's product IDs are immutable, so what a credit
// buys has to be able to change without an App Store release.
export const voiceCallCost = 1;

// How long one session ID keeps minting without being charged again.
//
// A conversation re-mints after a genuine drop, and all of those requests
// carry the session ID the app made when the call started. Every mint inside
// this window is the same call.
//
// A little longer than `kVoiceSessionCap` (5 minutes, in
// app/lib/src/voice/voice_session.dart), which ends the conversation: long
// enough to cover one call including its reconnects, short enough that a
// session ID cannot be talked on indefinitely for one credit.
export const voiceSessionReuseMs = 6 * 60 * 1000;

// One initial token plus enough retries for ordinary connection drops and
// background/foreground resumes. The count is stored on the session document
// and advanced in the same transaction that admits a mint, so a modified
// client cannot turn one paid session ID into an unlimited token faucet.
export const voiceSessionInitialMintCount = 1;
export const voiceSessionMintLimit = 5;

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

// What one new account is handed, once.
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

// How many credits to hand this account as its campaign grant — 0 for none.
//
// Once per account, and never to an anonymous one. An anonymous install that
// is deleted and reinstalled comes back under a fresh uid, so granting to it
// would be a faucet rather than a campaign; signing in with Apple is what
// makes an account outlive a reinstall, and so what makes "once" mean
// anything. An anonymous caller gets nothing and no error — a zero balance,
// and the ordinary refusal when it tries to call.
//
// `grantedAt` is the mark on the wallet. The caller writes it in the same
// commit as the credits, which is what keeps two concurrent calls from both
// granting.
//
// The ceiling does not bound this: an unspent credit costs nothing, and
// `callsUsed` counts calls made, not credits handed out. `enabled: false`
// does, because the emergency stop means the campaign is over and credits
// nobody may spend are only a confusing balance.
export function voiceCampaignGrant(input: {
  signInProvider: unknown;
  grantedAt: unknown;
  campaign: VoiceCampaign;
}): number {
  if (input.grantedAt != null) return 0;
  if (!voiceGrantEligible(input.signInProvider)) return 0;
  if (!input.campaign.enabled) return 0;
  return input.campaign.freeGrant;
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
// - `mintLimit`: this paid session has minted all of its allowed tokens
// - `campaignOver`: the free campaign is spent, or stopped by hand
export type VoiceMintDecision =
  | "reuse"
  | "debit"
  | "empty"
  | "foreign"
  | "mintLimit"
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
  session: { uid: unknown; startedAtMs: unknown; mintCount: unknown } | null;
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
      // Existing documents from before the bound, and hand-edited values, fail
      // closed while they are live. Once stale they take the ordinary debit
      // path below, which safely replaces them with a count of one.
      if (
        typeof session.mintCount !== "number" ||
        !Number.isInteger(session.mintCount) ||
        session.mintCount < 1 ||
        session.mintCount >= voiceSessionMintLimit
      ) {
        return "mintLimit";
      }
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
