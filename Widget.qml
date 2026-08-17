// Cliptail bar widget.
//
// Deliberately self-contained: it reads the daemon's status file directly
// rather than importing the service singleton, so neither entry point can
// break the other. The daemon writes only a direction, a byte count and a
// timestamp — never clipboard contents.

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

Item {
    id: root

    implicitWidth: row.implicitWidth
    implicitHeight: Math.max(row.implicitHeight, Style.font.body)

    // Injected by the shell when the matching service entry is loaded (see
    // shell.qml: `if ("service" in item) item.service = shell.serviceFor(...)`).
    // Always null-guard it: the widget must still render if the service failed
    // to load, which is the whole reason it reads status.json directly below.
    property var service: null
    readonly property string daemonState: service ? service.daemonState : "unknown"

    property string direction: ""
    property int syncedAt: 0
    property int syncedBytes: 0
    property bool wasSecret: false
    property int now: Math.floor(Date.now() / 1000)

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
                root.direction = s.direction || "";
                root.syncedAt = s.at || 0;
                root.syncedBytes = s.bytes || 0;
                root.wasSecret = s.secret === true;
            } catch (e) {
                root.direction = "";
            }
        }
    }

    // Re-render the relative time once a minute; nothing here polls the daemon.
    Timer {
        interval: 60000
        running: true
        repeat: true
        onTriggered: root.now = Math.floor(Date.now() / 1000)
    }

    function glyph() {
        // Daemon trouble outranks sync history: a stale ↓ from an hour ago is
        // actively misleading when nothing can sync right now.
        if (root.daemonState === "missing")
            return "!";      // installed the plugin, never ran install.sh
        if (root.daemonState === "stopped")
            return "⚠";      // built, but the unit isn't running
        if (root.direction === "in")
            return "↓";      // phone -> laptop
        if (root.direction === "out")
            return "↑";      // laptop -> phone
        if (root.direction === "cleared")
            return "×";
        return "·";
    }

    function label() {
        if (root.daemonState === "missing")
            return "setup";
        if (root.daemonState === "stopped")
            return "down";
        return root.ago();
    }

    function ago() {
        if (root.syncedAt <= 0)
            return "";
        const secs = Math.max(0, root.now - root.syncedAt);
        if (secs < 60)
            return "now";
        if (secs < 3600)
            return Math.floor(secs / 60) + "m";
        if (secs < 86400)
            return Math.floor(secs / 3600) + "h";
        return Math.floor(secs / 86400) + "d";
    }

    Row {
        id: row
        anchors.centerIn: parent
        spacing: Style.spacing.controlGap

        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.glyph()
            color: (root.wasSecret || root.daemonState === "missing"
                    || root.daemonState === "stopped") ? Color.urgent : Color.bar.text
            font.family: Style.font.family !== undefined ? Style.font.family : undefined
            font.pixelSize: Style.font.icon
        }

        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.label()
            visible: text.length > 0
            color: Color.bar.text
            opacity: 0.75
            font.pixelSize: Style.font.caption
        }
    }

    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton
        cursorShape: Qt.PointingHandCursor
        onClicked: restart.running = true
    }

    Process {
        id: restart
        command: ["systemctl", "--user", "restart", "cliptail.service"]
    }
}
