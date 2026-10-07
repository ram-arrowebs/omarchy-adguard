import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: widget
  moduleName: "ram.adguard"
  ipcTarget: "ram.adguard"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // Without these the bar gives the widget zero width and nothing renders.
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // Keyboard cursor: 0 = running switch, 1 = boot switch, 2 = restart, 3 = refresh
  property int cursorIndex: 0
  readonly property int cursorCount: 4

  function selectCursor(index) { cursorIndex = Math.max(0, Math.min(cursorCount - 1, index)) }
  function activateCursor() {
    if (!adguard.unitFound) return
    if (cursorIndex === 0) adguard.toggleService()
    else if (cursorIndex === 1) adguard.toggleBoot()
    else if (cursorIndex === 2) adguard.restart()
    else adguard.refresh()
  }

  // Shield glyphs from the Nerd Font Material set: full shield while
  // blocking, crossed-out shield while stopped, alert shield on failure.
  function icon() {
    if (adguard.failed) return "󰻍"
    if (adguard.active) return "󰒘"
    return "󰦞"
  }

  readonly property var infoRows: {
    var rows = []
    if (!adguard.active || !adguard.proxyRunning) return rows
    if (adguard.httpAddress !== "") rows.push({label: "HTTP proxy", value: adguard.httpAddress})
    if (adguard.socksAddress !== "") rows.push({label: "SOCKS5 proxy", value: adguard.socksAddress})
    if (adguard.autoFiltering !== "") rows.push({label: "System filtering", value: adguard.autoFiltering})
    if (adguard.dnsFiltering !== "") rows.push({label: "DNS filtering", value: adguard.dnsFiltering})
    return rows
  }

  Service {
    id: adguard
    settings: widget.settings
  }

  IpcHandler {
    target: widget.ipcTarget
    function open(): void { widget.open() }
    function close(): void { widget.close() }
    function show(): void { widget.open() }
    function hide(): void { widget.close() }
    function toggle(): void { widget.toggle() }
    function refresh(): string { adguard.refresh(); return "ok" }
    function start(): string { adguard.start(); return "ok" }
    function stop(): string { adguard.stop(); return "ok" }
    function toggleService(): string { adguard.toggleService(); return "ok" }
    function enableBoot(): string { adguard.enableAtBoot(); return "ok" }
    function disableBoot(): string { adguard.disableAtBoot(); return "ok" }
    function status(): string { return adguard.statusText }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: widget.bar
    text: widget.icon()
    opacity: adguard.active ? 1.0 : 0.5
    onPressed: function(mouseButton) {
      if (mouseButton === Qt.RightButton) adguard.toggleService()
      else if (mouseButton === Qt.MiddleButton) adguard.refresh()
      else widget.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: widget
    bar: widget.bar
    open: widget.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(320))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(520))

    onOpenChanged: if (open) adguard.refresh()

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) { if (dy !== 0) widget.selectCursor(widget.cursorIndex + dy) }
      onActivateRequested: widget.activateCursor()
      onCloseRequested: widget.close()
      onTabRequested: function(direction) { widget.switchPanel(direction) }

      Column {
        id: column
        anchors.fill: parent
        spacing: Style.space(12)

        // ---------- Hero: shield · status · run switch ----------
        Item {
          id: header
          width: parent.width
          implicitHeight: hero.implicitHeight
          readonly property bool ringVisible: widget.cursorIndex === 0
          function focusHero() { widget.selectCursor(0) }

          PanelHero {
            id: hero
            width: parent.width
            title: "AdGuard"
            meta: adguard.statusText
            foreground: widget.foreground
            fontFamily: widget.fontFamily
            iconOpacity: adguard.active ? 1.0 : 0.5
            iconComponent: Component {
              Text {
                text: widget.icon()
                color: adguard.failed ? widget.urgent : hero.foreground
                font.family: hero.fontFamily
                font.pixelSize: Style.font.display
              }
            }
            trailingControl: Component {
              ToggleSwitch {
                id: runSwitch
                visible: adguard.unitFound
                checked: adguard.active
                busy: adguard.busy && adguard.actionStatus !== ""
                hasCursor: header.ringVisible
                foreground: hero.foreground
                onHovered: function(on) { if (on) header.focusHero() }
                onToggled: adguard.toggleService()

                PanelToolTip {
                  visible: runSwitch.containsMouse
                  text: adguard.active ? "Stop the proxy service" : "Start the proxy service"
                  fontFamily: hero.fontFamily
                }
              }
            }
          }
        }

        // ---------- Listening addresses ----------
        Column {
          width: parent.width
          spacing: Style.space(4)
          visible: widget.infoRows.length > 0

          Repeater {
            model: widget.infoRows
            Item {
              required property var modelData
              width: column.width
              height: Style.space(16)
              Text {
                text: modelData.label
                color: widget.dim
                font.family: widget.fontFamily
                font.pixelSize: Style.font.caption
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }
              Text {
                text: modelData.value
                color: widget.foreground
                font.family: widget.fontFamily
                font.pixelSize: Style.font.caption
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
              }
            }
          }
        }

        PanelSeparator { width: parent.width; foreground: widget.foreground }

        PanelSectionHeader {
          width: parent.width
          text: "Startup"
          foreground: widget.foreground
          fontFamily: widget.fontFamily
        }

        // ---------- Start at boot ----------
        Item {
          width: parent.width
          height: Math.max(bootLabel.implicitHeight, bootSwitch.implicitHeight)

          Column {
            id: bootLabel
            anchors.left: parent.left
            anchors.right: bootSwitch.left
            anchors.rightMargin: Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)
            Text {
              text: "Start at boot"
              color: widget.foreground
              font.family: widget.fontFamily
              font.pixelSize: Style.font.body
            }
            Text {
              width: parent.width
              text: adguard.startsAtBoot
                    ? "The proxy starts with your session."
                    : "Stays running now, but will not start on the next boot."
              color: widget.dim
              font.family: widget.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          ToggleSwitch {
            id: bootSwitch
            enabled: adguard.unitFound
            checked: adguard.startsAtBoot
            hasCursor: widget.cursorIndex === 1
            foreground: widget.foreground
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            onHovered: function(on) { if (on) widget.selectCursor(1) }
            onToggled: adguard.toggleBoot()
          }
        }

        // ---------- Actions ----------
        Row {
          width: parent.width
          spacing: Style.space(8)

          Button {
            text: "Restart"
            iconText: "󰜉"
            enabled: adguard.unitFound && adguard.active
            hasCursor: widget.cursorIndex === 2
            foreground: widget.foreground
            fontFamily: widget.fontFamily
            onHovered: function(on) { if (on) widget.selectCursor(2) }
            onClicked: adguard.restart()
          }

          Button {
            text: "Refresh"
            iconText: "󰑐"
            iconSpinning: adguard.busy
            hasCursor: widget.cursorIndex === 3
            foreground: widget.foreground
            fontFamily: widget.fontFamily
            onHovered: function(on) { if (on) widget.selectCursor(3) }
            onClicked: adguard.refresh()
          }
        }

        // ---------- Footnotes ----------
        Text {
          width: parent.width
          visible: adguard.actionStatus !== "" || adguard.lastError !== ""
          text: adguard.lastError !== "" ? adguard.lastError : adguard.actionStatus
          color: adguard.lastError !== "" ? widget.urgent : widget.dim
          font.family: widget.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        Text {
          width: parent.width
          visible: adguard.checked && !adguard.unitFound
          text: "No user unit named " + adguard.unit + " was found. Create it, or change the unit name in this widget's settings."
          color: widget.dim
          font.family: widget.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }
    }
  }
}
