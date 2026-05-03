enum ConnectionMode {
  direct,
  tailscale,
  wireguard,
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
