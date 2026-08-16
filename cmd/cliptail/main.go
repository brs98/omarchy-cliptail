// cliptail is a localhost clipboard endpoint for Wayland, meant to be
// exposed to your tailnet — and only your tailnet — with `tailscale serve`.
//
//	GET  /health       liveness check, no auth
//	GET  /clip         current clipboard as text/plain
//	POST /clip         set the clipboard from the request body
//	POST /clip/secret  set the clipboard, then clear it after CLIPTAIL_SECRET_TTL
//
// At least one of CLIPTAIL_TOKEN or CLIPTAIL_ALLOWED_LOGINS must be set or
// the daemon refuses to start. `tailscale serve` proxies from loopback, so a
// source-address check would authenticate nothing.
package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

// Mime types marking a clip as belonging to a password manager. 1Password,
// KeePassXC and Bitwarden all set the KDE hint on Wayland.
var secretHints = []string{"x-kde-passwordmanagerhint", "application/x-secret"}

type config struct {
	port          int
	token         string
	allowedLogins map[string]bool
	maxBytes      int64
	secretTTL     time.Duration
	statusFile    string
}

type server struct {
	cfg config

	mu         sync.Mutex
	clearTimer *time.Timer
}

func main() {
	cfg, err := loadConfig()
	if err != nil {
		fmt.Fprintln(os.Stderr, "cliptail:", err)
		os.Exit(1)
	}
	if err := preflight(); err != nil {
		fmt.Fprintln(os.Stderr, "cliptail:", err)
		os.Exit(1)
	}
	if err := os.MkdirAll(filepath.Dir(cfg.statusFile), 0o700); err != nil {
		fmt.Fprintln(os.Stderr, "cliptail:", err)
		os.Exit(1)
	}

	s := &server{cfg: cfg}

	mux := http.NewServeMux()
	mux.HandleFunc("/health", s.handleHealth)
	mux.HandleFunc("/clip", s.handleClip)
	mux.HandleFunc("/clip/secret", s.handleClip)

	addr := net.JoinHostPort("127.0.0.1", strconv.Itoa(cfg.port))
	httpSrv := &http.Server{
		Addr:              addr,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      15 * time.Second,
		// No ErrorLog assignment and no request logging anywhere: request
		// lines can carry query strings, and systemd captures stderr into
		// journald. Keep clipboard traffic out of the log entirely.
	}

	go func() {
		fmt.Printf("cliptail listening on %s\n", addr)
		if err := httpSrv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			fmt.Fprintln(os.Stderr, "cliptail:", err)
			os.Exit(1)
		}
	}()

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	<-stop

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = httpSrv.Shutdown(ctx)
}

func loadConfig() (config, error) {
	cfg := config{
		port:          8787,
		maxBytes:      1 << 20,
		secretTTL:     30 * time.Second,
		allowedLogins: map[string]bool{},
	}

	if v := os.Getenv("CLIPTAIL_PORT"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil {
			return cfg, fmt.Errorf("CLIPTAIL_PORT is not a number: %q", v)
		}
		cfg.port = n
	}
	if v := os.Getenv("CLIPTAIL_MAX_BYTES"); v != "" {
		n, err := strconv.ParseInt(v, 10, 64)
		if err != nil {
			return cfg, fmt.Errorf("CLIPTAIL_MAX_BYTES is not a number: %q", v)
		}
		cfg.maxBytes = n
	}
	if v := os.Getenv("CLIPTAIL_SECRET_TTL"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil {
			return cfg, fmt.Errorf("CLIPTAIL_SECRET_TTL is not a number of seconds: %q", v)
		}
		cfg.secretTTL = time.Duration(n) * time.Second
	}

	cfg.token = strings.TrimSpace(os.Getenv("CLIPTAIL_TOKEN"))
	for _, l := range strings.Split(os.Getenv("CLIPTAIL_ALLOWED_LOGINS"), ",") {
		if l = strings.ToLower(strings.TrimSpace(l)); l != "" {
			cfg.allowedLogins[l] = true
		}
	}
	if cfg.token == "" && len(cfg.allowedLogins) == 0 {
		return cfg, fmt.Errorf("set CLIPTAIL_TOKEN or CLIPTAIL_ALLOWED_LOGINS before starting; run install.sh to generate a token")
	}

	stateHome := os.Getenv("XDG_STATE_HOME")
	if stateHome == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return cfg, err
		}
		stateHome = filepath.Join(home, ".local", "state")
	}
	cfg.statusFile = filepath.Join(stateHome, "cliptail", "status.json")

	return cfg, nil
}

func preflight() error {
	if os.Getenv("WAYLAND_DISPLAY") == "" {
		return fmt.Errorf("WAYLAND_DISPLAY is not set, so wl-paste cannot reach the compositor; run: systemctl --user import-environment WAYLAND_DISPLAY XDG_RUNTIME_DIR, then restart this service")
	}
	for _, tool := range []string{"wl-copy", "wl-paste"} {
		if _, err := exec.LookPath(tool); err != nil {
			return fmt.Errorf("%s not found; install wl-clipboard", tool)
		}
	}
	return nil
}

// --- clipboard -----------------------------------------------------------

// wlPaste returns the clipboard as text. The -t is not optional: without it
// wl-paste hands back whatever the preferred offer is, so copying an image
// would stream PNG bytes to the phone labelled text/plain.
func wlPaste() []byte {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "wl-paste", "--no-newline", "-t", "text/plain").Output()
	if err != nil {
		return nil // an empty clipboard, or one holding no text, exits non-zero
	}
	return out
}

