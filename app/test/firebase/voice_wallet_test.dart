import 'package:drover/src/firebase/voice_wallet.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reads the balance and the rows behind it', () {
    final wallet = parseVoiceWallet({
      'credits': 3,
      'entries': [
        {'type': 'voiceCall', 'credits': -1, 'at': 1758300000000},
        {'type': 'voiceCallRefund', 'credits': 1, 'at': 1758200000000},
      ],
    });

    expect(wallet.credits, 3);
    expect(wallet.entries, hasLength(2));
    expect(wallet.entries.first.type, VoiceLedgerType.call);
    expect(wallet.entries.first.credits, -1);
    expect(
      wallet.entries.first.at,
      DateTime.fromMillisecondsSinceEpoch(1758300000000),
    );
    expect(wallet.entries.last.type, VoiceLedgerType.refund);
    expect(wallet.entries.last.credits, 1);
  });

  test('names the campaign grant rather than dropping it', () {
    final wallet = parseVoiceWallet({
      'credits': 3,
      'entries': [
        {'type': 'campaignGrant', 'credits': 3, 'at': 1758100000000},
      ],
    });

    // The free credits have to be nameable: dropped, the balance would say
    // three and the ledger behind it would say nothing at all.
    expect(wallet.entries.single.type, VoiceLedgerType.grant);
    expect(wallet.entries.single.credits, 3);
    expect(
      wallet.entries.single.at,
      DateTime.fromMillisecondsSinceEpoch(1758100000000),
    );
  });

  test('drops a row whose type this build does not know', () {
    final wallet = parseVoiceWallet({
      'credits': 1,
      'entries': [
        {'type': 'voicePurchase', 'credits': 10, 'at': 1758300000000},
        {'type': 'voiceCall', 'credits': -1, 'at': 1758300000000},
      ],
    });

    expect(wallet.credits, 1);
    expect(wallet.entries, hasLength(1));
    expect(wallet.entries.single.type, VoiceLedgerType.call);
  });

  test('reads a number the channel handed back as a double', () {
    // The iOS callable channel is free to decode a JSON number either way,
    // and a balance of 3 arriving as 3.0 must not read as no balance at all.
    final wallet = parseVoiceWallet({
      'credits': 3.0,
      'entries': [
        {'type': 'voiceCall', 'credits': -1.0, 'at': 1758300000000.0},
      ],
    });

    expect(wallet.credits, 3);
    expect(wallet.entries.single.credits, -1);
    expect(
      wallet.entries.single.at,
      DateTime.fromMillisecondsSinceEpoch(1758300000000),
    );
  });

  test('keeps a row whose server timestamp had not landed', () {
    final wallet = parseVoiceWallet({
      'credits': 0,
      'entries': [
        {'type': 'voiceCall', 'credits': -1, 'at': null},
      ],
    });

    expect(wallet.entries.single.credits, -1);
    expect(wallet.entries.single.at, isNull);
  });

  test('a payload of the wrong shape decodes to an empty wallet', () {
    for (final payload in <Object?>[
      null,
      'nope',
      <Object?>[],
      {'credits': 'three', 'entries': 'none'},
      {
        'credits': 2,
        'entries': [
          'nope',
          {'type': 'voiceCall'},
          {'credits': -1},
        ],
      },
    ]) {
      final wallet = parseVoiceWallet(payload);
      expect(wallet.entries, isEmpty, reason: '$payload');
    }
    expect(parseVoiceWallet(null).credits, 0);
    // A readable balance survives its unreadable rows.
    expect(parseVoiceWallet({'credits': 2, 'entries': 'none'}).credits, 2);
  });
}
