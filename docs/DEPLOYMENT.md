# ccm Deployment Guide

This guide covers deploying the Bridge Server and installing the Android app for the current MVP.

## 1. Architecture

```text
Android app
  -> wss://ccm.example.com/ws
  -> Caddy/nginx reverse proxy
  -> Bridge Server on 127.0.0.1:8900
  -> ccc
  -> tmux
  -> Claude Code
```

Private-network deployments can use Tailscale instead:

```text
Android app with Tailscale on
  -> ws://100.x.y.z:8900/ws
  -> Bridge Server bound to the Tailscale IP
```

The Bridge must not be exposed as public plain `ws://`.

## 2. Backend Prerequisites

Install on the machine that will run Claude Code sessions:

- Node.js 18 or newer.
- npm.
- tmux.
- `ccc` CLI.
- Claude Code CLI (`claude`) authenticated for the local user.
- Optional: Tailscale, Caddy, or nginx depending on the network path.

Confirm tools:

```bash
node --version
npm --version
tmux -V
ccc --help
claude --version
```

The Bridge refuses to run as root. Run it as the same developer user that owns the workspace and Claude Code credentials.

## 3. Backend Setup

Clone and build:

```bash
git clone <repo-url> claude-code-mobile
cd claude-code-mobile/server
npm install
npm run build
npm test
```

Create a workspace root:

```bash
mkdir -p ~/workspace
```

Create a token:

```bash
openssl rand -base64 32
```

Create `server/config.production.json`:

```json
{
  "host": "127.0.0.1",
  "port": 8900,
  "token_env": "CCM_TOKEN",
  "workspace_root": "~/workspace",
  "allowed_paths": ["~/workspace"],
  "allow_manual_cwd": true,
  "ccc_bin": "ccc",
  "poll_interval_ms": 1000,
  "event_buffer_size": 200,
  "max_prompt_bytes": 102400,
  "max_ws_message_bytes": 262144,
  "max_event_bytes": 524288,
  "allow_wide_bind": false,
  "allow_hidden_cwd": false,
  "log_level": "info",
  "ccc_timeout_ms": 15000
}
```

Start locally:

```bash
export CCM_TOKEN="<token-from-openssl>"
npm start -- --config config.production.json
```

Expected startup log includes:

- `bridge_listening`
- `app_url_hint`
- `workspace_root`
- `allowed_paths`
- `token_source`

It must not print the full token.

## 4. Network Option A: Caddy + WSS

Use this for public or internet-reachable deployments.

Bridge config:

```json
{
  "host": "127.0.0.1",
  "port": 8900,
  "token_env": "CCM_TOKEN",
  "workspace_root": "~/workspace",
  "allowed_paths": ["~/workspace"]
}
```

Caddyfile:

```caddyfile
ccm.example.com {
    reverse_proxy /ws 127.0.0.1:8900
}
```

Start Caddy and use this App URL:

```text
wss://ccm.example.com/ws
```

## 5. Network Option B: Tailscale + Private ws

Use this when the phone and Bridge machine are on the same Tailnet.

Find the server Tailscale IP:

```bash
tailscale ip -4
```

Set Bridge `host` to that IP:

```json
{
  "host": "100.x.y.z",
  "port": 8900,
  "token_env": "CCM_TOKEN",
  "workspace_root": "~/workspace",
  "allowed_paths": ["~/workspace"]
}
```

Start the Bridge:

```bash
export CCM_TOKEN="<token-from-openssl>"
npm start -- --config config.production.json
```

Use this App URL:

```text
ws://100.x.y.z:8900/ws
```

In the Android app, enable `Allow private ws://`. The phone must have Tailscale VPN enabled.

## 6. Process Manager

For Linux/systemd, create `/etc/systemd/system/ccm-bridge.service`:

```ini
[Unit]
Description=ccm Bridge Server
After=network.target

[Service]
Type=simple
User=YOUR_USER
WorkingDirectory=/home/YOUR_USER/claude-code-mobile/server
Environment=CCM_TOKEN=REPLACE_WITH_TOKEN
ExecStart=/usr/bin/npm start -- --config config.production.json
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

Enable it:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now ccm-bridge
sudo journalctl -u ccm-bridge -f
```

For macOS, use a LaunchAgent or run `npm start` inside your preferred supervisor. Keep the process under the normal user, not root.

## 7. Backend Smoke Test

With the Bridge running:

```bash
cd server
CCM_E2E_TOKEN="$CCM_TOKEN" npm run e2e:smoke
```

Optional prompt smoke:

```bash
CCM_E2E_TOKEN="$CCM_TOKEN" \
CCM_E2E_PROMPT="Do not edit files. Reply with exactly: OK" \
npm run e2e:smoke
```

The script verifies auth, workspace creation/listing, session creation, attach, optional message send, and kill cleanup.

## 8. Android App Build

Install Flutter and Android SDK, then:

```bash
cd app
flutter pub get
flutter analyze
flutter test
JAVA_HOME=/opt/homebrew/opt/openjdk@17 PATH=/opt/homebrew/opt/openjdk@17/bin:$PATH flutter build apk
```

APK output:

```text
app/build/app/outputs/flutter-apk/app-release.apk
```

This is a release APK suitable for direct test install. Play Store distribution still needs a production signing setup.

## 9. Android App Install

Install with adb:

```bash
adb install -r app/build/app/outputs/flutter-apk/app-release.apk
```

Or transfer the APK to the device and install it after allowing installs from that source.

First launch:

1. Open the app.
2. Enter the Bridge Server URL:
   - WSS: `wss://ccm.example.com/ws`
   - Tailscale: `ws://100.x.y.z:8900/ws`
3. Paste the Bridge token.
4. Enable `Allow private ws://` only for Tailscale, localhost, or LAN testing.
5. Tap `Test connection`.
6. Tap `Save`.

## 10. Mobile Acceptance Test

Use the app to verify:

1. Session list loads.
2. New session dialog loads workspaces.
3. Create a new workspace under the default root.
4. Create a session from that workspace.
5. Send a short prompt.
6. Refresh/reattach the chat.
7. Kill the session.
8. Confirm `ccc ps --json` has no new alive test session after cleanup.

## 11. Security Notes

- Keep `allowed_paths` narrow. The default `["~/workspace"]` is recommended.
- App-created workspaces are one-level subdirectories of `workspace_root`.
- Advanced absolute paths are server-machine paths, not phone paths.
- Never put `/` in `allowed_paths`.
- Do not run the Bridge as root.
- Use WSS for public domains.
- Use private `ws://` only behind Tailscale or trusted LAN.
- Treat `CCM_TOKEN` like a password.

## 12. Troubleshooting

`AUTH_FAILED`:

- Check the token in the app exactly matches `CCM_TOKEN`.
- Restart the app connection after changing token.

`PATH_NOT_ALLOWED`:

- Confirm `workspace_root` is inside `allowed_paths`.
- Confirm the advanced path is an absolute path on the server.
- Check symlinks do not resolve outside `allowed_paths`.

`CCC_COMMAND_FAILED`:

- Run the same `ccc` command manually as the same user.
- Check `ccc --help` and `claude --version`.
- Confirm tmux is installed and usable.

App cannot connect over `ws://100.x.y.z`:

- Confirm Tailscale is enabled on the phone.
- Confirm the Bridge binds to the Tailscale IP or an allowed private interface.
- Confirm firewall rules allow the Bridge port.

Public `ws://` rejected by app:

- This is intentional. Use `wss://` through Caddy/nginx for public addresses.
