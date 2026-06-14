import 'package:flutter/material.dart';

/// CCM's type voice as a [ThemeExtension].
///
/// Humans speak in the app's default UI font; the machine (code, commands,
/// diffs, paths, metrics, countdowns) speaks in [monoFamily]. Today that is the
/// platform monospace, so there is zero binary/asset dependency — bundling
/// JetBrains Mono later is a one-line change to [monoFamily].
@immutable
class CcmTypography extends ThemeExtension<CcmTypography> {
  const CcmTypography({required this.monoFamily});

  /// Monospace family for everything the machine says.
  final String monoFamily;

  factory CcmTypography.standard() =>
      const CcmTypography(monoFamily: 'monospace');

  /// Base monospace [TextStyle]; callers `copyWith` size/colour.
  TextStyle get mono => TextStyle(fontFamily: monoFamily);

  /// Tabular, slashed-zero figures for in-place numeric instruments
  /// (countdowns, metrics, byte sizes) so they never re-layout on update.
  /// Apply via `style.copyWith(fontFeatures: CcmTypography.tabularFigures)`.
  static const List<FontFeature> tabularFigures = <FontFeature>[
    FontFeature.tabularFigures(),
    FontFeature.slashedZero(),
  ];

  @override
  CcmTypography copyWith({String? monoFamily}) =>
      CcmTypography(monoFamily: monoFamily ?? this.monoFamily);

  @override
  CcmTypography lerp(ThemeExtension<CcmTypography>? other, double t) {
    if (other is! CcmTypography) return this;
    // Font family is discrete — snap at the midpoint.
    return t < 0.5 ? this : other;
  }
}
