import 'package:firebase_core/firebase_core.dart';

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
