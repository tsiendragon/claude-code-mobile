# ccm Mobile App

Flutter MVP skeleton for the Android client described in `docs/TECH_DESIGN.md`.

This scaffold was created manually because Flutter tooling was not available in
the local environment. Once Flutter is installed, run:

```bash
flutter pub get
flutter run
```

The app contains:

- Server URL and token configuration with secure token storage.
- JSON-over-WebSocket protocol models and codec.
- Reconnect-oriented Bridge client.
- Session list, chat screen, approval card, and URL validation.
