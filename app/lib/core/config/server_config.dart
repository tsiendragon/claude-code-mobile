enum ConnectionMode {
  direct,
  tailscale,
  wireguard,
}

String connectionModeLabel(ConnectionMode mode) {
  switch (mode) {
    case ConnectionMode.direct:
      return 'Direct';
    case ConnectionMode.tailscale:
      return 'Tailscale';
    case ConnectionMode.wireguard:
      return 'WireGuard';
  }
}

class ServerConfig {
  const ServerConfig({
    required this.serverUrl,
    required this.allowPrivateWs,
    this.connectionMode = ConnectionMode.direct,
  });

  final Uri serverUrl;
  final bool allowPrivateWs;
  final ConnectionMode connectionMode;
}
