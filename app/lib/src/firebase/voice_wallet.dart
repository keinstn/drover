import 'package:cloud_functions/cloud_functions.dart';

/// What one ledger row records. Only the two the server writes: an unknown
/// string is a row this build does not know how to name, and naming it wrong
/// is worse than leaving it out.
enum VoiceLedgerType { call, refund }

/// One row of the credit ledger, as the wallet callable reports it.
class VoiceLedgerEntry {
  const VoiceLedgerEntry({
    required this.type,
    required this.credits,
    required this.at,
  });

  final VoiceLedgerType type;

  /// Signed: −1 for a call, +1 for its refund.
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
