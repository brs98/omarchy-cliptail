#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT="${CLIPTAIL_PORT:-8787}"
BIN="$HOME/.local/bin/cliptail"
CONF_DIR="$HOME/.config/cliptail"
UNIT_DIR="$HOME/.config/systemd/user"
PLUGIN_DIR="$HOME/.config/omarchy/plugins/brs98.cliptail"

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
(cd "$REPO" && go build -trimpath -o "$BIN" ./cmd/cliptail)
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
CLIPTAIL_TOKEN=$TOKEN
CLIPTAIL_PORT=$PORT
CLIPTAIL_SECRET_TTL=30
CLIPTAIL_MAX_BYTES=1048576
EOF
  chmod 600 "$CONF_DIR/env"
  echo "  -> $CONF_DIR/env (0600)"
fi

# --- service -------------------------------------------------------------

say "Installing the user service"
mkdir -p "$UNIT_DIR"
install -m 644 "$REPO/systemd/cliptail.service" "$UNIT_DIR/cliptail.service"

# The user manager needs the compositor's environment or wl-paste has nothing
# to talk to.
systemctl --user import-environment WAYLAND_DISPLAY XDG_RUNTIME_DIR XDG_CURRENT_DESKTOP
systemctl --user daemon-reload
systemctl --user enable --now cliptail.service
sleep 1
systemctl --user is-active --quiet cliptail.service \
  || die "The service did not start. Check: journalctl --user -u cliptail -n 30"
echo "  -> cliptail.service is running"

# --- expose to the tailnet ----------------------------------------------

say "Exposing it to your tailnet"
tailscale serve --bg "$PORT" >/dev/null

# Ask for Self.DNSName directly. The obvious `grep -o '"DNSName":"..."' | head -1`
# fails twice over: `tailscale status --json` pretty-prints, so there is a space
# after the colon and the pattern never matches, and `head -1` closes the pipe
# early, so grep dies of SIGPIPE and `set -o pipefail` aborts the whole install.
HOSTNAME_TS="$(tailscale status --json --peers=false \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))' \
  2>/dev/null || true)"
[[ -n "$HOSTNAME_TS" ]] || HOSTNAME_TS="<your-machine>.<tailnet>.ts.net"
echo "  -> https://$HOSTNAME_TS/clip"

# --- plugin --------------------------------------------------------------

say "Installing the shell plugin"
mkdir -p "$(dirname "$PLUGIN_DIR")"
if [[ -e "$PLUGIN_DIR" && ! -L "$PLUGIN_DIR" ]]; then
  # `omarchy plugin add` already cloned us here as a real directory. Don't
  # link over a git checkout — but still fall through to enable/place below,
  # because plugins land disabled and the widget would never appear.
  echo "  $PLUGIN_DIR is a real directory (installed via 'omarchy plugin add'). Not linking."
else
  # Validate the source tree, not the link. The runtime is happy with a
  # symlinked plugin folder (omarchy-plugin-remove knows how to unlink one),
  # but omarchy-plugin-validate refuses to descend into a symlink.
  omarchy plugin validate "$REPO" || die "The plugin manifest did not validate."
  ln -sfn "$REPO" "$PLUGIN_DIR"
  echo "  -> linked $PLUGIN_DIR -> $REPO"
fi

# The running shell caches its plugin registry, so a freshly linked id is "not
# known" until it rescans and `omarchy plugin enable` refuses. There is no
# `omarchy plugin rescan`; the verb lives on the shell IPC target.
export OMARCHY_PATH="${OMARCHY_PATH:-/usr/share/omarchy}"
omarchy-shell -q shell rescanPlugins >/dev/null 2>&1 || true
sleep 1

# Enable and place the widget however the folder got there. Both are idempotent,
# and both fail loudly: a silently skipped enable leaves you with a working
# daemon, no widget, and an installer that claimed success.
omarchy plugin enable brs98.cliptail || die "omarchy plugin enable failed."
# 'omarchy bar put <id> [placement]' is the widget-placement verb; there is no
# 'bar plugin add'.
omarchy bar put brs98.cliptail right || die "omarchy bar put failed."
echo "  -> enabled and on the bar"

# --- what to do next -----------------------------------------------------

TOKEN_VALUE="$(grep '^CLIPTAIL_TOKEN=' "$CONF_DIR/env" | cut -d= -f2-)"

cat <<EOF

$(printf '\033[1mNow set up the iPhone side.\033[0m')

Base URL     https://$HOSTNAME_TS
Auth header  Authorization: Bearer $TOKEN_VALUE

Create two Shortcuts (Shortcuts app > + > add Get Contents of URL):

  Clip -> Laptop     Get Clipboard
                     Get Contents of URL
                       URL     https://$HOSTNAME_TS/clip
                       Method  POST
                       Headers Authorization: Bearer <token above>
                       Body    File  <- pick File, then the Clipboard variable.
                                        JSON/Form send key=value and you end up
                                        pasting a literal {"text":"..."}.

  Clip <- Laptop     Get Contents of URL
                       URL     https://$HOSTNAME_TS/clip
                       Method  GET
                       Headers Authorization: Bearer <token above>
                     Copy to Clipboard

Then: Settings > Apps > Shortcuts > Paste from Other Apps > Allow,
and bind each shortcut to Back Tap or the Action Button.

Test it from here first:
  curl -H "Authorization: Bearer \$CLIPTAIL_TOKEN" https://$HOSTNAME_TS/clip
EOF
