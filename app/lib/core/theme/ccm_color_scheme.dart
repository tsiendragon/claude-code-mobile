import 'package:flutter/material.dart';

/// CCM's deliberate "matte graphite" colour schemes.
///
/// Built from a seed (so all the derived Material relationships stay valid)
/// with the surface ladder, text and borders overridden to a neutral graphite
/// palette — the steel-blue primary is kept for non-urgent interactive
/// elements, leaving the warm `liveWire` amber (in [CcmTokens]) as the only
/// chromatic "the machine is acting" signal. Values reuse GitHub's proven
/// dark/light palettes, which the web console already uses, for legibility and
/// cross-surface consistency. `surfaceTint` is transparent so Material applies
/// no elevation wash.

ColorScheme ccmDarkScheme() {
  final base = ColorScheme.fromSeed(
    seedColor: const Color(0xff58a6ff),
    brightness: Brightness.dark,
  );
  return base.copyWith(
    surface: const Color(0xFF0E1116),
    surfaceContainerLowest: const Color(0xFF0B0E13),
    surfaceContainerLow: const Color(0xFF13181F),
    surfaceContainer: const Color(0xFF161B22),
    surfaceContainerHigh: const Color(0xFF1C232C),
    surfaceContainerHighest: const Color(0xFF222B35),
    onSurface: const Color(0xFFE6EDF3),
    onSurfaceVariant: const Color(0xFF9DA7B3),
    outline: const Color(0xFF3A434F),
    outlineVariant: const Color(0xFF2A313C),
    surfaceTint: Colors.transparent,
  );
}

ColorScheme ccmLightScheme() {
  final base = ColorScheme.fromSeed(
    seedColor: const Color(0xff1f6feb),
    brightness: Brightness.light,
  );
  return base.copyWith(
    surface: const Color(0xFFFFFFFF),
    surfaceContainerLowest: const Color(0xFFFFFFFF),
    surfaceContainerLow: const Color(0xFFF6F8FA),
    surfaceContainer: const Color(0xFFEFF2F5),
    surfaceContainerHigh: const Color(0xFFEAEEF2),
    surfaceContainerHighest: const Color(0xFFE3E9EE),
    onSurface: const Color(0xFF1F2328),
    onSurfaceVariant: const Color(0xFF59636E),
    outline: const Color(0xFFAFB8C1),
    outlineVariant: const Color(0xFFD0D7DE),
    surfaceTint: Colors.transparent,
  );
}
