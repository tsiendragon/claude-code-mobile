import 'dart:math' as math;

import 'package:ccm_mobile/core/theme/ccm_color_scheme.dart';
import 'package:ccm_mobile/core/theme/ccm_tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Guards the graphite colour schemes against contrast regressions so the
/// "art" never costs legibility (WCAG 2.1 §1.4.3/§1.4.11). These run headless
/// and are the gate that makes future palette tweaks safe.

double _channel(double c) {
  final s = c / 255.0;
  return s <= 0.03928
      ? s / 12.92
      : math.pow((s + 0.055) / 1.055, 2.4).toDouble();
}

double _luminance(Color color) {
  final r = _channel((color.r * 255.0).roundToDouble());
  final g = _channel((color.g * 255.0).roundToDouble());
  final b = _channel((color.b * 255.0).roundToDouble());
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

double _contrast(Color a, Color b) {
  final la = _luminance(a);
  final lb = _luminance(b);
  final hi = math.max(la, lb);
  final lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  for (final entry in <String, ColorScheme>{
    'dark': ccmDarkScheme(),
    'light': ccmLightScheme(),
  }.entries) {
    final name = entry.key;
    final scheme = entry.value;
    final tokens = CcmTokens.fromScheme(scheme);

    test('[$name] body text meets WCAG AA on every surface tier', () {
      final surfaces = <Color>[
        scheme.surface,
        scheme.surfaceContainerLow,
        scheme.surfaceContainer,
        scheme.surfaceContainerHigh,
        scheme.surfaceContainerHighest,
      ];
      for (final surface in surfaces) {
        expect(
          _contrast(scheme.onSurface, surface),
          greaterThanOrEqualTo(4.5),
          reason: '$name onSurface on $surface',
        );
      }
    });

    test('[$name] muted text (onSurfaceVariant) meets AA-large', () {
      expect(
        _contrast(scheme.onSurfaceVariant, scheme.surface),
        greaterThanOrEqualTo(3.0),
      );
    });

    test('[$name] semantic + liveWire tokens are distinguishable on surface',
        () {
      // Non-text UI contrast (WCAG 1.4.11) >= 3:1 against the base surface.
      expect(_contrast(tokens.liveWire, scheme.surface),
          greaterThanOrEqualTo(3.0));
      expect(_contrast(tokens.connError, scheme.surface),
          greaterThanOrEqualTo(3.0));
      expect(
          _contrast(tokens.diffAdd, scheme.surface), greaterThanOrEqualTo(3.0));
    });

    test('[$name] code foreground is legible on the code surface', () {
      expect(_contrast(tokens.codeOnSurface, tokens.codeSurface),
          greaterThanOrEqualTo(4.5));
    });
  }
}
