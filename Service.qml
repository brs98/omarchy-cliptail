// Clip Bridge service — headless. It owns none of the clipboard logic; that
// lives in the clipbridge daemon under systemd. This just watches whether the
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

    // --- health ---------------------------------------------------------

    Process {
        id: health
        command: [
            "curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
            "--max-time", "2",
            "http://127.0.0.1:" + root.port + "/health"
        ]
        stdout: StdioCollector {
            onStreamFinished: root.daemonUp = (text.trim() === "200")
        }
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
        command: ["systemctl", "--user", "restart", "clipbridge.service"]
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
        target: "clipbridge"

        // omarchy-shell clipbridge restart
        function restart(): string {
            restartProc.running = true;
            return "Restarting the clipbridge daemon.";
        }

        // omarchy-shell clipbridge clear
        function clear(): string {
            clearProc.running = true;
            return "Clipboard cleared.";
        }

        // omarchy-shell clipbridge status
        function status(): string {
            return root.daemonUp ? "up" : "down";
        }
    }
}
