# ccm Mobile App

Flutter Android client for ccm. The app stores one Bridge Server configuration, connects over token-authenticated WebSocket, lists sessions, creates workspace-backed sessions, streams chat events, and handles approvals.

## Development

```bash
flutter pub get
flutter run
```

## Verification

```bash
flutter analyze
flutter test
JAVA_HOME=/opt/homebrew/opt/openjdk@17 PATH=/opt/homebrew/opt/openjdk@17/bin:$PATH flutter build apk
```

Release APK output:

```text
build/app/outputs/flutter-apk/app-release.apk
```

## Session Creation

The normal flow uses Bridge-provided workspaces under the server's `workspace_root`, which defaults to `~/workspace`. Users can pick an existing workspace or create a new subdirectory from the app.

The advanced path field is for server-side absolute paths only. The Bridge validates the real path and rejects paths outside `allowed_paths`.

The app contains:

- Server URL and token configuration with secure token storage.
- JSON-over-WebSocket protocol models and codec.
- Reconnect-oriented Bridge client.
- Session list, workspace-backed session creation, chat screen, approval card, and URL validation.
