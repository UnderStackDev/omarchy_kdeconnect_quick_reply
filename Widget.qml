// Quick Reply — a separate reply channel for repliable phone notifications
// relayed by KDE Connect.
//
// KDE Connect mirrors phone notifications onto the freedesktop bus like any
// other app, and that is all the notification spec can carry. It also keeps
// one object per notification on its own bus with the part the spec has no
// room for: a replyId and a sendReply method that puts text back into the
// conversation on the phone. This widget reads that side directly and offers
// a reply field. It does not own org.freedesktop.Notifications, does not
// compete with omarchy.notifications or omapager, and changes nothing about
// how normal notifications are shown — it is a second reader of the same
// source for one purpose.
//
// The difference from the general case: KDE Connect marks a LOT of apps
// repliable (X, Claude, ...) where a reply string goes nowhere useful. There
// is no per-notification config surface in a bar widget, so the gate is a
// plain app whitelist (`apps` in the widget's shell.json entry). Only a
// notification whose appName matches the list ever produces the bar icon.
//
// Bar convention, borrowed from Omarchy's own status glyphs: the icon exists
// only while there is something to act on. Nothing waiting -> no icon.

import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "io.github.understackdev.quick-reply"

  // ------------------------------------------------------------- settings
  // Comma-separated phone-app names. Case-insensitive, partial match both
  // ways. This default is the gate the plugin exists for — KDE Connect marks
  // X, Claude, RainViewer, ... repliable too. Set "apps": "" in shell.json to
  // turn the gate off and allow every repliable app.
  readonly property string defaultApps: "WhatsApp, Messenger, Signal, Telegram, Messages, Viestit, SMS, Instagram, Element, Google Messages, Samsung Messages"
  readonly property var whitelist: {
    return String(setting("apps", defaultApps)).split(",").map(function (s) {
      return s.toLowerCase().replace(/\s+/g, " ").trim()
    }).filter(function (s) { return s.length > 0 })
  }
  readonly property bool dismissAfterReply: setting("dismissAfterReply", true) !== false
  readonly property bool alwaysShow: setting("alwaysShow", false) === true

  function allowed(appName) {
    if (whitelist.length === 0)
      return true
    var a = String(appName || "").toLowerCase().replace(/\s+/g, " ").trim()
    if (a.length === 0)
      return false
    for (var i = 0; i < whitelist.length; i++) {
      var w = whitelist[i]
      if (a === w || a.indexOf(w) >= 0 || w.indexOf(a) >= 0)
        return true
    }
    return false
  }

  onSettingsChanged: root._refilter()

  // ------------------------------------------------------------- engine
  readonly property string helper: Qt.resolvedUrl("bin/qr-kdeconnect")
                                     .toString().replace(/^file:\/\//, "")

  // Everything KDE Connect reports as repliable, before the whitelist.
  property var _rawAll: []
  // Object paths acknowledged from here (replied, or the corner ✕) — dropped
  // from view straight away and kept out until KDE Connect's own list loses
  // them, so a message that is not `dismissable` still clears from the panel.
  property var _dismissed: ({})
  // Some apps (WhatsApp observed) answer sendReply by posting a brand-new
  // notification that just echoes the text back — a different object path,
  // so `dismiss`-by-path on the original doesn't catch it, and it would
  // otherwise reappear as a second "message waiting" needing its own ✕. Each
  // successful send is remembered here for a short window so _refilter can
  // recognise and silently swallow that echo instead of surfacing it.
  property var _recentSent: []
  readonly property int echoWindowMs: 8000
  // What the widget renders: _rawAll minus the whitelist and _dismissed.
  property var pending: []
  readonly property int count: pending.length
  readonly property bool hasPending: count > 0
  property bool sending: false
  property bool available: true
  property string errorText: ""

  function refresh() {
    if (!scanProc.running)
      scanProc.running = true
  }

  function _applyScan(text) {
    var all = []
    try {
      all = JSON.parse(String(text || "[]"))
    } catch (e) {
      all = []
    }
    _rawAll = Array.isArray(all) ? all : []
    _refilter()
  }

  // Prunes expired sent-text entries and reports whether `e` looks like the
  // phone's echo of one of them (same app, body matches the text we just
  // sent). Returns the matching index into `recent`, or -1.
  function _matchEcho(e, recent) {
    var app = String(e.appName || "").toLowerCase().replace(/\s+/g, " ").trim()
    var body = String(e.body || "").trim()
    if (body.length === 0)
      return -1
    for (var i = 0; i < recent.length; i++) {
      var r = recent[i]
      if (r.app !== app || r.text.length === 0)
        continue
      if (body === r.text || body.indexOf(r.text) >= 0 || r.text.indexOf(body) >= 0)
        return i
    }
    return -1
  }

  function _refilter() {
    var now = Date.now()
    var recent = root._recentSent.filter(function (r) { return (now - r.ts) < root.echoWindowMs })

    var out = []
    var seen = {}
    var d = root._dismissed
    var dChanged = false
    var echoPaths = []
    for (var i = 0; i < _rawAll.length; i++) {
      var e = _rawAll[i]
      var p = String(e.path)
      seen[p] = true
      if (d[p])
        continue
      if (!root.allowed(e.appName))
        continue
      var echoIdx = root._matchEcho(e, recent)
      if (echoIdx >= 0) {
        // The phone's own echo of a reply we just sent — acknowledge it
        // silently rather than showing it as a new message. Consume the
        // matched sent-text so it can only swallow one echo.
        recent.splice(echoIdx, 1)
        d[p] = true
        dChanged = true
        echoPaths.push(p)
        continue
      }
      out.push(e)
    }
    // Drop sticky dismissals once the message is gone from KDE Connect too.
    for (var pth in d) {
      if (!seen[pth]) { delete d[pth]; dChanged = true }
    }
    if (dChanged)
      root._dismissed = d
    root._recentSent = recent
    pending = out

    if (echoPaths.length > 0) {
      var q = root._dismissQueue.slice()
      for (var k = 0; k < echoPaths.length; k++) q.push(echoPaths[k])
      root._dismissQueue = q
      root._pumpDismiss()
    }
  }

  function _noteSent(entry, text) {
    var t = String(text || "").trim()
    if (t.length === 0 || !entry)
      return
    var r = root._recentSent.slice()
    r.push({ app: String(entry.appName || "").toLowerCase().replace(/\s+/g, " ").trim(), text: t, ts: Date.now() })
    root._recentSent = r
  }

  // Acknowledge a message without answering it: drop it from view now, and
  // queue a best-effort dismiss() so it clears on the phone too.
  property var _dismissQueue: []

  function dismiss(entry) {
    if (!entry || !entry.path)
      return
    var d = root._dismissed
    d[String(entry.path)] = true
    root._dismissed = d
    root._refilter()
    var q = root._dismissQueue.slice()
    q.push(String(entry.path))
    root._dismissQueue = q
    root._pumpDismiss()
  }

  function _pumpDismiss() {
    if (dismissProc.running || root._dismissQueue.length === 0)
      return
    var q = root._dismissQueue.slice()
    var path = q.shift()
    root._dismissQueue = q
    dismissProc.command = [root.helper, "dismiss", path]
    dismissProc.running = true
  }

  function sendReply(entry, message) {
    if (!entry || sending)
      return
    var text = String(message || "")
    if (text.trim().length === 0)
      return
    sending = true
    errorText = ""
    replyProc.entry = entry
    replyProc.sentText = text
    // The message text goes to the helper over stdin, never as an argv element
    // (argv is world-readable via /proc/<pid>/cmdline). argv carries only the
    // verb and the notification's object path.
    replyProc.payload = text
    replyProc.command = [root.helper, "reply", String(entry.path)]
    replyProc.stdinEnabled = true   // re-armed for each reply
    replyProc.running = true
  }

  Process {
    id: scanProc
    command: ["timeout", "-k", "2", "12", root.helper, "list"]
    stdout: StdioCollector { id: scanOut }
    onExited: function (code) {
      root.available = (code === 0)
      root._applyScan(scanOut.text)
    }
  }

  Process {
    id: replyProc
    property var entry: null
    property string payload: ""
    property string sentText: ""
    stdinEnabled: true
    stdout: StdioCollector { id: replyOut }
    stderr: StdioCollector { id: replyErr }
    onStarted: {
      replyProc.write(replyProc.payload)
      replyProc.payload = ""
      // Closing stdin is how Quickshell sends EOF, which is what lets the
      // helper's bounded read() return.
      replyProc.stdinEnabled = false
    }
    onExited: function (code) {
      root.sending = false
      var e = replyProc.entry
      var sentText = replyProc.sentText
      replyProc.entry = null
      replyProc.sentText = ""
      if (code === 0) {
        // Some apps (WhatsApp) answer a sent reply with a fresh echo
        // notification of their own — remember what we sent so _refilter
        // can recognise and swallow it instead of showing it as new.
        root._noteSent(e, sentText)
        // Answered is dealt with: drop it from view now, and (when it is
        // dismissable and the setting is on) clear it on the phone too. Both
        // go through dismiss(), which is the same path the corner ✕ uses.
        if (e && e.path) {
          if (root.dismissAfterReply && e.dismissable) {
            root.dismiss(e)
          } else {
            var d = root._dismissed
            d[String(e.path)] = true
            root._dismissed = d
            root._refilter()
          }
        }
        root.errorText = ""
        Qt.callLater(root.refresh)
      } else {
        root.errorText = replyErr.text.trim() || ("Reply failed (" + code + ")")
      }
    }
  }

  Process {
    id: dismissProc
    onExited: {
      if (root._dismissQueue.length > 0)
        Qt.callLater(root._pumpDismiss)
      else
        Qt.callLater(root.refresh)
    }
  }

  // Live wake-up: any signal on KDE Connect's notifications interface ->
  // debounced rescan. The signal is not parsed; its arrival is the trigger.
  Process {
    id: monitorProc
    running: true
    command: ["busctl", "--user", "monitor", "--json=short", "--match",
              "type='signal',interface='org.kde.kdeconnect.device.notifications'"]
    stdout: SplitParser {
      splitMarker: "\n"
      onRead: function (line) {
        if (String(line).trim().length > 0)
          debounce.restart()
      }
    }
    onExited: monitorRestart.restart()
  }

  Timer {
    id: monitorRestart
    interval: 3000
    onTriggered: if (!monitorProc.running) monitorProc.running = true
  }

  Timer {
    id: debounce
    interval: 300
    onTriggered: root.refresh()
  }

  // Backstop in case the monitor stream misses an event.
  Timer {
    interval: 15000
    repeat: true
    running: true
    onTriggered: root.refresh()
  }

  Component.onCompleted: root.refresh()

  // ------------------------------------------------------------- IPC
  // omarchy-shell io.github.understackdev.quick-reply toggle|open|close|count|list|dismiss|dismissAll
  IpcHandler {
    target: "io.github.understackdev.quick-reply"
    function toggle(): string { root.togglePanel(); return controller.open ? "open" : "closed" }
    function open(): string { root.open(); return "open" }
    function close(): string { root.close(); return "closed" }
    function count(): string { return String(root.count) }
    function list(): string {
      return JSON.stringify(root.pending.map(function (e) {
        return { app: e.appName, from: e.title, body: e.body }
      }))
    }
    // Acknowledge the newest waiting message without replying, or all of them.
    function dismiss(): string {
      if (root.pending.length === 0) return "nothing waiting"
      var e = root.pending[0]
      root.dismiss(e)
      return "dismissed " + String(e.appName || "")
    }
    function dismissAll(): string {
      var n = root.pending.length
      var copy = root.pending.slice()
      for (var i = 0; i < copy.length; i++) root.dismiss(copy[i])
      return "dismissed " + n
    }
  }

  // ------------------------------------------------------------- panel state
  PanelController { id: controller }
  readonly property bool opened: controller.open

  function open() { controller.show() }
  function close() { controller.hide() }
  function toggle() { togglePanel() }
  function togglePanel() { controller.open ? controller.hide() : controller.show() }

  onOpenedChanged: {
    if (opened) {
      root.refresh()
      focusTimer.restart()
    } else {
      root.errorText = ""
    }
  }

  Timer {
    id: focusTimer
    interval: 180
    onTriggered: {
      if (rows.count > 0) {
        var it = rows.itemAt(0)
        if (it && it.focusField)
          it.focusField()
      }
    }
  }

  // ------------------------------------------------------------- the bar
  //
  // Collapsed to zero width when there is nothing waiting — an empty slot is
  // still a gap. Revealed while a message is waiting, while the panel is open,
  // and on the same bar-centre hover that reveals Omarchy's own inactive
  // indicators, so there is a way to open it even when nothing is waiting.
  readonly property bool revealed: hasPending || opened || alwaysShow
    || (bar && bar.centerSectionRevealHeld === true && bar.centerHoverRevealSuppressed !== true)

  clip: true
  implicitWidth: vertical ? Math.max(glyphs.implicitWidth, barSize)
                          : (revealed ? glyphs.implicitWidth : 0)
  implicitHeight: vertical ? (revealed ? glyphs.implicitHeight : 0)
                           : Math.max(glyphs.implicitHeight, barSize)

  Item {
    id: glyphs
    anchors.centerIn: parent
    implicitWidth: indicator.implicitWidth
    implicitHeight: indicator.implicitHeight

    // Lucide "message-circle" — a round chat bubble, drawn from its own path
    // rather than a font glyph so the published icon is exact. Accent while a
    // message is waiting; dimmed in the resting state that only shows on the
    // bar-centre reveal.
    Indicator {
      id: indicator
      iconComponent: messageIcon
      quiet: !root.hasPending
      tooltipText: root.hasPending
        ? (root.count === 1 ? "1 message waiting — click to reply"
                            : (root.count + " messages waiting — click to reply"))
        : "Quick reply — nothing waiting"
      onPressed: function (buttonCode) { root.togglePanel() }
    }

    // Count badge, only once there is more than one. Accent, not an alarm.
    Rectangle {
      visible: root.count > 1
      anchors.top: parent.top
      anchors.right: parent.right
      anchors.topMargin: -1
      anchors.rightMargin: -1
      width: 13
      height: 13
      radius: 6.5
      color: Color.accent

      Text {
        anchors.centerIn: parent
        text: root.count > 9 ? "9+" : String(root.count)
        color: Color.background
        font.family: Style.font.family
        font.pixelSize: 8
        font.bold: true
      }
    }
  }

  component Indicator: BarIconButton {
    property bool quiet: false
    property color colour: Color.foreground
    bar: root.bar
    foreground: colour
    fontSize: Style.font.caption
    horizontalMargin: 5
    verticalPadding: 5
    fixedWidth: root.vertical ? -1 : Style.bar.statusSlot
    fixedHeight: root.vertical ? Style.bar.statusSlot : -1
    useActiveColor: false
    dimmed: quiet
  }

  // Lucide "message-circle", stroked from its 24×24 path. Kept as a Component
  // so BarIconButton mounts one per bar surface.
  Component {
    id: messageIcon

    Item {
      id: iconRoot
      anchors.fill: parent
      readonly property color col: root.hasPending ? Color.accent : Color.foreground
      readonly property real draw: Math.min(width, height)
      opacity: root.hasPending ? 1.0 : 0.5

      Shape {
        anchors.centerIn: parent
        width: 24
        height: 24
        scale: iconRoot.draw / 24
        antialiasing: true
        preferredRendererType: Shape.CurveRenderer

        ShapePath {
          strokeColor: iconRoot.col
          // Lucide's own weight is 2; a touch heavier so the stroked bubble
          // carries the same visual density as the bar's Nerd Font glyphs.
          strokeWidth: 2.75
          fillColor: "transparent"
          capStyle: ShapePath.RoundCap
          joinStyle: ShapePath.RoundJoin
          PathSvg {
            path: "M2.992 16.342a2 2 0 0 1 .094 1.167l-1.065 3.29a1 1 0 0 0 1.236 1.168l3.413-.998a2 2 0 0 1 1.099.092 10 10 0 1 0-4.777-4.719"
          }
        }
      }
    }
  }

  // The reply box. qs.Ui only ships a single-line TextField, which is no
  // good here — before sending you should be able to see the whole message,
  // not a caret scrolling through one line. Same border/fill styling as
  // Ui/TextField.qml, but wraps and grows with its content (Controls size
  // themselves to implicitHeight when height isn't set, so nothing else
  // needs to be told to grow — the card, the card list and its Flickable
  // above all just follow). Enter still sends, like the field it replaces;
  // Shift+Enter (or Ctrl+Enter) inserts a newline instead of sending.
  component ReplyArea: TextArea {
    id: ta
    signal accepted()

    property color foreground: Color.foreground
    property color accent: Color.accent
    property color selectionTint: Style.selectionFillFor(foreground, accent)
    property real horizontalPadding: Style.spacing.controlPaddingX
    property real verticalPadding: Style.spacing.inputPaddingY

    readonly property bool _focused: activeFocus
    readonly property bool _hot: hovered
    readonly property var _borderSpec: Border.controlSpec(_focused ? "focus" : (_hot ? "hover-cursor" : "normal"), ta.foreground, ta.accent)

    wrapMode: TextArea.Wrap
    font.family: Style.font.family
    font.pixelSize: Style.font.body
    color: foreground
    selectionColor: selectionTint
    selectedTextColor: foreground
    placeholderTextColor: Qt.darker(foreground, 1.6)

    leftPadding: horizontalPadding + Border.left(_borderSpec)
    rightPadding: horizontalPadding + Border.right(_borderSpec)
    topPadding: verticalPadding + Border.top(_borderSpec)
    bottomPadding: verticalPadding + Border.bottom(_borderSpec)

    background: BorderSurface {
      color: Style.controlFill(ta._focused, ta._hot, ta.foreground, ta.accent)
      borderSpec: ta._borderSpec
      radius: Style.cornerRadius
    }

    Keys.onPressed: function (event) {
      if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
          && !(event.modifiers & (Qt.ShiftModifier | Qt.ControlModifier))) {
        event.accepted = true
        ta.accepted()
      }
    }
  }

  // A round sender photo from KDE Connect's per-notification icon, with a
  // monogram fallback until (or unless) it loads. Rounding is Omarchy's own
  // image-mask pattern (see plugins/image-picker).
  component Avatar: Item {
    id: av
    property string source: ""
    property string monogram: "?"

    readonly property string _letter: {
      var m = String(av.monogram || "").trim()
      return m.length > 0 ? m.charAt(0).toUpperCase() : "?"
    }
    readonly property bool _ready: av.source.length > 0 && avImg.status === Image.Ready

    Rectangle {
      anchors.fill: parent
      radius: width / 2
      visible: !av._ready
      color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.18)

      Text {
        anchors.centerIn: parent
        text: av._letter
        color: Color.accent
        font.family: Style.font.family
        font.pixelSize: Math.round(parent.height * 0.44)
        font.bold: true
      }
    }

    Item {
      anchors.fill: parent
      visible: av._ready
      layer.enabled: true
      layer.smooth: true
      layer.effect: MultiEffect {
        maskEnabled: true
        maskSource: avMask
        maskThresholdMin: 0.5
        maskSpreadAtMin: 0.35
      }

      Image {
        id: avImg
        anchors.fill: parent
        source: av.source
        fillMode: Image.PreserveAspectCrop
        cache: true
        asynchronous: true
        smooth: true
        sourceSize.width: Math.round(width * Screen.devicePixelRatio)
        sourceSize.height: Math.round(height * Screen.devicePixelRatio)
      }
    }

    Item {
      id: avMask
      anchors.fill: parent
      visible: false
      layer.enabled: true
      Rectangle { anchors.fill: parent; radius: width / 2; color: "white" }
    }
  }

  // ------------------------------------------------------------- the panel
  //
  // This widget does one thing, so the panel gives it room. The vocabulary is
  // Omarchy's own weather panel: a wide surface, tracked uppercase labels in a
  // dimmed foreground, a hairline rule, and generous space between everything.
  KeyboardPanel {
    id: panel
    anchorItem: glyphs
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyGate
    padding: Style.space(24)
    contentWidth: panel.fittedContentWidth(Style.space(460))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(640))

    // Popup palette, with the two dim steps the weather panel uses for
    // secondary and tertiary text.
    readonly property color fg: Color.popups.text
    readonly property color fgMuted: Qt.darker(fg, 1.4)
    readonly property color fgFaint: Qt.darker(fg, 1.6)
    readonly property color hairline: Qt.rgba(fg.r, fg.g, fg.b, 0.12)
    readonly property color cardFill: Qt.rgba(fg.r, fg.g, fg.b, 0.05)

    // Holds keyboard focus for the panel before a reply field takes it, and
    // gives Esc somewhere to land when no field is focused.
    Item {
      id: keyGate
      Keys.onEscapePressed: root.close()
    }

    Column {
      id: column
      width: parent.width
      spacing: Style.space(22)

      // ---- Header: a tracked label over a plain-language status line.
      Column {
        width: parent.width
        spacing: Style.space(7)

        Text {
          text: "QUICK REPLY"
          color: panel.fgFaint
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          font.letterSpacing: 2
        }

        Text {
          width: parent.width
          text: {
            if (!root.available)
              return "KDE Connect not reachable"
            if (root.count === 0)
              return "Nothing waiting"
            return root.count === 1 ? "1 message waiting"
                                    : (root.count + " messages waiting")
          }
          color: root.available ? panel.fgMuted : Color.urgent
          font.family: Style.font.family
          font.pixelSize: Style.font.title
          wrapMode: Text.WordWrap
        }
      }

      // ---- Rule.
      Rectangle {
        width: parent.width
        height: Style.spacing.hairline
        color: panel.hairline
      }

      // ---- Send error, when the last reply did not go through.
      Rectangle {
        visible: root.errorText.length > 0
        width: parent.width
        radius: Math.max(Style.cornerRadius, Style.space(8))
        color: Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, 0.12)
        implicitHeight: errText.implicitHeight + Style.space(24)

        Text {
          id: errText
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          anchors.leftMargin: Style.space(16)
          anchors.rightMargin: Style.space(16)
          text: root.errorText
          color: Color.urgent
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }
      }

      // ---- Waiting messages.
      Flickable {
        visible: root.count > 0
        width: parent.width
        contentWidth: width
        contentHeight: cards.implicitHeight
        height: Math.min(cards.implicitHeight, Style.space(452))
        clip: true
        interactive: cards.implicitHeight > height
        boundsBehavior: Flickable.StopAtBounds

        Column {
          id: cards
          width: parent.width
          spacing: Style.space(14)

          Repeater {
            id: rows
            model: root.pending

            delegate: Rectangle {
              id: mrow
              required property var modelData
              required property int index

              function focusField() { field.forceActiveFocus() }
              function send() {
                var t = field.text.trim()
                if (t.length === 0 || root.sending)
                  return
                root.sendReply(mrow.modelData, t)
                field.text = ""
              }

              width: cards.width
              radius: Math.max(Style.cornerRadius, Style.space(12))
              color: panel.cardFill
              border.width: 1
              border.color: field.activeFocus ? Color.accent : panel.hairline
              implicitHeight: inner.implicitHeight + Style.space(40)

              Column {
                id: inner
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(20)
                anchors.rightMargin: Style.space(20)
                spacing: Style.space(14)

                // Header: sender photo, the app (tracked/dim) over the sender
                // name, and a corner ✕ that acknowledges without replying.
                Item {
                  width: parent.width
                  implicitHeight: Math.max(avatar.height, headText.implicitHeight)

                  Avatar {
                    id: avatar
                    width: Style.space(40)
                    height: Style.space(40)
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    source: mrow.modelData.icon ? ("file://" + mrow.modelData.icon) : ""
                    monogram: String(mrow.modelData.appName || mrow.modelData.title || "?")
                  }

                  Column {
                    id: headText
                    anchors.left: avatar.right
                    anchors.right: closeBtn.left
                    anchors.leftMargin: Style.space(12)
                    anchors.rightMargin: Style.space(8)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(3)

                    Text {
                      width: parent.width
                      text: String(mrow.modelData.appName || "Message").toUpperCase()
                      textFormat: Text.PlainText
                      color: panel.fgFaint
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                      font.letterSpacing: 2
                      elide: Text.ElideRight
                    }

                    Text {
                      width: parent.width
                      visible: text.length > 0
                      text: String(mrow.modelData.title || "")
                      textFormat: Text.PlainText
                      color: panel.fg
                      font.family: Style.font.family
                      font.pixelSize: Style.font.subtitle
                      elide: Text.ElideRight
                    }
                  }

                  Item {
                    id: closeBtn
                    anchors.right: parent.right
                    anchors.top: parent.top
                    width: Style.space(24)
                    height: Style.space(24)

                    Text {
                      anchors.centerIn: parent
                      text: "\u{f0156}"
                      color: closeArea.containsMouse ? panel.fg : panel.fgFaint
                      font.family: Style.font.family
                      font.pixelSize: Style.font.body
                    }

                    MouseArea {
                      id: closeArea
                      anchors.fill: parent
                      anchors.margins: -Style.space(4)
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.dismiss(mrow.modelData)
                    }
                  }
                }

                // The message.
                Text {
                  width: parent.width
                  visible: text.length > 0
                  text: String(mrow.modelData.body || "")
                  textFormat: Text.PlainText
                  color: panel.fgMuted
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  wrapMode: Text.WordWrap
                  maximumLineCount: 5
                  elide: Text.ElideRight
                  lineHeight: 1.35
                  bottomPadding: Style.space(2)
                }

                // Reply box, full width; the send button appears under it once
                // there is something to send. Enter sends too. Grows with the
                // message instead of scrolling it, so it can be checked before
                // it goes out.
                ReplyArea {
                  id: field
                  width: parent.width
                  foreground: panel.fg
                  accent: Color.accent
                  verticalPadding: Style.space(8)
                  horizontalPadding: Style.space(12)
                  enabled: !root.sending
                  placeholderText: "Reply to " + String(mrow.modelData.appName || "message") + "…"
                  onAccepted: mrow.send()
                  Keys.onEscapePressed: root.close()
                }

                Item {
                  width: parent.width
                  height: sendButton.implicitHeight
                  visible: field.text.trim().length > 0 || root.sending
                  opacity: visible ? 1 : 0
                  Behavior on opacity { NumberAnimation { duration: 120 } }

                  Text {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    visible: root.sending
                    text: "Sending…"
                    color: panel.fgFaint
                    font.family: Style.font.family
                    font.pixelSize: Style.font.bodySmall
                  }

                  Button {
                    id: sendButton
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Send"
                    foreground: panel.fg
                    accent: Color.accent
                    fontFamily: Style.font.family
                    fontSize: Style.font.bodySmall
                    verticalPadding: Style.space(5)
                    horizontalPadding: Style.space(14)
                    enabled: field.text.trim().length > 0 && !root.sending
                    opacity: enabled ? 1 : 0.4
                    onClicked: mrow.send()
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
