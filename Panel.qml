import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Vibrance popup: one card per connected display. All state lives in the
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
  readonly property bool bypassed: service ? service.bypassed : false

  // Which row has its name field open, and which has its numeric field open.
  // One of each at most, so the key catcher knows when to stand down.
  property int editingIndex: -1
  property int numericIndex: -1

  // Whether the install instructions under the missing-binary warning are open.
  property bool helpOpen: false

  // The card's inner padding, and therefore the amount the header and footer
  // are inset by so that *their* contents share the rows' left edge.
  //
  // The cards themselves span the full content column, which puts their border
  // on the same line as the hero's toggle and the footer buttons — the panel's
  // outer edge — while everything that reads as content sits one inset inside
  // it. Bleeding the cards outward instead would align the contents but leave
  // the boxes sticking out past the controls above and below them.
  readonly property int rowInset: Style.spacing.rowPaddingX

  // The leading icon column, shared by the hero and every row so their glyphs
  // and their text both start on the same line. The gap matches the one
  // PanelHero puts between its own icon and labels, which is fixed at 14.
  //
  // OpticalGlyph is an Item with no implicit size that centers its text on
  // itself, so a glyph given no width is a 0-wide box with half the mark
  // hanging off the left edge. Both icons below are therefore sized explicitly.
  readonly property int iconColumn: Style.space(24)
  readonly property int iconGap: Style.space(14)

  // The hero's status line: what the panel is driving right now.
  readonly property string heroMeta: {
    if (!service) return "Service unavailable"
    if (service.nvibrantMissing) return "nvibrant not found"
    if (service.bypassed) return "Bypassed · vibrance off"
    var n = displays.length
    var count = n === 1 ? "1 display" : n + " displays"
    return service.driverVersion !== "" ? count + " · driver " + service.driverVersion : count
  }

  function openFromHotkey() { root.controller.show() }

  onOpenedChanged: {
    if (!opened) {
      editingIndex = -1
      numericIndex = -1
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
    // One margin on every side. The card borders, the hero's toggle and the
    // footer buttons all sit on the content column's edge, so this is equally
    // the gap to the right of the buttons and the gap below them.
    padding: Style.space(16)
    contentWidth: card.fittedContentWidth(Style.space(420))
    contentHeight: card.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // While a field is open it must receive the keystrokes itself, including
      // the Escape that dismisses it.
      blocked: root.editingIndex >= 0 || root.numericIndex >= 0
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
    }

    Column {
      id: content
      width: parent.width
      spacing: Style.spacing.xxl

      // ------------------------------------------------------------- hero

      PanelHero {
        id: hero
        // Inset on the left only: the icon and labels line up with what is
        // inside the cards, while the trailing switch stays out on the content
        // edge with the card borders and the footer buttons.
        x: root.rowInset
        width: parent.width - root.rowInset
        title: "Digital Vibrance"
        meta: root.heroMeta
        foreground: root.foreground
        fontFamily: root.fontFamily
        iconOpacity: (root.service && !root.service.nvibrantMissing && !root.bypassed) ? 1.0 : 0.5

        iconComponent: Component {
          OpticalGlyph {
            // U+F0301 nf-md-invert_colors, the same mark as the bar widget.
            text: "\udb80\udf01"
            width: root.iconColumn
            height: root.iconColumn
            fontSize: Style.font.display
            color: root.foreground
          }
        }

        // Master switch. Off drives every display to neutral while leaving the
        // stored values — and this panel's sliders — exactly where they are.
        trailingControl: Component {
          ToggleSwitch {
            id: powerSwitch
            visible: root.service && !root.service.nvibrantMissing
            checked: !root.bypassed
            foreground: hero.foreground
            // The cursor ring pads the item six pixels around the visible
            // track, which would leave the switch floating short of the edge
            // every other control lines up on. Nothing here drives the panel by
            // keyboard cursor, so the ring costs nothing to drop.
            cursorRing: false
            onToggled: if (root.service) root.service.setBypassed(root.bypassed ? false : true)

            PanelToolTip {
              visible: powerSwitch.containsMouse
              text: root.bypassed ? "Turn vibrance on" : "Bypass — set every display neutral"
              fontFamily: hero.fontFamily
            }
          }
        }
      }

      PanelSeparator { foreground: root.foreground }

      // ------------------------------------------------------------ errors

      Text {
        x: root.rowInset
        width: parent.width - root.rowInset
        visible: !root.service
        text: "Enable the omavibrance service by adding the widget to your bar in shell.json."
        color: root.urgent
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.WordWrap
        textFormat: Text.PlainText
      }

      // Missing binary: say so, and put the fix one click away rather than
      // sending the reader off to find the README.
      Column {
        width: parent.width
        visible: root.service ? root.service.nvibrantMissing : false
        spacing: Style.spacing.sm

        Item {
          width: parent.width
          implicitHeight: Math.max(missingText.implicitHeight, helpButton.implicitHeight)

          Text {
            id: missingText
            anchors.left: parent.left
            anchors.leftMargin: root.rowInset
            anchors.right: helpButton.left
            anchors.rightMargin: Style.spacing.sm
            anchors.verticalCenter: parent.verticalCenter
            text: "nvibrant is not installed."
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
          }

          PanelActionButton {
            id: helpButton
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            // U+F0625 nf-md-help-circle-outline
            iconText: "\udb81\ude25"
            tooltipText: root.helpOpen ? "Hide" : "How to install it"
            foreground: root.helpOpen ? Color.accent : root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            onClicked: root.helpOpen = !root.helpOpen
          }
        }

        BorderSurface {
          visible: root.helpOpen
          width: parent.width
          implicitHeight: helpText.implicitHeight + Style.spacing.xxl
          height: implicitHeight
          radius: Style.cornerRadius
          color: Style.normalFillFor(root.foreground, Color.accent)
          borderSpec: Border.controlSpec("normal", root.foreground, Color.accent)

          Text {
            id: helpText
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: root.rowInset
            anchors.rightMargin: root.rowInset
            text: "On Arch, from the AUR:\n    yay -S nvibrant-bin\n\nAnywhere else:\n    pipx install nvibrant\n\n"
              + "It drives /dev/nvidia-modeset directly, so the kernel needs nvidia_drm.modeset=1.\n"
              + "Reopen this panel once it is on your PATH."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
          }
        }
      }

      Text {
        x: root.rowInset
        width: parent.width - root.rowInset
        visible: root.service ? (!root.service.nvibrantMissing && root.service.lastError !== "") : false
        text: root.service ? root.service.lastError : ""
        color: root.urgent
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.WordWrap
        textFormat: Text.PlainText
      }

      Text {
        x: root.rowInset
        width: parent.width - root.rowInset
        visible: root.service ? (!root.service.nvibrantMissing && root.displays.length === 0) : false
        text: "No connected displays reported by nvibrant."
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.WordWrap
        textFormat: Text.PlainText
      }

      // ------------------------------------------------------------- rows

      Column {
        width: parent.width
        spacing: Style.spacing.sm
        // Bypassed displays are still editable — you set up where vibrance
        // will land before switching it back on — but they are not in effect,
        // and the panel should not pretend otherwise.
        opacity: root.bypassed ? 0.55 : 1.0

        Behavior on opacity {
          NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
        }

        Repeater {
          model: root.displays

          delegate: BorderSurface {
            id: rowCard
            required property var modelData

            readonly property int displayIndex: modelData.index
            readonly property var monitor: root.service ? root.service.monitorFor(displayIndex) : null
            readonly property string customName: root.service ? root.service.nameFor(displayIndex) : ""
            readonly property bool editing: root.editingIndex === displayIndex
            readonly property bool numeric: root.numericIndex === displayIndex
            readonly property bool identifying: root.service ? root.service.identifyIndex === displayIndex : false
            readonly property bool hot: hover.hovered || editing || numeric || identifying

            width: parent.width
            implicitHeight: rowColumn.implicitHeight + contentTopInset + contentBottomInset
            height: implicitHeight
            radius: Style.cornerRadius
            topPadding: Style.spacing.rowPaddingX
            bottomPadding: Style.spacing.rowPaddingX
            // Measured off the border rather than fixed, because the normal,
            // hover and selected specs can differ in border width — folding
            // that difference into the padding keeps the contents from shifting
            // sideways as the row lights up.
            leftPadding: Math.max(0, root.rowInset - borderLeft)
            rightPadding: Math.max(0, root.rowInset - borderRight)
            // A card that lifts on hover, so three rows read as three objects
            // rather than one wall of text. An identifying row stays lit for as
            // long as its display is flashing.
            color: identifying
              ? Style.selectedFillFor(root.foreground, Color.accent)
              : (hot ? Style.hoverFillFor(root.foreground, Color.accent)
                     : Style.normalFillFor(root.foreground, Color.accent))
            borderSpec: Border.controlSpec(identifying ? "selected" : (hot ? "hover-cursor" : "normal"),
                                           root.foreground, Color.accent)

            Behavior on color {
              ColorAnimation { duration: 120; easing.type: Easing.OutCubic }
            }

            HoverHandler { id: hover }

            // Dragging a slider fires on every pixel of movement. Each apply is
            // a process spawn, so the drag is rate-limited here and the final
            // value is sent unconditionally on release — otherwise a drag that
            // ends between ticks leaves the display on a stale value.
            Timer {
              id: throttle
              interval: 25
              repeat: false
              onTriggered: root.applyPercent(rowCard.displayIndex, slider.liveValue)
            }

            Column {
              id: rowColumn
              anchors.top: parent.top
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.topMargin: rowCard.contentTopInset
              anchors.leftMargin: rowCard.contentLeftInset
              anchors.rightMargin: rowCard.contentRightInset
              spacing: Style.spacing.xs

              // ---- name + reading ----
              Item {
                width: parent.width
                implicitHeight: Math.max(nameStack.implicitHeight, valueStack.implicitHeight)

                OpticalGlyph {
                  id: rowIcon
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  width: root.iconColumn
                  height: Style.font.icon
                  // U+F0379 nf-md-monitor
                  text: "\udb80\udf79"
                  fontSize: Style.font.bodySmall
                  fontFamily: root.fontFamily
                  color: rowCard.identifying ? Color.accent : root.dim
                }

                Item {
                  id: nameStack
                  anchors.left: rowIcon.right
                  anchors.leftMargin: root.iconGap
                  anchors.right: valueStack.left
                  anchors.rightMargin: Style.spacing.controlGap
                  anchors.verticalCenter: parent.verticalCenter
                  implicitHeight: rowCard.editing ? nameField.implicitHeight : nameLabel.implicitHeight

                  Text {
                    id: nameLabel
                    visible: !rowCard.editing
                    width: parent.width
                    text: Model.displayLabel(rowCard.modelData, rowCard.monitor, rowCard.customName)
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                  }

                  TextField {
                    id: nameField
                    visible: rowCard.editing
                    width: parent.width
                    foreground: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    placeholderText: rowCard.monitor && rowCard.monitor.model ? rowCard.monitor.model : "Display name"

                    function commit() {
                      if (root.service) root.service.setName(rowCard.displayIndex, text)
                      root.editingIndex = -1
                    }

                    // Clearing editingIndex first makes `rowCard.editing` false,
                    // so the focus-loss handler below sees an edit that is no
                    // longer in progress and drops the text instead of saving it.
                    function cancel() { root.editingIndex = -1 }

                    onAccepted: commit()
                    Keys.onEscapePressed: function(event) {
                      cancel()
                      event.accepted = true
                    }

                    // No commit-on-focus-loss. Clicking the discard button can
                    // take focus off this field before its click handler runs,
                    // so a focus-loss commit would save the very edit the user
                    // just asked to throw away. Only the four explicit exits —
                    // Enter, Escape, and the two buttons — decide the outcome.
                  }
                }

                // The reading, right-aligned where the eye lands. The spin box
                // is the same value behind a button, so the resting row shows a
                // number rather than a control.
                Item {
                  id: valueStack
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  implicitWidth: rowCard.numeric ? numberField.implicitWidth : percentLabel.implicitWidth
                  implicitHeight: rowCard.numeric ? numberField.implicitHeight : percentLabel.implicitHeight

                  Text {
                    id: percentLabel
                    visible: !rowCard.numeric
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: (slider.dragging
                      ? Math.round(slider.liveValue)
                      : (root.service ? root.service.percentFor(rowCard.displayIndex) : 0)) + "%"
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    textFormat: Text.PlainText
                  }

                  NumberField {
                    id: numberField
                    visible: rowCard.numeric
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    from: -100
                    to: 100
                    stepSize: 5
                    fieldWidth: Style.space(74)
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    fontSize: Style.font.bodySmall
                    value: slider.dragging
                      ? Math.round(slider.liveValue)
                      : (root.service ? root.service.percentFor(rowCard.displayIndex) : 0)
                    onModified: function(value) { root.applyPercent(rowCard.displayIndex, value) }
                  }
                }
              }

              // ---- detail + actions ----
              Item {
                width: parent.width
                implicitHeight: Math.max(detailText.implicitHeight, rowActions.implicitHeight)

                Text {
                  id: detailText
                  anchors.left: parent.left
                  anchors.leftMargin: rowIcon.width + root.iconGap
                  anchors.right: rowActions.left
                  anchors.rightMargin: Style.spacing.sm
                  anchors.verticalCenter: parent.verticalCenter
                  text: Model.displayDetail(rowCard.modelData, rowCard.monitor, rowCard.customName)
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                  textFormat: Text.PlainText
                }

                Row {
                  id: rowActions
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.spacing.xxs
                  // Present but recessive until the row is under the cursor, so
                  // the resting panel stays quiet without hiding the controls
                  // from anyone looking for them.
                  opacity: rowCard.hot ? 1.0 : 0.45

                  Behavior on opacity {
                    NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
                  }

                  // While renaming, the row's actions become the two answers to
                  // the question on screen. Escape works too, but a rename with
                  // no visible way out is a trap.
                  PanelActionButton {
                    visible: rowCard.editing
                    // U+F012C nf-md-check
                    iconText: "\udb80\udd2c"
                    tooltipText: "Save name"
                    foreground: Color.accent
                    fontFamily: root.fontFamily
                    fontSize: Style.font.bodySmall
                    onClicked: nameField.commit()
                  }

                  PanelActionButton {
                    visible: rowCard.editing
                    // U+F0156 nf-md-close
                    iconText: "\udb80\udd56"
                    tooltipText: "Discard"
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    fontSize: Style.font.bodySmall
                    onClicked: nameField.cancel()
                  }

                  PanelActionButton {
                    visible: !rowCard.editing
                    // U+F0208 nf-md-eye — flash this display so it can be told
                    // apart from the others.
                    iconText: "\udb80\ude08"
                    tooltipText: rowCard.identifying ? "Stop flashing" : "Flash this display"
                    foreground: rowCard.identifying ? Color.accent : root.foreground
                    fontFamily: root.fontFamily
                    fontSize: Style.font.bodySmall
                    onClicked: {
                      if (!root.service) return
                      if (rowCard.identifying) root.service.stopIdentify()
                      else root.service.identify(rowCard.displayIndex)
                    }
                  }

                  PanelActionButton {
                    visible: !rowCard.editing
                    // U+F03EB nf-md-pencil
                    iconText: "\udb80\udfeb"
                    tooltipText: "Rename"
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    fontSize: Style.font.bodySmall
                    onClicked: {
                      root.numericIndex = -1
                      nameField.text = rowCard.customName
                      root.editingIndex = rowCard.displayIndex
                      nameField.forceActiveFocus()
                      nameField.selectAll()
                    }
                  }

                  PanelActionButton {
                    visible: !rowCard.editing
                    // U+F030C nf-md-keyboard \u2014 "type it in", which reads more
                    // clearly at this size than any of the numeric glyphs.
                    iconText: "\udb80\udf0c"
                    tooltipText: rowCard.numeric ? "Hide the value box" : "Type an exact value"
                    foreground: rowCard.numeric ? Color.accent : root.foreground
                    fontFamily: root.fontFamily
                    fontSize: Style.font.bodySmall
                    onClicked: root.numericIndex = rowCard.numeric ? -1 : rowCard.displayIndex
                  }
                }
              }

              // ---- slider, full width, with a neutral mark ----
              Item {
                width: parent.width
                implicitHeight: slider.implicitHeight

                // Sits under the slider so the track hides its middle and the
                // knob never collides with it. It has to clear the knob, not
                // just the track: at exactly 0% the knob parks dead centre, and
                // a mark only as tall as the knob disappears underneath it. The
                // track spans this item's full width, so the item's centre is
                // exactly the neutral position.
                Rectangle {
                  anchors.centerIn: parent
                  width: Math.max(1, Style.space(2))
                  height: slider.knobSize + Style.space(12)
                  radius: width / 2
                  color: root.dim
                }

                PanelSlider {
                  id: slider
                  anchors.fill: parent
                  bar: root.bar
                  minimum: -100
                  maximum: 100
                  // One percent per wheel notch, no snapping: the track is a
                  // continuous range, not a set of stops.
                  step: 1
                  integer: true
                  value: root.service ? root.service.percentFor(rowCard.displayIndex) : 0

                  onMoved: throttle.restart()
                  onReleased: function(value) {
                    throttle.stop()
                    root.applyPercent(rowCard.displayIndex, value)
                  }
                  // Right-click a slider to return that display to neutral.
                  onRightClicked: root.applyPercent(rowCard.displayIndex, 0)
                }
              }
            }
          }
        }
      }

      // ------------------------------------------------------------ footer

      Item {
        width: parent.width
        implicitHeight: footerRow.implicitHeight

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
            // A snapshot can outlive the binary that applied it, so this needs
            // the same guard as the rest: with nvibrant gone the click would be
            // swallowed and the button would just look broken.
            enabled: root.service ? (root.service.hasSnapshot && !root.service.nvibrantMissing) : false
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
