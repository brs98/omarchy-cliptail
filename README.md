# Clip Bridge

Clipboard sync between an Omarchy Quattro laptop and an iPhone, over your own
tailnet. No relay server, no account, no LocalSend dance.

**What it does:** one tap on the phone moves the clipboard in either direction.
Phone → laptop is fully automatic on the laptop end; laptop → phone needs the
phone to ask for it.

**What it can't do:** true Universal Clipboard. iOS won't let a third-party app
read the pasteboard in the background, and Apple's Continuity protocol is a
signed system daemon you can't join. One tap is the ceiling on iOS. Everything
here is built to make that one tap as cheap as possible.

## Layout

```
manifest.json            plugin manifest (service + bar-widget)
Service.qml              headless service: health check, IPC verbs
Widget.qml               bar widget: last sync direction and age
cmd/clipbridge/main.go   the daemon — all clipboard and network logic
systemd/                 user unit
install.sh               builds, wires up systemd + tailscale serve, links the plugin
```

The split is deliberate. Plugins run as unsandboxed code inside the long-lived
`omarchy-shell` process, so an HTTP listener in there means a panic takes your
bar, notifications and lock screen with it. The daemon runs under systemd where
it can crash and restart on its own.

## Install

```bash
git clone <your-repo-url> ~/src/clipbridge
cd ~/src/clipbridge
./install.sh
```

It builds the binary to `~/.local/bin`, generates a token at
`~/.config/clipbridge/env` (mode 0600), starts the user service, runs
`tailscale serve --bg 8787`, links the plugin into
`~/.config/omarchy/plugins/`, and prints the exact Shortcut recipe with your
URL and token filled in.

To publish it instead, push to a public repo and anyone can run
`omarchy plugin add <url>` — though they'll still need to run `install.sh` for
the daemon half, since `omarchy plugin add` deliberately never executes
anything from a plugin.

## The API

| Method | Path           | Effect                                            |
| ------ | -------------- | ------------------------------------------------- |
| GET    | `/health`      | liveness, no auth                                 |
| GET    | `/clip`        | current clipboard as `text/plain`                 |
| POST   | `/clip`        | set the clipboard from the body                   |
| POST   | `/clip/secret` | set the clipboard, clear it after 30s             |

`GET /clip` returns 409 when the clipboard is empty, when it holds a
password-manager entry, or when it holds non-text content, so the Shortcut
shows you a real reason instead of silently pasting nothing. The read is
pinned to `text/plain`; without that, copying an image would stream PNG bytes
to the phone labelled as text.

## iPhone setup

Two Shortcuts, bound to Back Tap or the Action Button:

**Send to Mac** — Get Clipboard → Get Contents of URL (`POST /clip`, header
`Authorization: Bearer <token>`, body = clipboard text).

**Get from Mac** — Get Contents of URL (`GET /clip`, same header) → Copy to
Clipboard.

Then Settings → Apps → Shortcuts → **Paste from Other Apps → Allow**, or the
send shortcut prompts every single time. Note this applies to every shortcut,
not just these two.

For secrets, duplicate "Send to Mac" and point it at `/clip/secret`.

## Laptop keybinds

Quattro's Hyprland config is Lua now. In `~/.config/hypr/hyprland.lua`:

```lua
bind = {
  { "SUPER SHIFT", "V", "exec", "omarchy-shell clipbridge clear" },
  { "SUPER SHIFT", "R", "exec", "omarchy-shell clipbridge restart" },
}
```

The bar widget shows `↓` for an inbound clip, `↑` for outbound, `×` after a
secret self-clears, plus how long ago. Clicking it restarts the daemon, which
is the fix for the one failure mode you'll actually hit (see below). Secrets
render in the theme's urgent color.

## Security model

- The daemon binds `127.0.0.1` only. `tailscale serve` is what exposes it, so
  it's reachable from your tailnet and nowhere else, over WireGuard.
