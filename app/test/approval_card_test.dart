import 'package:ccm_mobile/core/theme/ccm_motion.dart';
import 'package:ccm_mobile/core/theme/ccm_tokens.dart';
import 'package:ccm_mobile/core/theme/ccm_typography.dart';
import 'package:ccm_mobile/features/approvals/approval_card.dart';
import 'package:ccm_mobile/protocol/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Behaviour-locking tests for [ApprovalCard]: the signature approval surface.
///
/// These pin the contract a visual redesign must NOT break — the Accept/Reject
/// labels, action dispatch wiring, and the fact the card renders cleanly in
/// dark + reduce-motion. They are intentionally behavioural (not pixel
/// goldens) so they stay stable while the styling is reworked.

PendingApproval _approval({
  String operationKind = 'file_edit',
  List<String> actions = const <String>['approve', 'reject', 'always'],
  String description = 'Edit lib/main.dart',
  String? diffSummary,
  Duration ttl = const Duration(minutes: 5),
}) {
  return PendingApproval(
    approvalId: 'a1',
    sessionId: 's1',
    operationKind: operationKind,
    description: description,
    paths: const <String>['lib/main.dart'],
    actions: actions,
    diffSummary: diffSummary,
    expiresAt: DateTime.now().add(ttl),
  );
}

ThemeData _theme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xff1f6feb),
    brightness: brightness,
  ).copyWith(surfaceTint: Colors.transparent);
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    extensions: <ThemeExtension<dynamic>>[
      CcmTokens.fromScheme(scheme),
      CcmTypography.standard(),
      CcmMotion.standard(),
    ],
  );
}

Widget _host(
  Widget child, {
  Brightness brightness = Brightness.light,
  bool reduceMotion = false,
}) {
  return MaterialApp(
    theme: _theme(brightness),
    home: Scaffold(
      body: Builder(
        builder: (context) {
          final media = MediaQuery.of(context);
          return MediaQuery(
            data: media.copyWith(disableAnimations: reduceMotion),
            child: SingleChildScrollView(child: child),
          );
        },
      ),
    ),
  );
}

void main() {
  testWidgets('renders operation label and Accept/Reject actions',
      (tester) async {
    await tester.pumpWidget(_host(
      ApprovalCard(
        approval: _approval(),
        isSubmitting: false,
        onAction: (_) {},
      ),
    ));

    expect(find.text('File change approval'), findsOneWidget);
    expect(find.text('Edit lib/main.dart'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Accept'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Reject'), findsOneWidget);

    // Dispose the card so its per-second expiry Timer is cancelled.
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Accept dispatches the approve action', (tester) async {
    final dispatched = <String>[];
    await tester.pumpWidget(_host(
      ApprovalCard(
        approval: _approval(),
        isSubmitting: false,
        onAction: dispatched.add,
      ),
    ));

    await tester.tap(find.widgetWithText(FilledButton, 'Accept'));
    await tester.pump();

    expect(dispatched, <String>['approve']);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Reject dispatches the reject action', (tester) async {
    final dispatched = <String>[];
    await tester.pumpWidget(_host(
      ApprovalCard(
        approval: _approval(),
        isSubmitting: false,
        onAction: dispatched.add,
      ),
    ));

    await tester.tap(find.widgetWithText(OutlinedButton, 'Reject'));
    await tester.pump();

    expect(dispatched, <String>['reject']);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('command approval renders the command in a code block',
      (tester) async {
    await tester.pumpWidget(_host(
      ApprovalCard(
        approval: _approval(
          operationKind: 'command',
          actions: const <String>['approve', 'reject'],
          description: 'Run the build\n\nnpm run build',
        ),
        isSubmitting: false,
        onAction: (_) {},
      ),
    ));

    expect(find.text('Command approval'), findsOneWidget);
    expect(find.text('npm run build'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('renders and dispatches in dark theme with reduce-motion',
      (tester) async {
    final dispatched = <String>[];
    await tester.pumpWidget(_host(
      ApprovalCard(
        approval: _approval(diffSummary: '@@ -1 +1 @@\n-old\n+new'),
        isSubmitting: false,
        onAction: dispatched.add,
      ),
      brightness: Brightness.dark,
      reduceMotion: true,
    ));

    expect(tester.takeException(), isNull);
    await tester.tap(find.widgetWithText(FilledButton, 'Accept'));
    await tester.pump();
    expect(dispatched, <String>['approve']);

    await tester.pumpWidget(const SizedBox());
  });
}
