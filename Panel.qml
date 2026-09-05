import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Vibrance popup: one row per connected display. All state lives in the
// service — this file only renders it and forwards edits, so the bar surfaces
// on a multi-monitor setup stay in agreement.
Panel {
  id: root
  moduleName: "com.github.marvreichmann.omavibrance"
  ipcTarget: "com.github.marvreichmann.omavibrance"

  property var anchorItem: null

  // The bar tracks the widget mounted in its slot — BarWidget.qml — not this
  // nested panel, so popup coordination has to be keyed on the host.
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // The shell injects `service` only into panels loaded from the manifest's
  // `panel` entry point. This one is nested inside the bar widget instead, so
  // it reaches the singleton the way any bar-hosted component has to: through
  // the bar's shell reference.
  readonly property var service: bar && bar.shell ? bar.shell.serviceFor("com.github.marvreichmann.omavibrance") : null

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar && bar.urgent !== undefined ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property var displays: service ? service.connectedDisplays : []

  // Which row has its name field open. Only one at a time, so the key catcher
  // can be blocked while it is.
  property int editingIndex: -1

  function openFromHotkey() { root.controller.show() }

  onOpenedChanged: {
    if (!opened) {
      editingIndex = -1
      // A pulse left running behind a closed panel would keep flashing a
      // monitor with no visible way to stop it.
      if (service && service.identifyIndex >= 0) service.stopIdentify()
      return
    }
    // Re-reading on open is cheap (one process) and catches vibrance or a
    // monitor layout changed by anything else since the panel was last shown.
    if (service) service.refresh()
    // The catcher only sees keys once it holds focus, and the popup window
    // does not exist yet on the frame `opened` flips.
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  function applyPercent(index, percent) {
    if (!service) return
    service.setVibrancePercent(index, Math.round(percent))
  }

  PopupCard {
    id: card
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    contentWidth: card.fittedContentWidth(Style.space(400))
    contentHeight: card.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // While a name field is open it must receive the keystrokes itself,
      // including the Escape that closes it.
      blocked: root.editingIndex >= 0
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
    }

    Column {
      id: content
      width: parent.width
      spacing: Style.spacing.lg

      PanelSectionHeader {
        text: "DIGITAL VIBRANCE"
        foreground: root.foreground
        fontFamily: root.fontFamily
      }

      // ------------------------------------------------------------ errors

      Text {
        width: parent.width
        visible: !root.service
        text: "Service unavailable — enable the omavibrance service in shell.json."
        color: root.urgent
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.WordWrap
        textFormat: Text.PlainText
      }

      Text {
        width: parent.width
        visible: root.service ? root.service.nvibrantMissing : false
        text: "nvibrant is not installed. Install it to control vibrance."
        color: root.urgent
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.WordWrap
        textFormat: Text.PlainText
      }

      Text {
        width: parent.width
        visible: root.service ? (!root.service.nvibrantMissing && root.service.lastError !== "") : false
        text: root.service ? root.service.lastError : ""
        color: root.urgent
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.WordWrap
        textFormat: Text.PlainText
      }

      Text {
        width: parent.width
        visible: root.service ? (!root.service.nvibrantMissing && root.displays.length === 0) : false
        text: "No connected displays reported by nvibrant."
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.WordWrap
        textFormat: Text.PlainText
      }

      // -------------------------------------------------------------- rows

      Repeater {
        model: root.displays

        delegate: Item {
          id: row
          required property var modelData

          readonly property int displayIndex: modelData.index
          readonly property var monitor: root.service ? root.service.monitorFor(displayIndex) : null
          readonly property string customName: root.service ? root.service.nameFor(displayIndex) : ""
          readonly property bool editing: root.editingIndex === displayIndex
          readonly property bool identifying: root.service ? root.service.identifyIndex === displayIndex : false

          width: content.width
          implicitHeight: rowColumn.implicitHeight
          height: implicitHeight

          // Dragging a slider fires on every pixel of movement. Each apply is a
          // process spawn, so the drag is rate-limited here and the final value
          // is sent unconditionally on release — otherwise a drag that ends
          // between ticks leaves the display on a stale value.
          Timer {
            id: throttle
            interval: 25
            repeat: false
            onTriggered: root.applyPercent(row.displayIndex, slider.liveValue)
          }

          Column {
            id: rowColumn
            width: parent.width
            spacing: Style.spacing.xs

            // ---- name line ----
            Item {
              width: parent.width
              implicitHeight: Math.max(nameStack.implicitHeight, rowActions.implicitHeight)

              Item {
                id: nameStack
                anchors.left: parent.left
                anchors.right: rowActions.left
                anchors.rightMargin: Style.spacing.sm
                anchors.verticalCenter: parent.verticalCenter
                implicitHeight: row.editing ? nameField.implicitHeight : nameLabel.implicitHeight

                Text {
                  id: nameLabel
                  visible: !row.editing
                  width: parent.width
                  text: Model.displayLabel(row.modelData, row.monitor, row.customName)
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  elide: Text.ElideRight
                  textFormat: Text.PlainText
                }

                TextField {
                  id: nameField
                  visible: row.editing
                  width: parent.width
                  foreground: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  placeholderText: row.monitor && row.monitor.model ? row.monitor.model : "Display name"

                  function commit() {
                    if (root.service) root.service.setName(row.displayIndex, text)
                    root.editingIndex = -1
                  }

                  onAccepted: commit()
                  Keys.onEscapePressed: function(event) {
                    root.editingIndex = -1
                    event.accepted = true
                  }
                  // Clicking elsewhere in the panel is a commit, not a cancel:
                  // losing the text because the popup stole focus would be a
                  // surprise.
                  onActiveFocusChanged: if (!activeFocus && row.editing) commit()
                }
              }

              Row {
                id: rowActions
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.spacing.xxs

                PanelActionButton {
                  // U+F0208 nf-md-eye — flash this display so it can be told
                  // apart from the others.
                  iconText: "\udb80\ude08"
                  tooltipText: row.identifying ? "Identifying…" : "Flash this display"
                  foreground: row.identifying ? Color.accent : root.dim
                  hoverColor: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: {
                    if (!root.service) return
                    if (row.identifying) root.service.stopIdentify()
                    else root.service.identify(row.displayIndex)
                  }
                }

                PanelActionButton {
                  // U+F03EB nf-md-pencil
                  iconText: "\udb80\udfeb"
                  tooltipText: "Rename"
                  foreground: root.dim
                  hoverColor: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: {
                    nameField.text = row.customName
                    root.editingIndex = row.displayIndex
                    nameField.forceActiveFocus()
                    nameField.selectAll()
                  }
                }
              }
            }

            // ---- detail line ----
            Text {
              width: parent.width
              text: Model.displayDetail(row.modelData, row.monitor, row.customName)
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
              textFormat: Text.PlainText
            }

            // ---- control line ----
            Item {
              width: parent.width
              implicitHeight: Math.max(slider.implicitHeight, field.implicitHeight)

              PanelSlider {
                id: slider
                anchors.left: parent.left
                anchors.right: field.left
                anchors.rightMargin: Style.spacing.controlGap
                anchors.verticalCenter: parent.verticalCenter
                bar: root.bar
                minimum: -100
                maximum: 100
                // One percent per wheel notch, no snapping: the track is a
                // continuous range, not a set of stops.
                step: 1
                integer: true
                value: root.service ? root.service.percentFor(row.displayIndex) : 0

                onMoved: throttle.restart()
                onReleased: function(value) {
                  throttle.stop()
                  root.applyPercent(row.displayIndex, value)
                }
                // Right-click a slider to return that display to neutral.
                onRightClicked: root.applyPercent(row.displayIndex, 0)
              }

              NumberField {
                id: field
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                from: -100
                to: 100
                stepSize: 5
                fieldWidth: Style.space(78)
                foreground: root.foreground
                fontFamily: root.fontFamily
                // Follow the knob while it is moving; the service only catches
                // up once nvibrant has run.
                value: slider.dragging
                  ? Math.round(slider.liveValue)
                  : (root.service ? root.service.percentFor(row.displayIndex) : 0)
                onModified: function(value) { root.applyPercent(row.displayIndex, value) }
              }
            }
          }
        }
      }

      PanelSeparator {
        visible: root.displays.length > 0
        foreground: root.foreground
      }

      // ------------------------------------------------------------ footer

      Item {
        width: parent.width
        implicitHeight: footerRow.implicitHeight

        Text {
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          visible: root.service ? root.service.driverVersion !== "" : false
          text: "Driver " + (root.service ? root.service.driverVersion : "")
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          textFormat: Text.PlainText
        }

        Row {
          id: footerRow
          anchors.right: parent.right
          spacing: Style.spacing.sm

          Button {
            text: "Save"
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            tooltipText: "Pin these values as the ones to come back to"
            enabled: root.displays.length > 0
            opacity: enabled ? 1.0 : 0.4
            onClicked: if (root.service) root.service.saveSnapshot()
          }

          Button {
            text: "Restore"
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            tooltipText: "Return to the saved values"
            enabled: root.service ? root.service.hasSnapshot : false
            opacity: enabled ? 1.0 : 0.4
            onClicked: if (root.service) root.service.restoreSnapshot()
          }

          Button {
            text: "Reset"
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            tooltipText: "Set every display to neutral"
            // Item.enabled blocks the button's input but paints nothing
            // differently, so the dimming has to be explicit.
            enabled: root.service ? !root.service.nvibrantMissing : false
            opacity: enabled ? 1.0 : 0.4
            onClicked: if (root.service) root.service.resetAll()
          }

          Button {
            text: "Close"
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            onClicked: root.close()
          }
        }
      }
    }
  }
}
