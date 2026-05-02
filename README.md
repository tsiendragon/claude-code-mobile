# ccm (Claude Code Mobile)

ccm is a mobile control plane for AI coding assistants running on a remote machine. It turns ccc-managed Claude Code sessions into a mobile-friendly chat and approval experience.

Current status: MVP scaffold with a Node.js Bridge Server, Flutter Android app, workspace-based session creation, and Android release APK build verified. The product and implementation plans live in:

- [PRD](./docs/PRD.md)
- [Technical Design](./docs/TECH_DESIGN.md)

## Structure

```text
docs/    Product and technical design docs
server/  Node.js Bridge Server
app/     Flutter Android app
```

## Development

Bridge Server:

```bash
cd server
npm install
export CCM_TOKEN="$(openssl rand -base64 32)"
npm run build
npm test
npm run dev -- --config config.example.json
```

The default config creates and exposes app-created workspaces under `~/workspace`. `session.run` accepts either a `workspace_id` from the app workspace picker or an advanced `cwd` value. Advanced `cwd` values are paths on the server machine and must resolve inside `allowed_paths`.

Flutter App:

```bash
cd app
flutter pub get
flutter test
flutter run
```

Android release APK:

```bash
cd app
JAVA_HOME=/opt/homebrew/opt/openjdk@17 PATH=/opt/homebrew/opt/openjdk@17/bin:$PATH flutter build apk
```

The generated APK is written to `app/build/app/outputs/flutter-apk/app-release.apk`.

The Bridge always enforces `allowed_paths` (defaulting to `workspace_root`) and refuses to run as root. Public deployments should put the Bridge behind WSS, or bind it to a Tailscale IP for private `ws://` access.
By default new mobile-created sessions use subdirectories under `~/workspace`; advanced users can still enter an absolute server path if it is inside `allowed_paths`.

## MVP Scope

- One saved server configuration.
- Token-authenticated WebSocket connection.
- Attach to existing ccc sessions.
- Create Claude Code sessions.
- Send prompts.
- Receive state and assistant output events.
- Approve pending actions with approval IDs.
- Interrupt and kill sessions.
- Snapshot-based reconnect.

File viewing, local history persistence, notifications, and multi-backend polish are Phase 2+.
