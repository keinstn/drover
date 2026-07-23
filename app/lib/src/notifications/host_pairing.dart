import 'package:cloud_functions/cloud_functions.dart';

class PairingCode {
  const PairingCode({
    required this.code,
    required this.hostId,
    required this.completionUrl,
  });

  final String code;
  final String hostId;
  final String completionUrl;

  static PairingCode fromResponse(Object? value) {
    if (value is! Map<Object?, Object?>) {
      throw const FormatException('Invalid pairing response.');
    }
    final code = value['pairingCode'];
    final hostId = value['hostId'];
    final completionUrl = value['completionUrl'];
    if (code is! String || hostId is! String || completionUrl is! String) {
      throw const FormatException('Invalid pairing response.');
    }
    return PairingCode(
      code: code,
      hostId: hostId,
      completionUrl: completionUrl,
    );
  }
}

abstract interface class HostPairingGateway {
  Future<PairingCode> createPairingCode(String hostId);
  Future<void> revokeHost(String hostId);
}

class FirebaseHostPairingGateway implements HostPairingGateway {
  FirebaseHostPairingGateway([FirebaseFunctions? functions])
    : _functions =
          functions ?? FirebaseFunctions.instanceFor(region: 'us-central1');

  final FirebaseFunctions _functions;

  @override
  Future<PairingCode> createPairingCode(String hostId) async {
    final response = await _functions
        .httpsCallable('createPairingCode')
        .call<Object?>({'hostId': hostId});
    return PairingCode.fromResponse(response.data);
  }

  @override
  Future<void> revokeHost(String hostId) async {
    await _functions.httpsCallable('revokeHost').call<void>({'hostId': hostId});
  }
}
