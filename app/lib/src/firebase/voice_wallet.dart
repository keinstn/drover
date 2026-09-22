import 'package:cloud_functions/cloud_functions.dart';

/// What one ledger row records. Only the three the server writes: an unknown
/// string is a row this build does not know how to name, and naming it wrong
/// is worse than leaving it out.
enum VoiceLedgerType { call, refund, grant }

/// One row of the credit ledger, as the wallet callable reports it.
class VoiceLedgerEntry {
  const VoiceLedgerEntry({
    required this.type,
    required this.credits,
    required this.at,
  });

  final VoiceLedgerType type;

  /// Signed: −1 for a call, +1 for its refund or for the campaign grant.
  final int credits;

  /// Null when the row came back without a usable timestamp. The server
  /// resolves one on commit and orders by it, so this only happens to a row
  /// somebody edited by hand — which is still a real movement of credits,
  /// it just cannot say when.
  final DateTime? at;
}

/// The balance and the rows behind it.
class VoiceWallet {
  const VoiceWallet({required this.credits, required this.entries});

  final int credits;

  /// Newest first, as the callable returns them.
  final List<VoiceLedgerEntry> entries;
}

/// Decodes what the `voiceWallet` callable returned.
///
/// Takes `Object?` so decoding is testable without Firebase, and drops
/// anything it does not recognise rather than throwing: the server drops the
/// same rows, but this is the client that *renders* them, and a payload it
/// did not expect must not take the settings screen down with it.
VoiceWallet parseVoiceWallet(Object? payload) {
  if (payload is! Map) return const VoiceWallet(credits: 0, entries: []);
  final rows = payload['entries'];
  return VoiceWallet(
    credits: _int(payload['credits']) ?? 0,
    entries: [
      if (rows is List)
        for (final row in rows) ?_entry(row),
    ],
  );
}

VoiceLedgerEntry? _entry(Object? row) {
  if (row is! Map) return null;
  final type = switch (row['type']) {
    'voiceCall' => VoiceLedgerType.call,
    'voiceCallRefund' => VoiceLedgerType.refund,
    // The free campaign's opening balance, granted server-side on a
    // signed-in account's first wallet read or first call. A positive row
    // like a refund, but it has to say where the credits came from.
    'campaignGrant' => VoiceLedgerType.grant,
    _ => null,
  };
  final credits = _int(row['credits']);
  if (type == null || credits == null) return null;
  final at = _int(row['at']);
  return VoiceLedgerEntry(
    type: type,
    credits: credits,
    at: at == null ? null : DateTime.fromMillisecondsSinceEpoch(at),
  );
}

/// `num`, not `int`: JSON that came back as a double is still the number the
/// server meant.
int? _int(Object? value) => value is num ? value.toInt() : null;

/// How much a sign-in's own wallet read just added, if anything.
///
/// A delta against the balance the app already held rather than a look at
/// [VoiceWallet.entries]: an account that was granted its campaign credits
/// before this sign-in (an Apple ID re-linked on a fresh install, say) still
/// carries a `campaignGrant` row, and reading the ledger instead would toast
/// every such sign-in as if it just happened.
int creditsGranted({required int before, required int? after}) =>
    after == null ? 0 : after - before;

/// Asks the server for the balance — `firestore.rules` denies the client
/// every read, so this callable is the only way the device learns its own.
///
/// No arguments: the Function reads the uid from the auth context, the same
/// account it would charge. Async so that a Firebase bootstrap that failed
/// surfaces as a rejected future rather than throwing at the call site.
Future<VoiceWallet> fetchVoiceWallet() async {
  final result = await FirebaseFunctions.instanceFor(
    region: 'us-central1',
  ).httpsCallable('voiceWallet').call<Object?>();
  return parseVoiceWallet(result.data);
}

/// Adds one to the count of people who would pay to keep using the voice
/// assistant.
///
/// Nothing is bought and nothing is promised back — the call exists so the
/// free campaign can answer the one question it is being run to answer. The
/// server stores no uid, only the total, which is why the "you already said
/// this" state is a local flag on this device rather than something the
/// wallet can be asked about.
///
/// Returns nothing: the caller learns it worked by the future completing.
Future<void> recordVoicePaidInterest() async {
  await FirebaseFunctions.instanceFor(
    region: 'us-central1',
  ).httpsCallable('voicePaidInterest').call<Object?>();
}
