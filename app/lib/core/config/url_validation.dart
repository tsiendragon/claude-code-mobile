import 'server_config.dart';

enum ServerUrlRisk {
  none,
  privateNetwork,
  tailscale,
}

class ServerUrlValidationResult {
  const ServerUrlValidationResult.valid({this.risk = ServerUrlRisk.none})
      : error = null;

  const ServerUrlValidationResult.invalid(this.error)
      : risk = ServerUrlRisk.none;

  final String? error;
  final ServerUrlRisk risk;

  bool get isValid => error == null;
  bool get requiresPrivateConfirmation =>
      risk == ServerUrlRisk.privateNetwork || risk == ServerUrlRisk.tailscale;
}

ServerUrlValidationResult validateServerUrl(
  String value, {
  required bool allowPrivateWs,
  ConnectionMode connectionMode = ConnectionMode.direct,
}) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
    return const ServerUrlValidationResult.invalid('Enter a valid server URL.');
  }

  if (uri.scheme == 'wss') {
    return const ServerUrlValidationResult.valid();
  }

  if (uri.scheme != 'ws') {
    return const ServerUrlValidationResult.invalid(
      'Only wss:// and restricted ws:// URLs are supported.',
    );
  }

  final host = uri.host.toLowerCase();
  if (host == 'localhost' || host == '127.0.0.1' || host == '::1') {
    return const ServerUrlValidationResult.valid();
  }

  final privateRisk = _privateWsRisk(host);
  if (privateRisk == null) {
    return const ServerUrlValidationResult.invalid(
      'Public ws:// URLs are rejected. Use wss:// for public servers.',
    );
  }

  if (connectionMode == ConnectionMode.tailscale &&
      privateRisk != ServerUrlRisk.tailscale) {
    return const ServerUrlValidationResult.invalid(
      'Tailscale mode expects a 100.x Tailscale ws:// address.',
    );
  }

  if (connectionMode == ConnectionMode.wireguard &&
      privateRisk != ServerUrlRisk.privateNetwork) {
    return const ServerUrlValidationResult.invalid(
      'WireGuard mode expects a private VPN ws:// address.',
    );
  }

  if (!allowPrivateWs) {
    return const ServerUrlValidationResult.invalid(
      'Enable private ws:// connections before saving this URL.',
    );
  }

  return ServerUrlValidationResult.valid(risk: privateRisk);
}

ServerUrlRisk? _privateWsRisk(String host) {
  final ip = InternetAddress.tryParse(host);
  if (ip == null || ip.type != InternetAddressType.ipv4) {
    return null;
  }

  final parts = host.split('.').map(int.tryParse).toList(growable: false);
  if (parts.length != 4 || parts.any((part) => part == null)) {
    return null;
  }

  final a = parts[0]!;
  final b = parts[1]!;

  if (a == 10) return ServerUrlRisk.privateNetwork;
  if (a == 172 && b >= 16 && b <= 31) return ServerUrlRisk.privateNetwork;
  if (a == 192 && b == 168) return ServerUrlRisk.privateNetwork;
  if (a == 100 && b >= 64 && b <= 127) return ServerUrlRisk.tailscale;

  return null;
}

class InternetAddress {
  const InternetAddress._(this.type);

  final InternetAddressType type;

  static InternetAddress? tryParse(String value) {
    final parts = value.split('.');
    if (parts.length != 4) return null;
    for (final part in parts) {
      final number = int.tryParse(part);
      if (number == null || number < 0 || number > 255) return null;
    }
    return const InternetAddress._(InternetAddressType.ipv4);
  }
}

enum InternetAddressType { ipv4 }
