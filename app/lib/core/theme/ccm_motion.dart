import 'package:flutter/material.dart';

/// CCM's motion tokens as a [ThemeExtension] — a small, fixed vocabulary of
/// durations and curves so animations stay restrained and consistent.
///
/// Reduce-motion is folded in centrally: callers resolve durations through
/// [durationOf] (or check [reduceMotionOf]) so every animation degrades to
/// instant when the platform requests it. The streaming cadence and other
/// existing timings are mirrored here as the single source of truth.
@immutable
class CcmMotion extends ThemeExtension<CcmMotion> {
  const CcmMotion({
    required this.stream,
    required this.thinking,
    required this.scroll,
    required this.fast,
    required this.standard,
    required this.emphasized,
    required this.standardCurve,
    required this.emphasizedCurve,
  });

  /// 40ms — the existing assistant streaming frame cadence.
  final Duration stream;

  /// 1200ms — the existing thinking-indicator cycle.
  final Duration thinking;

  /// 180ms — the existing programmatic scroll animation.
  final Duration scroll;

  final Duration fast;
  final Duration standard;
  final Duration emphasized;

  final Curve standardCurve;
  final Curve emphasizedCurve;

  factory CcmMotion.standard() => const CcmMotion(
        stream: Duration(milliseconds: 40),
        thinking: Duration(milliseconds: 1200),
        scroll: Duration(milliseconds: 180),
        fast: Duration(milliseconds: 120),
        standard: Duration(milliseconds: 200),
        emphasized: Duration(milliseconds: 320),
        standardCurve: Curves.easeOutCubic,
        emphasizedCurve: Cubic(0.05, 0.7, 0.1, 1.0),
      );

  /// Whether the platform has requested reduced motion.
  static bool reduceMotionOf(BuildContext context) =>
      MediaQuery.maybeOf(context)?.disableAnimations ?? false;

  static CcmMotion of(BuildContext context) =>
      Theme.of(context).extension<CcmMotion>() ?? CcmMotion.standard();

  /// Resolves [d] to [Duration.zero] when reduce-motion is active.
  Duration durationOf(BuildContext context, Duration d) =>
      reduceMotionOf(context) ? Duration.zero : d;

  @override
  CcmMotion copyWith({
    Duration? stream,
    Duration? thinking,
    Duration? scroll,
    Duration? fast,
    Duration? standard,
    Duration? emphasized,
    Curve? standardCurve,
    Curve? emphasizedCurve,
  }) {
    return CcmMotion(
      stream: stream ?? this.stream,
      thinking: thinking ?? this.thinking,
      scroll: scroll ?? this.scroll,
      fast: fast ?? this.fast,
      standard: standard ?? this.standard,
      emphasized: emphasized ?? this.emphasized,
      standardCurve: standardCurve ?? this.standardCurve,
      emphasizedCurve: emphasizedCurve ?? this.emphasizedCurve,
    );
  }

  @override
  CcmMotion lerp(ThemeExtension<CcmMotion>? other, double t) {
    if (other is! CcmMotion) return this;
    // Durations/curves are discrete tokens — snap at the midpoint.
    return t < 0.5 ? this : other;
  }
}
