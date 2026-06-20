import 'package:ccm_mobile/features/chat/chat_screen.dart';
import 'package:ccm_mobile/protocol/models.dart';
import 'package:flutter_test/flutter_test.dart';

/// Guards the assistant-message dedup that prevents a re-id'd growing snapshot
/// from rendering twice (the "A+B then A+B+C as two bubbles" bug).

ChatItem _assistant(String id, String text) =>
    ChatItem(id: id, role: ChatItemRole.assistant, text: text, snapshot: true);

ChatItem _user(String id, String text) =>
    ChatItem(id: id, role: ChatItemRole.user, text: text);

String _shown(ChatItem item) => item.text;

void main() {
  group('extractAssistantReplyOptions', () {
    test('extracts bullet suggestions after an options prompt', () {
      final options = extractAssistantReplyOptions('''
What would you like to do? A few options:
- Review the PRD changes
- Look at the spike work
- Explore the core proving loop
''');

      expect(options.map((option) => option.label), <String>[
        'Review the PRD changes',
        'Look at the spike work',
        'Explore the core proving loop',
      ]);
    });

    test('extracts numbered suggestions after a choice prompt', () {
      final options = extractAssistantReplyOptions('''
Choose one:
1. Run tests
2. Fix build
''');

      expect(options.map((option) => option.prompt), <String>[
        'Run tests',
        'Fix build',
      ]);
    });

    test('ignores ordinary explanatory bullet lists', () {
      final options = extractAssistantReplyOptions('''
Implementation status:
- verify_counterexample is done
- verify_lean is still pending
''');

      expect(options, isEmpty);
    });
  });

  test('empty list appends', () {
    expect(assistantMergeIndex(const [], _assistant('m1', 'A'), _shown), -1);
  });

  test('exact id match merges', () {
    final items = [_assistant('m1', 'A+B')];
    expect(assistantMergeIndex(items, _assistant('m1', 'A+B+C'), _shown), 0);
  });

  test('re-id\'d growing snapshot merges into the last bubble (the bug)', () {
    // Server emitted "A+B" as msg_1, now emits "A+B+C" as msg_2.
    final items = [_user('u1', 'hi'), _assistant('msg_1', 'A+B')];
    expect(assistantMergeIndex(items, _assistant('msg_2', 'A+B+C'), _shown), 1);
  });

  test('equal text with a different id merges (no duplicate)', () {
    final items = [_assistant('msg_1', 'A+B')];
    expect(assistantMergeIndex(items, _assistant('msg_9', 'A+B'), _shown), 0);
  });

  test('merges against the shown (still-animating) text', () {
    // The last bubble's full text is "A+B+C" but only "A+B" is shown so far.
    final items = [_assistant('msg_1', 'A+B+C')];
    String shown(ChatItem i) => i.id == 'msg_1' ? 'A+B' : i.text;
    expect(
        assistantMergeIndex(items, _assistant('msg_2', 'A+B+C+D'), shown), 0);
  });

  test('a genuinely new turn (after a user message) appends', () {
    final items = [
      _assistant('msg_1', 'first answer'),
      _user('u2', 'next question'),
    ];
    expect(
      assistantMergeIndex(items, _assistant('msg_2', 'second answer'), _shown),
      -1,
    );
  });

  test('unrelated assistant text (not a continuation) appends', () {
    final items = [_assistant('msg_1', 'A+B')];
    expect(
      assistantMergeIndex(
          items, _assistant('msg_2', 'totally different'), _shown),
      -1,
    );
  });

  test('a shorter prefix does not merge (no regression path)', () {
    final items = [_assistant('msg_1', 'A+B+C')];
    expect(assistantMergeIndex(items, _assistant('msg_2', 'A+B'), _shown), -1);
  });
}
