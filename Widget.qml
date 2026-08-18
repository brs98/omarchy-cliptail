// Cliptail bar widget.
//
// One fixed-width glyph, no text label. The earlier version printed a relative
// age next to the icon, which meant the bar re-laid-out every time "9m" became
// "10m", and it permanently displayed a fact you'd already acted on. Detail now
// lives in the tooltip; the icon only carries state, through colour:
//
//   default   idle, daemon healthy
//   accent    a clip moved in the last few seconds
//   urgent    a secret is pending its self-clear, or the daemon is broken
//
// Display-only: hover for detail, nothing to click. Restarting and clearing
// live where they're discoverable — the IPC verbs and a keybind — rather than
// behind an unlabelled icon whose two mouse buttons do different things.
//
// It reads the daemon's status.json directly and probes the daemon itself, so
// it stands alone: if the service entry point fails to load, the widget still
// works. The daemon writes only a direction, a byte count and a timestamp to
// that file — never clipboard contents.

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
    id: root
    moduleName: "brs98.cliptail"

    // The widget probes the daemon itself rather than reading it off the service
    // entry point. The shell only injects `service` into *panel* loaders
    // (shell.qml, panelLoader.onLoaded); the bar widget path in
    // plugins/bar/Bar.qml injects `settings` and nothing else, so a
    // `property var service` here would sit null forever and every state would
    // read as healthy. Probing also keeps the widget working when the service
    // fails to load, which is the point of it being self-contained.
    property int port: 8787
    property string daemonState: "unknown"
    readonly property bool broken: daemonState === "missing" || daemonState === "stopped"

    // Same startup race the service entry point guards against, and this copy is
    // the one you actually see: nothing orders quickshell's launch against
    // cliptail's, so the first probe at login lands before the daemon binds and
    // would paint the icon urgent-red for a daemon that is merely still starting.
    // Confirm a failure across several probes before believing it.
    property int failures: 0
    readonly property int failuresBeforeDown: 3

    Process {
        id: health
        command: [
            "curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
            "--max-time", "2",
            "http://127.0.0.1:" + root.port + "/health"
        ]
        stdout: StdioCollector {
            onStreamFinished: {
                if (text.trim() === "200") {
                    root.failures = 0;
                    root.daemonState = "up";
                } else {
                    root.failures += 1;
                    probe.running = true;   // distinguish "stopped" from "missing"
                }
            }
        }
    }

    Process {
        id: probe
        command: ["sh", "-c", "command -v cliptail"]
        onExited: (exitCode) => {
            // A missing binary is not a race — nothing will bind the port later.
            if (exitCode !== 0)
                root.daemonState = "missing";
            else if (root.failures >= root.failuresBeforeDown)
                root.daemonState = "stopped";
            else
                retryProbe.restart();   // still too early to call it
        }
    }

    Timer {
        id: retryProbe
        interval: 2000
        repeat: false
        onTriggered: health.running = true
    }

    Timer {
        interval: 30000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: health.running = true
    }

    property string direction: ""
    property int syncedAt: 0
    property int syncedBytes: 0
    property bool wasSecret: false

    // Ticks once a minute purely so the tooltip's relative age doesn't go stale
    // while hovering. The flash below is driven by a one-shot timer instead, so
    // there's no per-second ticker anywhere.
    property int now: Math.floor(Date.now() / 1000)
    property bool flashing: false

    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight

    readonly property string statePath: {
        const base = Quickshell.env("XDG_STATE_HOME")
            || (Quickshell.env("HOME") + "/.local/state");
        return base + "/cliptail/status.json";
    }

    FileView {
        id: statusFile
        path: root.statePath
        watchChanges: true
        onFileChanged: reload()
        onLoaded: {
            try {
                const s = JSON.parse(text());
                const at = s.at || 0;
                const isNew = at > root.syncedAt;
                root.direction = s.direction || "";
                root.syncedAt = at;
                root.syncedBytes = s.bytes || 0;
                root.wasSecret = s.secret === true;
                if (isNew) {
                    root.now = Math.floor(Date.now() / 1000);
                    root.flashing = true;
                    flash.restart();
                }
            } catch (e) {
                root.direction = "";
            }
        }
    }

    Timer {
        id: flash
        interval: 8000
        repeat: false
        onTriggered: root.flashing = false
    }

    Timer {
        interval: 60000
        running: true
        repeat: true
        onTriggered: root.now = Math.floor(Date.now() / 1000)
    }

    function ago() {
        if (root.syncedAt <= 0)
            return "";
        const secs = Math.max(0, root.now - root.syncedAt);
        if (secs < 60)
            return "just now";
        if (secs < 3600)
            return Math.floor(secs / 60) + "m ago";
        if (secs < 86400)
            return Math.floor(secs / 3600) + "h ago";
        return Math.floor(secs / 86400) + "d ago";
    }

    function tooltip() {
        if (root.daemonState === "missing")
            return "Cliptail daemon is not installed\n"
                 + "Run: ~/.config/omarchy/plugins/brs98.cliptail/install.sh";
        if (root.daemonState === "stopped")
            return "Cliptail daemon is not running\n"
                 + "Run: systemctl --user restart cliptail.service";

        var head;
        if (root.direction === "in")
            head = "Received from phone";
        else if (root.direction === "out")
            head = "Sent to phone";
        else if (root.direction === "cleared")
            head = "Secret cleared";
        else
            return "Cliptail — nothing synced yet";

        var line = head;
        if (root.wasSecret && root.direction !== "cleared")
            line += " (secret)";
        if (root.direction !== "cleared")
            line += "\n" + root.syncedBytes + " bytes · " + root.ago();
        else
            line += "\n" + root.ago();
        return line;
    }

    BarIconButton {
        id: button
        anchors.fill: parent
        bar: root.bar

        // Omarchy's own clipboard overlay uses this glyph, so it is known to
        // exist in the bar font. That plugin is an overlay rather than a bar
        // widget, so there's no icon collision on the bar itself.
        text: "󰅌"

        active: root.broken || root.flashing || root.wasSecret
        activeColor: root.broken || root.wasSecret ? Color.urgent : Color.accent
        tooltipText: root.tooltip()

        // Display-only: no click, no middle-click, no wheel. Note this is
        // `pressable`, not `interactive` — WidgetButton gates its MouseArea on
        // `interactive`, and a disabled MouseArea never emits onEntered, which
        // would take the tooltip with it. `pressable: false` drops the click
        // handler and reverts the cursor to an arrow, so it doesn't advertise
        // an action it no longer has.
        pressable: false
    }
}
