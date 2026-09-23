// Simplified Chinese content for the scripted demo session. Only what a person
// would have written is translated: the user's turns, the session titles, and
// the assistant's prose. The fenced Dart block and diff are pulled in from
// `demo_content.dart` unchanged, and every string the CLI itself emits (the
// permission prompt, the live terminal, the mode indicator, tool names) stays
// English in `demo_backend.dart` — see `demo_content.dart` for why.
import 'demo_content.dart';

const demoContentZh = DemoContent(
  scriptedTitle: '创建演示文件',
  reviewTitle: '审查计费 webhook',
  docsTitle: '更新 README',
  userTour: '简单讲讲这个 retry 辅助函数是怎么工作的。',
  assistantTour:
      '## retry 辅助函数\n'
      '\n'
      '`withRetry` 会包装一次调用，失败时自动重试。有两点值得注意：\n'
      '\n'
      '- **attempts** — 放弃之前最多尝试几次\n'
      '- *rethrow* — 最后一次失败会原样抛出，绝不吞掉\n'
      '\n'
      '$demoCodeFence\n'
      '\n'
      '问题出在循环的上界。下面的 diff 就是修复：\n'
      '\n'
      '$demoDiffFence',
  userSetup: '我想看看实际效果，能帮我创建一个测试文件吗？',
  thinking: '我打算用 touch 创建一个空文件。',
  reply1: '完成了 — 我已创建 spike-test.txt。要我往里面写点内容吗？也可以问我别的。',
  reply2:
      '这个我也很乐意帮忙 — 在真实会话里，我会先去读相关文件再做修改。'
      '不过这个演示的脚本到这里就结束了。',
);
