import 'package:drover/src/widgets/text_context_menu.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

ContextMenuButtonItem _item(ContextMenuButtonType type) =>
    ContextMenuButtonItem(onPressed: () {}, type: type);

void main() {
  group('withoutScanText', () {
    test('drops the liveTextInput item and preserves the rest', () {
      final items = [
        _item(ContextMenuButtonType.paste),
        _item(ContextMenuButtonType.liveTextInput),
        _item(ContextMenuButtonType.selectAll),
      ];

      final result = withoutScanText(items);

      expect(result.map((i) => i.type), [
        ContextMenuButtonType.paste,
        ContextMenuButtonType.selectAll,
      ]);
    });

    test('yields an empty list when only liveTextInput is present', () {
      final items = [_item(ContextMenuButtonType.liveTextInput)];

      expect(withoutScanText(items), isEmpty);
    });

    test('leaves a list without liveTextInput unchanged', () {
      final items = [
        _item(ContextMenuButtonType.paste),
        _item(ContextMenuButtonType.selectAll),
      ];

      expect(withoutScanText(items).map((i) => i.type), [
        ContextMenuButtonType.paste,
        ContextMenuButtonType.selectAll,
      ]);
    });
  });
}
