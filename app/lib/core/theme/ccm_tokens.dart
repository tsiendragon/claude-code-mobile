import 'package:flutter/material.dart';

import 'ccm_motion.dart';
import 'ccm_typography.dart';

/// Semantic design tokens for CCM, layered on top of the Material
/// [ColorScheme] as a [ThemeExtension].
///
/// Introduced as a (near) pixel-identical alias of the colours/spacings the app
/// already computes inline, so the boundary commit is provably neutral. The one
/// deliberate change at introduction is normalising the command-block surface
/// (previously `isDark ? surface : 0xFF1F2937`, which was inverted) into a
/// single recessed graphite that reads as machine/terminal output in both
/// brightnesses. Future value changes (the full graphite palette) happen later
/// behind golden tests — the call sites do not move.
@immutable
class CcmTokens extends ThemeExtension<CcmTokens> {
  const CcmTokens({
    required this.spaceXs,
    required this.spaceSm,
    required this.spaceMd,
    required this.spaceLg,
    required this.radiusPanel,
    required this.radiusControl,
    required this.codeSurface,
    required this.codeOnSurface,
    required this.diffAdd,
    required this.diffRemove,
    required this.diffMeta,
    required this.liveWire,
    required this.liveWireDim,
    required this.connOk,
    required this.connError,
  });

  /// 4 / 8 / 12 / 16 spacing scale — the literals used across the app today.
  final double spaceXs;
  final double spaceSm;
  final double spaceMd;
  final double spaceLg;

  /// Corner radii: panels/cards vs. inline controls. Today's values (8 / 6).
  final double radiusPanel;
  final double radiusControl;

  /// Recessed "terminal" surface for code/command blocks. Deliberately dark in
  /// both brightnesses so code reads as machine output, with a stable light
  /// foreground.
  final Color codeSurface;
  final Color codeOnSurface;

  /// Diff semantics — functional colours, legible on the default surface.
  final Color diffAdd;
  final Color diffRemove;
  final Color diffMeta;

  /// The single rationed warm accent — "the remote machine is acting on your
  /// behalf". Reserved for streaming, the live-connection dot, the approval
  /// edge and the thinking indicator. Never used on ordinary buttons/links.
  final Color liveWire;
  final Color liveWireDim;

  /// Connection-health semantics.
  final Color connOk;
  final Color connError;

  /// Derives tokens from the active [ColorScheme]. Non-colour spatial tokens
  /// are the literal values already used across the app.
  factory CcmTokens.fromScheme(ColorScheme scheme) {
    final isDark = scheme.brightness == Brightness.dark;
    return CcmTokens(
      spaceXs: 4,
      spaceSm: 8,
      spaceMd: 12,
      spaceLg: 16,
      radiusPanel: 8,
      radiusControl: 6,
      codeSurface: const Color(0xFF161B22),
      codeOnSurface: const Color(0xFFE6EDF3),
      diffAdd: isDark ? const Color(0xFF3FB950) : const Color(0xFF1A7F37),
      diffRemove: scheme.error,
      diffMeta: scheme.onSurfaceVariant,
      liveWire: const Color(0xFFE3A008),
      liveWireDim: isDark ? const Color(0xFF8A6D1B) : const Color(0xFFB07D12),
      connOk: isDark ? const Color(0xFF3FB950) : const Color(0xFF1A7F37),
      connError: scheme.error,
    );
  }

  @override
  CcmTokens copyWith({
    double? spaceXs,
    double? spaceSm,
    double? spaceMd,
    double? spaceLg,
    double? radiusPanel,
    double? radiusControl,
    Color? codeSurface,
    Color? codeOnSurface,
    Color? diffAdd,
    Color? diffRemove,
    Color? diffMeta,
    Color? liveWire,
    Color? liveWireDim,
    Color? connOk,
    Color? connError,
  }) {
    return CcmTokens(
      spaceXs: spaceXs ?? this.spaceXs,
      spaceSm: spaceSm ?? this.spaceSm,
      spaceMd: spaceMd ?? this.spaceMd,
      spaceLg: spaceLg ?? this.spaceLg,
      radiusPanel: radiusPanel ?? this.radiusPanel,
      radiusControl: radiusControl ?? this.radiusControl,
      codeSurface: codeSurface ?? this.codeSurface,
      codeOnSurface: codeOnSurface ?? this.codeOnSurface,
      diffAdd: diffAdd ?? this.diffAdd,
      diffRemove: diffRemove ?? this.diffRemove,
      diffMeta: diffMeta ?? this.diffMeta,
      liveWire: liveWire ?? this.liveWire,
      liveWireDim: liveWireDim ?? this.liveWireDim,
      connOk: connOk ?? this.connOk,
      connError: connError ?? this.connError,
    );
  }

  @override
  CcmTokens lerp(ThemeExtension<CcmTokens>? other, double t) {
    if (other is! CcmTokens) return this;
    return CcmTokens(
      spaceXs: lerpDouble(spaceXs, other.spaceXs, t),
      spaceSm: lerpDouble(spaceSm, other.spaceSm, t),
      spaceMd: lerpDouble(spaceMd, other.spaceMd, t),
      spaceLg: lerpDouble(spaceLg, other.spaceLg, t),
      radiusPanel: lerpDouble(radiusPanel, other.radiusPanel, t),
      radiusControl: lerpDouble(radiusControl, other.radiusControl, t),
      codeSurface: Color.lerp(codeSurface, other.codeSurface, t)!,
      codeOnSurface: Color.lerp(codeOnSurface, other.codeOnSurface, t)!,
      diffAdd: Color.lerp(diffAdd, other.diffAdd, t)!,
      diffRemove: Color.lerp(diffRemove, other.diffRemove, t)!,
      diffMeta: Color.lerp(diffMeta, other.diffMeta, t)!,
      liveWire: Color.lerp(liveWire, other.liveWire, t)!,
      liveWireDim: Color.lerp(liveWireDim, other.liveWireDim, t)!,
      connOk: Color.lerp(connOk, other.connOk, t)!,
      connError: Color.lerp(connError, other.connError, t)!,
    );
  }

  static double lerpDouble(double a, double b, double t) => a + (b - a) * t;
}

/// Ergonomic access to CCM theme extensions, with graceful fallbacks so widget
/// tests that build a bare theme never crash on a missing extension.
extension CcmThemeX on BuildContext {
  CcmTokens get tokens =>
      Theme.of(this).extension<CcmTokens>() ??
      CcmTokens.fromScheme(Theme.of(this).colorScheme);

  CcmTypography get type =>
      Theme.of(this).extension<CcmTypography>() ?? CcmTypography.standard();

  CcmMotion get motion =>
      Theme.of(this).extension<CcmMotion>() ?? CcmMotion.standard();
}
