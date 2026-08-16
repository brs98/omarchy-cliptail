#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT="${CLIPBRIDGE_PORT:-8787}"
BIN="$HOME/.local/bin/clipbridge"
CONF_DIR="$HOME/.config/clipbridge"
UNIT_DIR="$HOME/.config/systemd/user"
PLUGIN_DIR="$HOME/.config/omarchy/plugins/you.clipbridge"

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
die() { printf '\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

# --- prerequisites -------------------------------------------------------

command -v go >/dev/null || die "Go is not installed. Run: sudo pacman -S go"
command -v wl-copy >/dev/null || die "wl-clipboard is not installed. Run: sudo pacman -S wl-clipboard"
command -v tailscale >/dev/null || die "Tailscale is not installed. Run: sudo pacman -S tailscale"
tailscale status >/dev/null 2>&1 || die "Tailscale is installed but not connected. Run: sudo tailscale up"

# --- build ---------------------------------------------------------------

say "Building the daemon"
mkdir -p "$HOME/.local/bin"
(cd "$REPO" && go build -trimpath -o "$BIN" ./cmd/clipbridge)
echo "  -> $BIN"

# --- token ---------------------------------------------------------------

mkdir -p "$CONF_DIR"
chmod 700 "$CONF_DIR"
if [[ -f "$CONF_DIR/env" ]]; then
  say "Keeping the existing token in $CONF_DIR/env"
else
  say "Generating a token"
  TOKEN="$(head -c 32 /dev/urandom | base64 | tr -d '/+=' | head -c 40)"
  cat > "$CONF_DIR/env" <<EOF
CLIPBRIDGE_TOKEN=$TOKEN
CLIPBRIDGE_PORT=$PORT
CLIPBRIDGE_SECRET_TTL=30
CLIPBRIDGE_MAX_BYTES=1048576
EOF
  chmod 600 "$CONF_DIR/env"
  echo "  -> $CONF_DIR/env (0600)"
fi

# --- service -------------------------------------------------------------

say "Installing the user service"
mkdir -p "$UNIT_DIR"
install -m 644 "$REPO/systemd/clipbridge.service" "$UNIT_DIR/clipbridge.service"

# The user manager needs the compositor's environment or wl-paste has nothing
# to talk to.
systemctl --user import-environment WAYLAND_DISPLAY XDG_RUNTIME_DIR XDG_CURRENT_DESKTOP
systemctl --user daemon-reload
systemctl --user enable --now clipbridge.service
sleep 1
systemctl --user is-active --quiet clipbridge.service \
  || die "The service did not start. Check: journalctl --user -u clipbridge -n 30"
echo "  -> clipbridge.service is running"

# --- expose to the tailnet ----------------------------------------------

say "Exposing it to your tailnet"
tailscale serve --bg "$PORT" >/dev/null
HOSTNAME_TS="$(tailscale status --json | grep -o '"DNSName":"[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/\.$//')"
[[ -n "$HOSTNAME_TS" ]] || HOSTNAME_TS="<your-machine>.<tailnet>.ts.net"
echo "  -> https://$HOSTNAME_TS/clip"

# --- plugin --------------------------------------------------------------

say "Installing the shell plugin"
mkdir -p "$(dirname "$PLUGIN_DIR")"
if [[ -e "$PLUGIN_DIR" && ! -L "$PLUGIN_DIR" ]]; then
  echo "  $PLUGIN_DIR already exists and is not a symlink. Leaving it alone."
else
  ln -sfn "$REPO" "$PLUGIN_DIR"

  # Fail loudly here. A silently skipped enable leaves you with a working
  # daemon, no widget, and an installer that claimed success.
  omarchy plugin validate "$PLUGIN_DIR" || die "The plugin manifest did not validate."
  omarchy plugin enable you.clipbridge || die "omarchy plugin enable failed."
  # 'omarchy bar put <id> [placement]' is the widget-placement verb; there is
  # no 'bar plugin add'. Placement is idempotent, so a re-run is harmless.
  omarchy bar put you.clipbridge right || die "omarchy bar put failed."
  echo "  -> linked, enabled and added to the bar"
fi

# --- what to do next -----------------------------------------------------

TOKEN_VALUE="$(grep '^CLIPBRIDGE_TOKEN=' "$CONF_DIR/env" | cut -d= -f2-)"

cat <<EOF

$(printf '\033[1mNow set up the iPhone side.\033[0m')

Base URL     https://$HOSTNAME_TS
Auth header  Authorization: Bearer $TOKEN_VALUE

Create two Shortcuts (Shortcuts app > + > add Get Contents of URL):

  Send to Mac        Get Clipboard
                     Get Contents of URL
                       URL     https://$HOSTNAME_TS/clip
                       Method  POST
                       Headers Authorization: Bearer <token above>
                       Body    Request Body -> Text -> Clipboard

  Get from Mac       Get Contents of URL
                       URL     https://$HOSTNAME_TS/clip
                       Method  GET
                       Headers Authorization: Bearer <token above>
                     Copy to Clipboard

Then: Settings > Apps > Shortcuts > Paste from Other Apps > Allow,
and bind each shortcut to Back Tap or the Action Button.

Test it from here first:
  curl -H "Authorization: Bearer \$CLIPBRIDGE_TOKEN" https://$HOSTNAME_TS/clip
EOF
