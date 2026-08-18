// Cliptail service — headless. It owns none of the clipboard logic; that
// lives in the cliptail daemon under systemd. This just watches whether the
// daemon is alive and exposes IPC verbs so a Hyprland keybind can drive it.
//
// Not a Singleton: the shell loads service plugins with Qt.createComponent
// followed by createObject (see shell.qml, ensureService), and a composite
// singleton is not creatable that way. First-party services under
// plugins/services/ are plain Items for the same reason.

import QtQuick
import Quickshell
import Quickshell.Io

Item {
    id: root

    // Injected by the shell after createObject; see ensureService.
    property var shell: null
    property var manifest: null
    property string omarchyPath: Quickshell.env("OMARCHY_PATH")

    property bool daemonUp: false
    property int port: 8787

    // "unknown" until the first probe lands, then "missing" | "stopped" | "up".
    // The bar widget reads this to distinguish "you never installed the daemon"
    // from "the daemon crashed", which look identical from a failed health check.
    property string daemonState: "unknown"
    property bool binaryPresent: true
    property bool warned: false

    // The first probe races the daemon's bind at login. quickshell is launched
    // from Hyprland's exec-once and cliptail from graphical-session.target, and
    // nothing orders the two, so at boot this probe reliably lands in the
    // sub-second window before the daemon has bound its port. A single failure
    // therefore means "asked too early", not "dead" — only a run of them is
    // real. Without this the widget cried wolf on every cold boot.
    property int failures: 0
    readonly property int failuresBeforeDown: 3

    // --- health ---------------------------------------------------------

    Process {
        id: health
        command: [
            "curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
            "--max-time", "2",
            "http://127.0.0.1:" + root.port + "/health"
        ]
        stdout: StdioCollector {
            onStreamFinished: {
                root.daemonUp = (text.trim() === "200");
                if (root.daemonUp) {
                    root.failures = 0;
                    root.daemonState = "up";
                    root.warned = false;
                } else {
                    root.failures += 1;
                    probe.running = true;
                }
            }
        }
    }

    // `omarchy plugin add` installs this plugin but deliberately never runs
    // install.sh — Omarchy's installer executes no plugin code. So the common
    // first-run state is "widget present, daemon never built". Tell the user
    // that instead of showing a dead indicator forever.
    Process {
        id: probe
        command: ["sh", "-c", "command -v cliptail"]
        onExited: (exitCode) => {
            root.binaryPresent = (exitCode === 0);

            // A missing binary is not a race: nothing is going to bind the port
            // later, so report that on the first probe exactly as before.
            if (!root.binaryPresent) {
                root.daemonState = "missing";
            } else if (root.failures >= root.failuresBeforeDown) {
                root.daemonState = "stopped";
            } else {
                // Still inside the grace window. Leave daemonState on its last
                // honest reading and retry well before the 30s poll, so a real
                // outage still surfaces quickly.
                retryProbe.restart();
                return;
            }

            if (!root.warned) {
                root.warned = true;
                notify.running = true;
            }
        }
    }

    // Retry cadence while a failure is still unconfirmed. Three strikes at 2s
    // reports a genuinely dead daemon ~6s in, still well inside the 30s poll.
    Timer {
        id: retryProbe
        interval: 2000
        repeat: false
        onTriggered: health.running = true
    }

    Process {
        id: notify
        command: root.binaryPresent
            ? ["notify-send", "-a", "Cliptail", "-u", "normal",
               "Cliptail daemon is not running",
               "Start it with:\nsystemctl --user restart cliptail.service"]
            : ["notify-send", "-a", "Cliptail", "-u", "critical",
               "Cliptail daemon is not installed",
               "The plugin is only half of it — the daemon does the work.\n" +
               "Finish with:\n~/.config/omarchy/plugins/brs98.cliptail/install.sh"]
    }

    Timer {
        interval: 30000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: health.running = true
    }

    // --- actions --------------------------------------------------------

    Process {
        id: restartProc
        command: ["systemctl", "--user", "restart", "cliptail.service"]
        // `systemctl restart` returns before the daemon has rebound the port,
        // so probing immediately reads "down" and the widget stays wrong until
        // the next 30s poll. Give it a moment.
        onExited: recheck.restart()
    }

    Timer {
        id: recheck
        interval: 1500
        repeat: false
        onTriggered: health.running = true
    }

    Process {
        id: clearProc
        command: ["wl-copy", "--clear"]
    }

    IpcHandler {
        target: "cliptail"

        // omarchy-shell cliptail restart
        function restart(): string {
            // A deliberate restart earns a fresh grace window; otherwise stale
            // failures from the outage that prompted it fire the warning early.
            root.failures = 0;
            restartProc.running = true;
            return "Restarting the cliptail daemon.";
        }

        // omarchy-shell cliptail clear
        function clear(): string {
            clearProc.running = true;
            return "Clipboard cleared.";
        }

        // omarchy-shell cliptail status
        // "up" | "stopped" (built, unit not running) | "missing" (never
        // installed) | "unknown" (first probe hasn't landed yet)
        function status(): string {
            return root.daemonState;
        }

        // omarchy-shell cliptail check — force a probe instead of waiting out
        // the 30s poll. Useful right after starting or stopping the unit.
        function check(): string {
            health.running = true;
            return "Probing.";
        }
    }
}
