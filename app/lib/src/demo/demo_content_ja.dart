// Japanese content for the scripted demo session. Only what a person would
// have written is translated: the user's turns, the session titles, and the
// assistant's prose. The fenced Dart block and diff are pulled in from
// `demo_content.dart` unchanged, and every string the CLI itself emits (the
// permission prompt, the live terminal, the mode indicator, tool names) stays
// English in `demo_backend.dart` — see `demo_content.dart` for why.
import 'demo_content.dart';

const demoContentJa = DemoContent(
  scriptedTitle: 'デモ用のファイルを作る',
  reviewTitle: '請求 webhook をレビュー',
  docsTitle: 'README を更新',
  userTour: 'retry ヘルパーの仕組みをざっと説明して。',
  assistantTour:
      '## retry ヘルパー\n'
      '\n'
      '`withRetry` は呼び出しをラップして、失敗したときにやり直します。'
      'ポイントは 2 つです:\n'
      '\n'
      '- **attempts** — あきらめるまでの試行回数\n'
      '- *rethrow* — 最後の失敗は握りつぶさずそのまま投げ直す\n'
      '\n'
      '$demoCodeFence\n'
      '\n'
      'バグはループの上限でした。修正を diff で示します:\n'
      '\n'
      '$demoDiffFence',
  userSetup: '動きを見てみたいので、テスト用のファイルを作ってくれる？',
  thinking: 'touch で空のファイルを作ることにします。',
  reply1:
      'できました — spike-test.txt を作成しました。'
      '中身を書き足しましょうか？ ほかのことを聞いてもらっても大丈夫です。',
  reply2:
      'それも喜んでお手伝いします — 実際のセッションなら、関連するファイルを読んでから'
      '変更を加えるところです。ただ、このデモの台本はここまでです。',
);
