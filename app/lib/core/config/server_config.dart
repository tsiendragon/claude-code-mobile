class ServerConfig {
  const ServerConfig({
    required this.serverUrl,
    required this.allowPrivateWs,
  });

  final Uri serverUrl;
  final bool allowPrivateWs;
}