- Auth is a bearer token by default. The daemon **refuses to start** without
  either `CLIPBRIDGE_TOKEN` or `CLIPBRIDGE_ALLOWED_LOGINS` — since
  `tailscale serve` proxies from loopback, a source-address check would
  authenticate nothing.
- To drop the token and use Tailscale identity instead, set
  `CLIPBRIDGE_ALLOWED_LOGINS=you@example.com` in `~/.config/clipbridge/env` and
  remove `CLIPBRIDGE_TOKEN`. Two things to confirm before relying on this, not
  one: that your version sends a `Tailscale-User-Login` header at all, and
  that `tailscale serve` **strips a client-supplied one**. The daemon cannot
  tell an injected header from a real one — it sees only loopback. If serve
  passes a spoofed header through, any node on your tailnet can read your
  clipboard. Keeping the bearer token avoids the question entirely.
- Outbound clips carrying `x-kde-passwordManagerHint` are refused. 1Password,
  KeePassXC and Bitwarden all set it on Wayland.
- Nothing is logged. Request lines can carry query strings and systemd captures
  stderr into journald, so there's no request logging anywhere in the daemon.
  Don't add any.
- `status.json` holds a direction, a byte count and a timestamp — never
  contents.
- A token in a Shortcut is readable by anyone with your unlocked phone and it
  syncs through iCloud. Rotate by editing `~/.config/clipbridge/env` and
  restarting the service.

**Still not a password manager.** Quattro keeps clipboard history, so anything
POSTed to plain `/clip` lands on disk. `/clip/secret` clears after 30 seconds
but doesn't retroactively scrub history. For real credentials use the 1Password
or Bitwarden clients — they sync over their own encrypted channels and never
touch this.

## Troubleshooting

**Everything 500s after a reboot or relogin.** The user manager has a stale
`WAYLAND_DISPLAY`, so `wl-paste` can't reach the compositor. The daemon
detects this at startup and refuses to start rather than serving errors.

If you launch Hyprland through uwsm — which Omarchy does — the user manager
already has `WAYLAND_DISPLAY` and `graphical-session.target` is active, so
you are unlikely to hit this at all. Check with
`systemctl --user show-environment | grep WAYLAND` before assuming it. If it
really is missing:

```bash
systemctl --user import-environment WAYLAND_DISPLAY XDG_RUNTIME_DIR
systemctl --user restart clipbridge
```

**The clipboard empties when the service restarts.** The unit sets
`KillMode=process` precisely to prevent this — `wl-copy` forks a resident
process that owns the selection and lands in the unit's cgroup, so the default
`KillMode=control-group` would kill it on every restart. Don't remove that line.

**Shortcut fails with a TLS error.** The phone isn't on the tailnet. Check the
Tailscale app is connected, not just installed.

**Plugin won't load.** `omarchy plugin validate .` runs the same checks the
shell does at load time, and `journalctl --user -u omarchy-shell` has the QML
errors.

## A caveat on the QML

The daemon is tested. The two QML files are written against Quickshell's
documented types (`Process`, `StdioCollector`, `FileView`, `IpcHandler`) and
Omarchy's `qs.Commons` theme singletons (`Color`, `Style`), but Quattro is days
old and tracks `quickshell-git`. If a property name has moved, the pattern to
copy is in `$OMARCHY_PATH/shell/plugins/` — every first-party widget is right
there, and `omarchy plugin clone omarchy.clock` gives you a working one to diff
against. `Style.font.family` is the likeliest thing to differ; the widget
guards against it being undefined.

Editing the QML does **not** hot-reload when the plugin is installed as a
symlink, which is how `install.sh` installs it. Quickshell only watches its own
config root (`/usr/share/omarchy/shell`), and `omarchy-shell shell rescanPlugins`
re-reads the registry without clearing Qt's component cache — so the old QML
keeps running and you debug a file the shell isn't executing. After a QML edit:

```bash
omarchy-restart-shell
```