func wlTypes() []string {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "wl-paste", "--list-types").Output()
	if err != nil {
		return nil
	}
	return strings.Fields(strings.ToLower(string(out)))
}

func wlCopy(data []byte) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "wl-copy")
	cmd.Stdin = bytes.NewReader(data)
	return cmd.Run()
}

func wlClear() {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = exec.CommandContext(ctx, "wl-copy", "--clear").Run()
}

func holdsSecret() bool {
	for _, t := range wlTypes() {
		for _, hint := range secretHints {
			if strings.Contains(t, hint) {
				return true
			}
		}
	}
	return false
}

// --- status --------------------------------------------------------------

type status struct {
	Direction string `json:"direction"` // "in" (phone -> laptop), "out", "cleared"
	At        int64  `json:"at"`
	Bytes     int    `json:"bytes"`
	Secret    bool   `json:"secret"`
}

// writeStatus records what just happened so the bar widget has something to
// show. It never records clipboard contents — only a size, direction and time.
func (s *server) writeStatus(direction string, size int, secret bool) {
	payload, err := json.Marshal(status{
		Direction: direction,
		At:        time.Now().Unix(),
		Bytes:     size,
		Secret:    secret,
	})
	if err != nil {
		return
	}
	tmp := s.cfg.statusFile + ".tmp"
	if err := os.WriteFile(tmp, payload, 0o600); err != nil {
		return
	}
	_ = os.Rename(tmp, s.cfg.statusFile)
}

// scheduleClear wipes the clipboard after the TTL, but only if it still holds
// the secret that was pushed.
func (s *server) scheduleClear(data []byte) {
	want := sha256.Sum256(data)

	s.mu.Lock()
	defer s.mu.Unlock()
	if s.clearTimer != nil {
		s.clearTimer.Stop()
	}
	s.clearTimer = time.AfterFunc(s.cfg.secretTTL, func() {
		if got := sha256.Sum256(wlPaste()); got == want {
			wlClear()
			s.writeStatus("cleared", 0, true)
		}
	})
}

// --- handlers ------------------------------------------------------------

func reply(w http.ResponseWriter, code int, body []byte) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Length", strconv.Itoa(len(body)))
	w.WriteHeader(code)
	_, _ = w.Write(body)
}

func (s *server) handleHealth(w http.ResponseWriter, r *http.Request) {
	reply(w, http.StatusOK, []byte("ok"))
}

func (s *server) authorized(r *http.Request) bool {
	if s.cfg.token != "" {
		auth := r.Header.Get("Authorization")
		if strings.HasPrefix(auth, "Bearer ") {
			got := strings.TrimSpace(strings.TrimPrefix(auth, "Bearer "))
			if subtle.ConstantTimeCompare([]byte(got), []byte(s.cfg.token)) == 1 {
				return true
			}
		}
	}
	if len(s.cfg.allowedLogins) > 0 {
		login := strings.ToLower(strings.TrimSpace(r.Header.Get("Tailscale-User-Login")))
		if login != "" && s.cfg.allowedLogins[login] {
			return true
		}
	}
	return false
}

func (s *server) handleClip(w http.ResponseWriter, r *http.Request) {
	if !s.authorized(r) {
		reply(w, http.StatusUnauthorized, []byte("Not authorized for this tailnet endpoint."))
		return
	}

	switch r.Method {
	case http.MethodGet:
		if r.URL.Path != "/clip" {
			reply(w, http.StatusMethodNotAllowed, []byte("Use POST for this endpoint."))
			return
		}
		s.sendClip(w)
	case http.MethodPost:
		s.receiveClip(w, r, r.URL.Path == "/clip/secret")
	default:
		reply(w, http.StatusMethodNotAllowed, []byte("Use GET or POST."))
	}
}

func (s *server) sendClip(w http.ResponseWriter) {
	if holdsSecret() {
		reply(w, http.StatusConflict, []byte("Clipboard holds a password-manager entry. Not sending."))
		return
	}
	data := wlPaste()
	if len(data) == 0 {
		// Distinguish "nothing copied" from "an image is on the clipboard",
		// so the Shortcut shows a reason that matches what you actually did.
		if len(wlTypes()) > 0 {
			reply(w, http.StatusConflict, []byte("Clipboard holds non-text content. Not sending."))
			return
		}
		reply(w, http.StatusConflict, []byte("Clipboard is empty."))
		return
	}
	s.writeStatus("out", len(data), false)
	reply(w, http.StatusOK, data)
}

func (s *server) receiveClip(w http.ResponseWriter, r *http.Request, secret bool) {
	data, err := io.ReadAll(io.LimitReader(r.Body, s.cfg.maxBytes+1))
	if err != nil {
		reply(w, http.StatusBadRequest, []byte("Could not read the request body."))
		return
	}
	if int64(len(data)) > s.cfg.maxBytes {
		reply(w, http.StatusRequestEntityTooLarge,
			[]byte(fmt.Sprintf("Body is larger than the %d byte limit.", s.cfg.maxBytes)))
		return
	}
	if len(data) == 0 {
		reply(w, http.StatusBadRequest, []byte("Send the text to copy as the request body."))
		return
	}

	if err := wlCopy(data); err != nil {
		reply(w, http.StatusInternalServerError, []byte("Could not reach the clipboard."))
		return
	}

	if secret {
		s.scheduleClear(data)
		s.writeStatus("in", len(data), true)
		reply(w, http.StatusOK, []byte(fmt.Sprintf("Copied. Clearing in %s.", s.cfg.secretTTL)))
		return
	}
	s.writeStatus("in", len(data), false)
	reply(w, http.StatusOK, []byte("Copied."))
}
