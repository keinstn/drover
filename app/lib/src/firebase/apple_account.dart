import 'package:firebase_core/firebase_core.dart';

import '../infra/best_effort.dart';

/// Attaches an Apple ID to the Firebase account the app is already signed in
/// as, keeping its uid.
///
/// The uid is the only key a purchase balance can hang off — Apple's
/// consumables leave nothing to restore — so the account is *linked*, never
/// replaced: signing in fresh would mint a different uid and orphan whatever
/// was attached to the old one.
///
/// [link] attaches the Apple credential to the current user; [signIn] signs
/// in with the same Apple ID from scratch. Both are passed in rather than
/// called here so the recovery branch below is drivable without Firebase.
Future<void> linkAppleAccount({
  required Future<void> Function() link,
  required Future<void> Function() signIn,
}) async {
  try {
    await link();
  } on FirebaseException catch (e) {
    // Caught one level above FirebaseAuthException, whose constructor is
    // @protected: this way a test can raise the case without a mock.
    if (e.code != 'credential-already-in-use') rethrow;
    // The Apple ID already belongs to an older Firebase user — which is
    // exactly what a reinstalled device hits, because its anonymous uid is
    // new while the Apple ID still points at the uid from before. Adopting
    // that older uid is the one job this feature exists for.
    //
    // ponytail: the anonymous uid this launch just created is abandoned
    // here. Harmless today because nothing hangs off it; once the wallet
    // exists this becomes a merge question (whatever the abandoned uid
    // accrued before the user signed in).
    await signIn();
  }
}

/// Deletes the Firebase account behind the app, then signs back in
/// anonymously so there is still a uid to hang the next session off.
///
/// Every step is passed in rather than called here, same as
/// [linkAppleAccount]: the ordering below is the whole feature, and it is
/// only worth having if it can be driven without Firebase.
///
/// [reauthenticate] returns Apple's authorization code, or null when the
/// platform handed none back.
Future<void> deleteAccount({
  required bool appleLinked,
  required Future<String?> Function() reauthenticate,
  required Future<void> Function(String authorizationCode) revoke,
  required Future<void> Function() delete,
  required Future<void> Function() startOver,
}) async {
  String? authorizationCode;
  if (appleLinked) {
    // Deleting a linked account is a recent-login operation, and the code
    // Apple returns on the way through is the only way to revoke the token
    // afterwards. This throws when the user dismisses Apple's sheet, and
    // that throw is deliberately not caught: backing out of the
    // confirmation must leave the account exactly as it was.
    authorizationCode = await reauthenticate();
  }
  if (authorizationCode != null && authorizationCode.isNotEmpty) {
    // Apple requires the token be revoked when the account goes away, and
    // Firebase can only do that while the account it belongs to still
    // exists — so this goes before the delete, not after it.
    //
    // Best effort, because a revoke fails for reasons that have nothing to
    // do with the user (Firebase cannot reach Apple, the Apple provider in
    // the console is missing its key, the token was already revoked), and
    // none of them are a reason to trap someone in an account they asked to
    // be rid of. Not silent, though: a console left unconfigured fails every
    // revoke, and that has to be visible somewhere.
    await runBestEffort(
      () => revoke(authorizationCode!),
      context: 'revoke the Apple token',
    );
  }
  // Nothing local has changed yet, so a failure here is simply reported and
  // the account stays as it was.
  await delete();
  await startOver();
}
