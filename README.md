# Cliptail

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
manifest.json         plugin manifest (service + bar-widget)
Service.qml           headless service: health check, notifications, IPC verbs
Widget.qml            bar widget: one glyph, state by colour, detail on hover
cmd/cliptail/main.go  the daemon — all clipboard and network logic
systemd/              user unit
install.sh            builds or downloads, wires up systemd + tailscale serve, links the plugin
```

The split is deliberate. Plugins run as unsandboxed code inside the long-lived
`omarchy-shell` process, so an HTTP listener in there means a panic takes your
bar, notifications and lock screen with it. The daemon runs under systemd where
it can crash and restart on its own.

## Install

```bash
git clone https://github.com/brs98/omarchy-cliptail ~/src/omarchy-cliptail
cd ~/src/omarchy-cliptail
./install.sh
```

It builds the binary to `~/.local/bin`, generates a token at
`~/.config/cliptail/env` (mode 0600), starts the user service, runs
`tailscale serve --bg 8787`, links the plugin into
`~/.config/omarchy/plugins/`, and prints the exact Shortcut recipe with your
URL and token filled in.

### Installing as an Omarchy plugin

```bash
omarchy plugin add https://github.com/brs98/omarchy-cliptail
```

This clones into `~/.config/omarchy/plugins/brs98.cliptail/` and gets you the
bar widget and IPC verbs — **but not the daemon**, which is where all the actual
clipboard and network logic lives. Omarchy's installer never runs plugin code,
install hooks, or sudo; it only clones files, validates the manifest, and
toggles enabled state over IPC. So the widget alone will sit there reading
"down" forever.

You don't have to remember this: with the plugin enabled and no daemon, the bar
widget glyph turns urgent red and you get a notification naming the exact command.

Finish the job by running the installer from the cloned checkout:

```bash
~/.config/omarchy/plugins/brs98.cliptail/install.sh
```

It is idempotent — it detects the cloned plugin folder, skips the linking step,
and still enables the plugin and places the widget.

**Go is optional.** If Go is installed the daemon is built from source, which is
what you want for something that can read your clipboard. If it isn't, the
installer downloads the published binary for your architecture and verifies it
against the `SHA256SUMS` from the same release, refusing to install on a
mismatch. Install Go and re-run at any point to replace it with your own build.

### Bar widget states

One clipboard glyph in a fixed slot — no text label, so the bar never re-lays
out. State is carried by colour, detail by the tooltip:

| Colour | Meaning |
| ------ | ------- |
| foreground | idle, daemon healthy |
| accent | a clip moved in the last 8 seconds — the "it worked" signal |
| urgent | a secret is pending its self-clear, or the daemon is broken |

Hover for the rest: direction, byte count, relative age, and what the daemon
needs if it's unhappy (`stopped` says click to restart; `missing` names the
`install.sh` path). **Left-click restarts the daemon, middle-click clears the
clipboard.**

An earlier version printed the relative age next to the glyph. Don't: the label
changes width as it counts up, so every minute the whole bar shifted — and a
permanently-displayed "9m ago" is a fact you've already acted on. Omarchy's own
indicators use `fixedWidth` plus `keepSpace` for exactly this reason.

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

**Clip → Laptop** — Get Clipboard → Get Contents of URL (`POST /clip`, header
`Authorization: Bearer <token>`).

For the body, pick **File** — not JSON, not Form — and pass the Clipboard
variable. File is the only mode that sends a raw body; the daemon copies those
bytes verbatim, so JSON or Form mode puts a literal `{"text":"..."}` or
`text=hello+world` on your clipboard.

**Clip ← Laptop** — Get Contents of URL (`GET /clip`, same header) → Copy to
Clipboard.

On the Copy to Clipboard action, leave **Local Only** off and **Expire At**
empty for everyday use: Local Only off lets the clip reach your Mac and iPad
over Universal Clipboard for free, and Expire At is a hard deadline rather than
an idle timer, so it will drop the clip whether or not you've pasted yet.

Then Settings → Apps → Shortcuts → **Paste from Other Apps → Allow**, or the
send shortcut prompts every single time. Note this applies to every shortcut,
not just these two.

For secrets, duplicate "Clip → Laptop" and point it at `/clip/secret`. Worth
duplicating "Clip ← Laptop" too, with **Local Only on** and a short **Expire
At** — `/clip/secret` clears the *laptop* after 30s, but nothing clears the
phone. iOS won't let a third-party app clear the pasteboard in the background,
so those two toggles are the only phone-side control that exists.

## Laptop keybinds

Quattro's Hyprland config is Lua now, and Omarchy wraps binds in its own `o.bind`
helper rather than raw `bind = { ... }` tables. In `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + SHIFT + V", "Clear clipboard", "omarchy-shell cliptail clear")
```

Check for collisions before adding more — `SUPER + SHIFT + R` looks free but is a
common personal bind, and Omarchy already owns `SUPER + CTRL + V` (clipboard
manager), `SUPER + C/V/X` (universal copy/paste/cut) and `SUPER + SHIFT + RETURN`
(browser). List what is taken with:

```bash
grep -rhoE '"SUPER \+ [^"]+"' ~/.config/hypr/*.lua /usr/share/omarchy/default/hypr/bindings/*.lua | sort -u
```

A restart bind is usually unnecessary: clicking the bar widget restarts the
daemon, which is the fix for the one failure mode you'll actually hit.

The service exposes four IPC verbs:

```bash
omarchy-shell cliptail status    # up | stopped | missing | unknown
omarchy-shell cliptail check     # force a health probe, don't wait out the 30s poll
omarchy-shell cliptail clear     # wl-copy --clear
omarchy-shell cliptail restart   # systemctl --user restart cliptail.service
```

## Security model

- The daemon binds `127.0.0.1` only. `tailscale serve` is what exposes it, so
  it's reachable from your tailnet and nowhere else, over WireGuard.
- Auth is a bearer token by default. The daemon **refuses to start** without
  either `CLIPTAIL_TOKEN` or `CLIPTAIL_ALLOWED_LOGINS` — since
  `tailscale serve` proxies from loopback, a source-address check would
  authenticate nothing.
- To drop the token and use Tailscale identity instead, set
  `CLIPTAIL_ALLOWED_LOGINS=you@example.com` in `~/.config/cliptail/env` and
  remove `CLIPTAIL_TOKEN`. Two things to confirm before relying on this, not
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
  syncs through iCloud. Rotate by editing `~/.config/cliptail/env` and
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
systemctl --user restart cliptail
```

**The clipboard empties when the service restarts.** The unit sets
`KillMode=process` precisely to prevent this — `wl-copy` forks a resident
process that owns the selection and lands in the unit's cgroup, so the default
`KillMode=control-group` would kill it on every restart. Don't remove that line.

**Shortcut fails with a TLS error.** The phone isn't on the tailnet. Check the
Tailscale app is connected, not just installed.

**The Shortcut says `Copied.` but nothing pastes.** The push worked — you are
pasting the wrong selection. Check the daemon's own record first:

```bash
cat ~/.local/state/cliptail/status.json   # direction "in" + a fresh timestamp = it landed
wl-paste --no-newline                     # CLIPBOARD — what the daemon writes
wl-paste --primary --no-newline           # PRIMARY — a different buffer entirely
```

If `status.json` says `in` and `wl-paste` shows your text, the bridge is fine.
Wayland has two independent selections and the daemon only writes CLIPBOARD;
middle-click and several default terminal chords read PRIMARY.

Omarchy's `SUPER + V` is not a paste — `default/hypr/bindings/clipboard.lua`
synthesizes a chord and picks it from the window's `terminal` tag: tagged
windows get `Shift+Insert`, everything else gets `Ctrl+V`. Those Insert chords
only reach the CLIPBOARD because Omarchy ships a `foot.ini` that remaps them.
**Stock, every terminal sends `Shift+Insert` to PRIMARY** — WezTerm, Ghostty and
Alacritty all do — and Omarchy tags foot, ghostty, kitty and wezterm as
terminals while shipping that config only for foot. If your terminal isn't foot,
mirror foot's `[key-bindings]` block in its config:

```
clipboard-copy=Control+Insert Control+Shift+c XF86Copy
primary-paste=none
clipboard-paste=Shift+Insert Control+Shift+v XF86Paste
```

**Plugin won't load.** `omarchy plugin validate .` runs the same checks the
shell does at load time, and `journalctl --user -u omarchy-shell` has the QML
errors.

## Notes on the QML

Both entry points run against Omarchy Quattro and are exercised end to end:
service load, all four IPC verbs, and each daemon state. Two things that cost
real debugging time, in case you fork this:

**`Service.qml` must not be a `pragma Singleton`.** The shell loads service
plugins with `Qt.createComponent` followed by `createObject` (`shell.qml`,
`ensureService`), and a composite singleton is not creatable that way — you get
a null instance and no IPC verbs. First-party services under
`plugins/services/` are plain `Item`s for the same reason.

**`Color.bar` exposes `background`, `text` and `active` — there is no
`foreground`.** An undefined color binding renders without an obvious error.

The widget declares `property var service`, which the shell populates with the
matching service instance (`shell.qml`: `if ("service" in item) item.service =
shell.serviceFor(...)`). It still reads `status.json` directly and null-guards
`service`, so a service that fails to load degrades the widget rather than
breaking it.

Editing the QML does **not** hot-reload when the plugin is installed as a
symlink, which is how `install.sh` installs it. Quickshell only watches its own
config root (`/usr/share/omarchy/shell`), and `omarchy-shell shell rescanPlugins`
re-reads the registry without clearing Qt's component cache — so the old QML
keeps running and you debug a file the shell isn't executing. After a QML edit:

```bash
omarchy-restart-shell
```
