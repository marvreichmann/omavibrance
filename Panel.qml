import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Vibrance popup: one slider per connected display. All state lives in the
// service — this file only renders it and forwards edits, so the three bar
// surfaces on a three-monitor setup stay in agreement.
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

  function openFromHotkey() { root.controller.show() }

  onOpenedChanged: {
    if (!opened) return
    // Re-reading on open is cheap (one process) and catches vibrance changed
    // by anything else since the panel was last shown.
    if (service) service.refresh()
    // The catcher only sees keys once it holds focus, and the popup window
    // does not exist yet on the frame `opened` flips.
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  PopupCard {
    id: card
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    contentWidth: card.fittedContentWidth(Style.space(320))
    contentHeight: card.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
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

      // ----------------------------------------------------------- sliders

      Repeater {
        model: root.displays

        delegate: Item {
          id: row
          required property var modelData
          width: content.width
          implicitHeight: rowColumn.implicitHeight
          height: implicitHeight

          // Dragging a slider fires `moved` on every pixel. nvibrant is a
          // process spawn per call, so the drag is throttled here and the
          // final value is sent unconditionally on release — otherwise a drag
          // that ends between ticks leaves the display on a stale value.
          Timer {
            id: throttle
            interval: 60
            repeat: false
            onTriggered: root.applyPercent(row.modelData.index, slider.liveValue)
          }

          Column {
            id: rowColumn
            width: parent.width
            spacing: Style.spacing.xs

            Item {
              width: parent.width
              implicitHeight: Math.max(label.implicitHeight, readout.implicitHeight)

              Text {
                id: label
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: Model.displayLabel(row.modelData)
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                textFormat: Text.PlainText
              }

              Text {
                id: readout
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                // While dragging, follow the knob rather than the service —
                // the service only catches up once nvibrant has run.
                text: (slider.dragging ? Math.round(slider.liveValue)
                                       : root.service.percentFor(row.modelData.index)) + "%"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                textFormat: Text.PlainText
              }
            }

            PanelSlider {
              id: slider
              width: parent.width
              bar: root.bar
              minimum: -100
              maximum: 100
              step: 5
              integer: true
              // A notch at each 25% step, with the middle one marking neutral.
              tickCount: 9
              value: root.service ? root.service.percentFor(row.modelData.index) : 0

              onMoved: throttle.restart()
              onReleased: function(value) {
                throttle.stop()
                root.applyPercent(row.modelData.index, value)
              }
              // Right-click a slider to return that display to neutral.
              onRightClicked: root.applyPercent(row.modelData.index, 0)
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
            text: "Reset"
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
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
            onClicked: root.close()
          }
        }
      }
    }
  }

  function applyPercent(index, percent) {
    if (!service) return
    service.setVibrancePercent(index, Math.round(percent))
  }
}
