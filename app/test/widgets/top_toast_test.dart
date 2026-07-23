import 'package:drover/src/widgets/top_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('showTopToast renders a message from an in-route context', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => showTopToast(context, 'hello'),
            child: const Text('go'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('go'));
    await tester.pump();

    expect(find.text('hello'), findsOneWidget);
  });

  testWidgets(
    'showTopToastOnOverlay works from a root navigator key, whose context '
    'has no Overlay ancestor',
    (tester) async {
      final navKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(navigatorKey: navKey, home: const SizedBox()),
      );

      // The regression: Overlay.of(navKey.currentContext!) throws "No Overlay
      // widget found" because the navigator's Overlay is its descendant. The
      // overlay-driven entry point must not.
      final overlay = navKey.currentState!.overlay!;
      showTopToastOnOverlay(overlay, 'from overlay');
      await tester.pump();

      expect(find.text('from overlay'), findsOneWidget);
    },
  );

  testWidgets('a top toast auto-dismisses after its visible duration', (
    tester,
  ) async {
    final navKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(navigatorKey: navKey, home: const SizedBox()),
    );

    showTopToastOnOverlay(navKey.currentState!.overlay!, 'transient');
    await tester.pump();
    expect(find.text('transient'), findsOneWidget);

    // Visible window (3s) plus the exit animation.
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(find.text('transient'), findsNothing);
  });
}
