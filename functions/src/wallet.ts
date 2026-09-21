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

// What a mint should do about the balance:
// - `reuse`: this call was already paid for, mint again for free
// - `debit`: a new call, and the balance covers it
// - `empty`: a new call the balance does not cover
// - `foreign`: the session ID belongs to somebody else
export type VoiceMintDecision = "reuse" | "debit" | "empty" | "foreign";

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
