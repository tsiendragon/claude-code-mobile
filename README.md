# ccm (Claude Code Mobile)

ccm is a mobile control plane for AI coding assistants running on a remote machine. It turns ccc-managed Claude Code sessions into a mobile-friendly chat and approval experience.

Current status: MVP scaffold with a Node.js Bridge Server, Flutter Android app, workspace-based session creation, and Android release APK build verified. The product and implementation plans live in:

- [PRD](./docs/PRD.md)
- [Technical Design](./docs/TECH_DESIGN.md)
- [Deployment Guide](./docs/DEPLOYMENT.md)

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

### Web Console (browser UI)

The Bridge also serves a browser-based console from its HTTP port — the same one used
for the WebSocket endpoint. It speaks the identical protocol as the Flutter app, so it is
useful for manual testing and for driving the Bridge with a browser-automation agent to
surface bugs. Once the Bridge is running, open `http://127.0.0.1:8900/` and enter your
`CCM_TOKEN` to connect.

The console covers sessions (list/create/attach/kill), prompts and `/commands`, approval
cards, interrupt, message history paging, image upload, a file browser, system stats,
feedback submission, and a raw event/RPC log for debugging. Note the Bridge keeps a single
active socket, so connecting the console disconnects any attached mobile app (and vice
versa).

Toggle it with `web_ui_enabled` in the config (or `CCM_WEB_UI=0`); override the served
directory with `web_ui_dir` (or `CCM_WEB_UI_DIR`). Like the WS endpoint, the console is
unauthenticated at the HTTP layer — keep the Bridge behind WSS or a private network.

The default config creates and exposes app-created workspaces under `~/workspace`. It also allows advanced server paths under `~/apps` for sessions that need to work in existing repos. `session.run` accepts either a `workspace_id` from the app workspace picker or an advanced `cwd` value. Advanced `cwd` values are paths on the server machine and must resolve inside `allowed_paths`.

Bridge smoke test against a running local Bridge:

```bash
cd server
CCM_E2E_TOKEN="$CCM_TOKEN" npm run e2e:smoke
CCM_E2E_TOKEN="$CCM_TOKEN" CCM_E2E_PROMPT="Do not edit files. Reply with exactly: OK" npm run e2e:smoke
```

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

The Bridge always enforces `allowed_paths` and refuses to run as root. Public deployments should put the Bridge behind WSS, or bind it to a Tailscale IP for private `ws://` access.
By default new mobile-created sessions use subdirectories under `~/workspace`; advanced users can still enter an absolute server path under an allowed root such as `~/apps`.

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
