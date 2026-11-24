import QtQuick
import QtQuick.Shapes
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "io.github.nathanrgagnon.omawhoop"
  ipcTarget: "io.github.nathanrgagnon.omawhoop"

  property var anchorItem: null
  property var hostWidget: null
  property var status: null

  readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "")
  readonly property string redirectUri: "http://localhost:8942/callback"
  readonly property var barIdentity: hostWidget || root

  readonly property bool authenticated: !Model.isAuthError(status)
  readonly property string strainLabel: Model.formatStrain(status ? status.strain : null)
  readonly property string strainStateLabel: Model.scoreStateLabel(status ? status.strain_state : "")
  readonly property string recoveryLabel: Model.formatPercent(status ? status.recovery : null)
  readonly property string recoveryStateLabel: Model.scoreStateLabel(status ? status.recovery_state : "")
  readonly property color recoveryColor: Model.recoveryColor(status ? status.recovery : null, root.barForeground)
  readonly property string sleepLabel: Model.formatPercent(status ? status.sleep_pct : null)
  readonly property string sleepDurationLabel: Model.formatDuration(status ? status.sleep_total_ms : null)
  readonly property string hrvLabel: Model.formatHrv(status ? status.hrv_ms : null)
  readonly property string rhrLabel: Model.formatBpm(status ? status.rhr : null)
  readonly property string respiratoryLabel: Model.formatRespiratoryRate(status ? status.respiratory_rate : null)
  readonly property string spo2Label: Model.formatPercent(status ? status.spo2 : null)
  readonly property string skinTempLabel: Model.formatTemperature(status ? status.skin_temp_c : null)
  readonly property string sleepEfficiencyLabel: Model.formatPercent(status ? status.sleep_efficiency : null)
  readonly property string caloriesLabel: Model.formatCalories(status ? status.kilojoule : null)
  readonly property string avgHrLabel: Model.formatBpm(status ? status.avg_hr : null)
  readonly property string maxHrLabel: Model.formatBpm(status ? status.max_hr : null)
  readonly property string updatedLabel: Model.relativeUpdated(status ? status.fetched_at : 0, Date.now() / 1000)
  readonly property bool stale: !!(status && status.stale)

  // WHOOP scores Strain 0-21 (see the API's CycleScore/WorkoutScore docs);
  // Recovery/Sleep are already 0-100 percentages. Ring colors mirror the
  // WHOOP app: dynamic recovery banding, fixed blue for strain, fixed
  // violet for sleep.
  readonly property real strainMax: 21
  // Per the WHOOP Brand & Design Guidelines color palette: Strain #0093E7,
  // Sleep #7BA1BB — not arbitrary picks, so ring colors match the app.
  readonly property color strainColor: "#0093E7"
  readonly property color sleepColor: "#7BA1BB"
  readonly property bool recoveryHasValue: !!(status && status.recovery !== null && status.recovery !== undefined)
  readonly property bool strainHasValue: !!(status && status.strain !== null && status.strain !== undefined)
  readonly property bool sleepHasValue: !!(status && status.sleep_pct !== null && status.sleep_pct !== undefined)

  function binCommand(name) {
    return ["bash", root.pluginDir + "bin/" + name]
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function open() {
    root.controller.show()
    root.refresh(false)
    root.refreshHistory(false)
  }

  function refresh(force) {
    if (statusProc.running) return
    statusProc.command = force ? root.binCommand("omawhoop-status").concat(["--force"]) : root.binCommand("omawhoop-status")
    statusProc.running = true
  }

  property bool connecting: false
  readonly property bool waitingForBrowser: loginProc.running
  property string connectError: ""

  function submitConnect() {
    var clientId = clientIdField.text.trim()
    var clientSecret = clientSecretField.text
    if (clientId === "" || clientSecret === "") {
      root.connectError = "Enter both the client ID and client secret."
      return
    }
    root.connectError = ""
    root.connecting = true
    saveConfigProc.pendingId = clientId
    saveConfigProc.pendingSecret = clientSecret
    saveConfigProc.running = true
  }

  Process {
    id: saveConfigProc
    property string pendingId: ""
    property string pendingSecret: ""
    property string errorText: ""
    command: root.binCommand("omawhoop-auth").concat(["save-config"])
    stdinEnabled: true
    onStarted: {
      write(pendingId + "\n" + pendingSecret + "\n")
      pendingId = ""
      pendingSecret = ""
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        saveConfigProc.errorText = String(text || "").trim()
        if (root.connectError !== "" && saveConfigProc.errorText !== "") root.connectError = saveConfigProc.errorText
      }
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.connecting = false
        root.connectError = saveConfigProc.errorText || "Failed to save credentials."
        return
      }

      clientIdField.text = ""
      clientSecretField.text = ""
      loginProc.running = true
    }
  }

  Process {
    id: loginProc
    property string errorText: ""
    command: root.binCommand("omawhoop-auth").concat(["login"])
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        loginProc.errorText = String(text || "").trim()
        if (root.connectError !== "" && loginProc.errorText !== "") root.connectError = loginProc.errorText
      }
    }
    onExited: function(exitCode) {
      root.connecting = false
      if (exitCode !== 0) {
        root.connectError = loginProc.errorText || "Authorization failed or timed out."
        return
      }
      root.connectError = ""
      root.refresh(true)
    }
  }

  property bool disconnecting: false

  function disconnectWhoop() {
    if (disconnectProc.running) return
    root.disconnecting = true
    disconnectProc.running = true
  }

  Process {
    id: disconnectProc
    command: root.binCommand("omawhoop-auth").concat(["logout"])
    onExited: function(exitCode) {
      root.disconnecting = false
      // logout always clears local tokens even if the remote revoke call
      // failed (see whoop_logout), so the panel can drop straight back to
      // the connect form regardless of exitCode.
      root.status = { error: "not_authenticated" }
    }
  }

  property bool removeAllOpen: false
  property bool removingAll: false

  function requestRemoveAllData() {
    if (root.removingAll) return
    removeAllConfirm.selectedIndex = 1
    root.removeAllOpen = true
  }

  function cancelRemoveAllData() {
    root.removeAllOpen = false
  }

  function confirmRemoveAllData() {
    root.removeAllOpen = false
    root.removingAll = true
    removeAllProc.running = true
  }

  Process {
    id: removeAllProc
    command: root.binCommand("omawhoop-auth").concat(["uninstall"])
    onExited: function(exitCode) {
      root.removingAll = false
      root.status = { error: "not_authenticated" }
    }
  }

  Process {
    id: statusProc
    command: root.binCommand("omawhoop-status")
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parsed = Model.parseStatus(text)
        if (parsed) root.status = parsed
      }
    }
  }

  property var history: []

  function refreshHistory(force) {
    if (historyProc.running) return
    historyProc.command = force ? root.binCommand("omawhoop-history").concat(["--force"]) : root.binCommand("omawhoop-history")
    historyProc.running = true
  }

  Process {
    id: historyProc
    command: root.binCommand("omawhoop-history")
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parsed = Model.parseHistory(text)
        if (parsed) root.history = parsed.days
      }
    }
  }

  Timer {
    interval: 15 * 60 * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      root.refresh(false)
      root.refreshHistory(false)
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(column.implicitHeight + Style.space(32))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.removeAllOpen
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: Style.space(16)
        spacing: Style.space(16)

        // ---- Not connected state: inline connect form.
        Column {
          visible: !root.authenticated
          width: parent.width
          spacing: Style.space(10)

          Text {
            text: "WHOOP not connected"
            color: root.barForeground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
          }
          Text {
            text: "One-time setup: create a free app at developer.whoop.com, then enter its credentials below."
            color: Qt.darker(root.barForeground, 1.4)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
            width: parent.width
          }

          Column {
            width: parent.width
            spacing: Style.space(4)
            topPadding: Style.space(4)

            Text {
              text: "REDIRECT URI (register this in the app)"
              color: Qt.darker(root.barForeground, 1.5)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.letterSpacing: 1
            }
            TextField {
              width: parent.width
              readOnly: true
              selectByMouse: true
              text: root.redirectUri
              foreground: root.barForeground
              font.family: root.bar.fontFamily
            }
          }

          TextField {
            id: clientIdField
            width: parent.width
            placeholderText: "Client ID"
            foreground: root.barForeground
            font.family: root.bar.fontFamily
            enabled: !root.connecting
            onTextChanged: if (!root.connecting) root.connectError = ""
          }

          TextField {
            id: clientSecretField
            width: parent.width
            placeholderText: "Client Secret"
            password: true
            foreground: root.barForeground
            font.family: root.bar.fontFamily
            enabled: !root.connecting
            onTextChanged: if (!root.connecting) root.connectError = ""
            Keys.onReturnPressed: root.submitConnect()
          }

          Text {
            visible: root.connectError !== ""
            text: Model.truncateMessage(root.connectError, 220)
            textFormat: Text.PlainText
            color: "#e5534b"
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.Wrap
            width: parent.width
          }

          Text {
            visible: root.waitingForBrowser
            text: "Complete the authorization in your browser…"
            color: Qt.darker(root.barForeground, 1.4)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.Wrap
            width: parent.width
          }

          Button {
            text: root.connecting ? "Connecting…" : "Connect WHOOP"
            bordered: true
            foreground: root.barForeground
            accent: Color.accent
            iconText: root.connecting ? "" : ""
            iconSpinning: root.connecting
            onClicked: root.submitConnect()
          }
        }

        // Connected state: rings + stats.
        Column {
          visible: root.authenticated
          width: parent.width
          spacing: Style.space(18)

          Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Style.space(18)

            RingGauge {
              value: root.status && root.status.recovery !== null && root.status.recovery !== undefined ? root.status.recovery : 0
              maxValue: 100
              hasValue: root.recoveryHasValue
              ringColor: root.recoveryColor
              centerText: root.recoveryLabel
              unitText: root.recoveryStateLabel
              label: "RECOVERY"
            }

            RingGauge {
              value: root.status && root.status.strain !== null && root.status.strain !== undefined ? root.status.strain : 0
              maxValue: root.strainMax
              hasValue: root.strainHasValue
              ringColor: root.strainColor
              centerText: root.strainLabel
              unitText: root.strainStateLabel
              label: "STRAIN"
            }

            RingGauge {
              value: root.status && root.status.sleep_pct !== null && root.status.sleep_pct !== undefined ? root.status.sleep_pct : 0
              maxValue: 100
              hasValue: root.sleepHasValue
              ringColor: root.sleepColor
              centerText: root.sleepLabel
              unitText: root.sleepDurationLabel
              label: "SLEEP"
            }
          }

          Rectangle {
            width: parent.width
            height: Style.spacing.hairline
            color: root.barForeground
            opacity: 0.12
          }

          Grid {
            anchors.horizontalCenter: parent.horizontalCenter
            columns: 3
            columnSpacing: Style.space(26)
            rowSpacing: Style.space(14)

            StatCell { label: "HRV"; value: root.hrvLabel }
            StatCell { label: "RHR"; value: root.rhrLabel }
            StatCell { label: "RESP"; value: root.respiratoryLabel }
            StatCell { label: "SPO2"; value: root.spo2Label }
            StatCell { label: "SKIN TEMP"; value: root.skinTempLabel }
            StatCell { label: "EFFICIENCY"; value: root.sleepEfficiencyLabel }
            StatCell { label: "CALORIES"; value: root.caloriesLabel }
            StatCell { label: "AVG HR"; value: root.avgHrLabel }
            StatCell { label: "MAX HR"; value: root.maxHrLabel }
          }

          Rectangle {
            width: parent.width
            height: Style.spacing.hairline
            color: root.barForeground
            opacity: 0.12
          }

          // 7-day Strain & Recovery trend
          Column {
            visible: root.history.length > 0
            width: parent.width
            spacing: Style.space(8)

            Text {
              text: "STRAIN & RECOVERY"
              color: Qt.darker(root.barForeground, 1.5)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.letterSpacing: 1
            }

            TrendChart {
              width: parent.width
              history: root.history
            }
          }

          // Footer
          Item {
            width: parent.width
            height: Math.max(footerLeft.implicitHeight, attributionRow.implicitHeight)

            Row {
              id: footerLeft
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: (root.stale ? "Stale · " : "") + "Updated " + root.updatedLabel
                color: Qt.darker(root.barForeground, 1.5)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
              }

              Button {
                anchors.verticalCenter: parent.verticalCenter
                iconText: ""
                tooltipText: "Refresh"
                foreground: root.barForeground
                accent: Color.accent
                fontFamily: root.bar.fontFamily
                horizontalPadding: Style.space(6)
                verticalPadding: Style.space(4)
                onClicked: root.refresh(true)
              }

              Button {
                anchors.verticalCenter: parent.verticalCenter
                enabled: !root.disconnecting
                iconText: root.disconnecting ? "" : ""
                iconSpinning: root.disconnecting
                tooltipText: root.disconnecting ? "Disconnecting…" : "Disconnect"
                foreground: root.barForeground
                accent: "#e5534b"
                fontFamily: root.bar.fontFamily
                horizontalPadding: Style.space(6)
                verticalPadding: Style.space(4)
                onClicked: root.disconnectWhoop()
              }

              Button {
                anchors.verticalCenter: parent.verticalCenter
                enabled: !root.removingAll
                iconText: root.removingAll ? "" : ""
                iconSpinning: root.removingAll
                tooltipText: root.removingAll ? "Removing data…" : "Remove all data"
                foreground: root.barForeground
                accent: "#e5534b"
                fontFamily: root.bar.fontFamily
                horizontalPadding: Style.space(6)
                verticalPadding: Style.space(4)
                onClicked: root.requestRemoveAllData()
              }
            }

            Row {
              id: attributionRow
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(6)

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "DATA BY"
                color: Qt.darker(root.barForeground, 1.6)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1.5
              }

              Image {
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(32)
                height: Style.space(32)
                source: Model.brandMarkColor(Color.popups.background) === "#ffffff" ? "whoop-mark-white.svg" : "whoop-mark-black.svg"
                fillMode: Image.PreserveAspectFit
                sourceSize.width: Math.round(width * Screen.devicePixelRatio)
                sourceSize.height: Math.round(height * Screen.devicePixelRatio)
              }
            }
          }
        }
      }

      ConfirmDialog {
        id: removeAllConfirm
        anchors.fill: parent
        z: 20
        opened: root.removeAllOpen
        message: "Remove all omawhoop data? This disconnects WHOOP and deletes your saved client ID/secret, tokens, and cache."
        confirmText: "Remove"
        background: Color.popups.background
        foreground: root.barForeground
        fontFamily: root.bar.fontFamily
        onCanceled: root.cancelRemoveAllData()
        onConfirmed: root.confirmRemoveAllData()
      }
    }
  }

  // WHOOP-style ring gauge
  component RingGauge: Item {
    id: gauge

    property real value: 0
    property real maxValue: 100
    property bool hasValue: true
    property color ringColor: Color.accent
    property color trackColor: Qt.rgba(1, 1, 1, 0.14)
    property string centerText: "—"
    property string unitText: ""
    property string label: ""
    readonly property real diameter: Style.space(94)
    readonly property real arcWidth: Style.space(7)
    readonly property real arcRadius: diameter / 2 - arcWidth
    property real fraction: hasValue && maxValue > 0 ? Math.max(0, Math.min(1, value / maxValue)) : 0

    width: diameter
    height: diameter + labelText.implicitHeight + Style.space(6)

    Behavior on fraction {
      NumberAnimation { duration: 500; easing.type: Easing.OutCubic }
    }

    Item {
      id: ring
      width: gauge.diameter
      height: gauge.diameter

      Shape {
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer

        ShapePath {
          strokeWidth: gauge.arcWidth
          strokeColor: gauge.trackColor
          fillColor: "transparent"
          capStyle: ShapePath.RoundCap

          PathAngleArc {
            centerX: ring.width / 2
            centerY: ring.height / 2
            radiusX: gauge.arcRadius
            radiusY: gauge.arcRadius
            startAngle: -90
            sweepAngle: 359.9
          }
        }

        ShapePath {
          strokeWidth: gauge.arcWidth
          strokeColor: gauge.hasValue ? gauge.ringColor : "transparent"
          fillColor: "transparent"
          capStyle: ShapePath.RoundCap

          PathAngleArc {
            centerX: ring.width / 2
            centerY: ring.height / 2
            radiusX: gauge.arcRadius
            radiusY: gauge.arcRadius
            startAngle: -90
            sweepAngle: 359.9 * gauge.fraction
          }
        }
      }

      Column {
        anchors.centerIn: parent
        spacing: 0

        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          text: gauge.centerText
          color: root.barForeground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.title
          font.bold: true
        }
        Text {
          visible: gauge.unitText !== ""
          anchors.horizontalCenter: parent.horizontalCenter
          text: gauge.unitText
          color: Qt.darker(root.barForeground, 1.5)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          horizontalAlignment: Text.AlignHCenter
        }
      }
    }

    Text {
      id: labelText
      anchors.top: ring.bottom
      anchors.topMargin: Style.space(6)
      anchors.horizontalCenter: parent.horizontalCenter
      text: gauge.label
      color: Qt.darker(root.barForeground, 1.4)
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.caption
      font.letterSpacing: 1
      font.bold: true
    }
  }

  component StatCell: Column {
    id: cell
    property string label: ""
    property string value: ""
    spacing: Style.space(4)

    Text {
      text: cell.label
      color: Qt.darker(root.barForeground, 1.5)
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.caption
      font.letterSpacing: 1
    }
    Text {
      text: cell.value
      color: root.barForeground
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.body
    }
  }

  component TrendChart: Item {
    id: chart

    property var history: []
    readonly property int dayCount: history.length
    readonly property var strainValues: history.map(function(d) { return d.strain })
    readonly property var recoveryValues: history.map(function(d) { return d.recovery })

    readonly property real topPad: Style.space(24)
    readonly property real innerHeight: Style.space(100)
    readonly property real bottomPad: Style.space(18)
    readonly property real labelsHeight: Style.space(28)

    readonly property var strainPoints: Model.chartPoints(strainValues, 0, root.strainMax, width, innerHeight)
    readonly property var recoveryPoints: Model.chartPoints(recoveryValues, 0, 100, width, innerHeight)
    readonly property var strainSegments: Model.chartSegments(strainPoints)
    readonly property var recoverySegments: Model.chartSegments(recoveryPoints)

    height: topPad + innerHeight + bottomPad + labelsHeight

    Item {
      id: plotArea
      y: chart.topPad
      width: chart.width
      height: chart.innerHeight

      Repeater {
        model: [0.0, 0.5, 1.0]
        Rectangle {
          required property real modelData
          y: modelData * plotArea.height
          width: plotArea.width
          height: Style.spacing.hairline
          color: root.barForeground
          opacity: 0.08
        }
      }

      Repeater {
        model: chart.strainSegments
        Shape {
          id: strainSegShape
          required property var modelData
          width: plotArea.width
          height: plotArea.height
          preferredRendererType: Shape.CurveRenderer

          ShapePath {
            strokeWidth: Style.space(2)
            strokeColor: root.strainColor
            fillColor: "transparent"
            capStyle: ShapePath.RoundCap
            joinStyle: ShapePath.RoundJoin

            PathPolyline {
              path: strainSegShape.modelData.map(function(p) { return Qt.point(p.x, p.y) })
            }
          }
        }
      }

      Repeater {
        model: chart.recoverySegments
        Shape {
          id: recoverySegShape
          required property var modelData
          width: plotArea.width
          height: plotArea.height
          preferredRendererType: Shape.CurveRenderer

          ShapePath {
            strokeWidth: Style.space(1.5)
            strokeColor: Qt.darker(root.barForeground, 1.1)
            fillColor: "transparent"
            capStyle: ShapePath.RoundCap
            joinStyle: ShapePath.RoundJoin

            PathPolyline {
              path: recoverySegShape.modelData.map(function(p) { return Qt.point(p.x, p.y) })
            }
          }
        }
      }

      Repeater {
        model: chart.strainPoints
        Item {
          id: strainMarker
          required property var modelData
          required property int index
          width: plotArea.width
          height: plotArea.height

          Rectangle {
            visible: strainMarker.modelData.y !== null
            x: strainMarker.modelData.x - width / 2
            y: strainMarker.modelData.y - height / 2
            width: Style.space(7)
            height: Style.space(7)
            radius: width / 2
            color: Color.popups.background
            border.color: root.strainColor
            border.width: Style.space(2)
          }

          Text {
            visible: strainMarker.modelData.y !== null
            text: Model.formatStrain(chart.strainValues[strainMarker.index])
            color: root.strainColor
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            x: strainMarker.modelData.x - implicitWidth / 2
            y: Math.max(0, strainMarker.modelData.y - implicitHeight - Style.space(6))
          }
        }
      }

      Repeater {
        model: chart.recoveryPoints
        Item {
          id: recoveryMarker
          required property var modelData
          required property int index
          width: plotArea.width
          height: plotArea.height
          readonly property color dotColor: Model.recoveryColor(chart.recoveryValues[index], root.barForeground)

          Rectangle {
            visible: recoveryMarker.modelData.y !== null
            x: recoveryMarker.modelData.x - width / 2
            y: recoveryMarker.modelData.y - height / 2
            width: Style.space(7)
            height: Style.space(7)
            radius: width / 2
            color: recoveryMarker.dotColor
          }

          Text {
            visible: recoveryMarker.modelData.y !== null
            text: Model.formatPercent(chart.recoveryValues[recoveryMarker.index])
            color: recoveryMarker.dotColor
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            x: recoveryMarker.modelData.x - implicitWidth / 2
            y: Math.min(plotArea.height - implicitHeight, recoveryMarker.modelData.y + Style.space(6))
          }
        }
      }
    }

    Item {
      id: dayLabels
      y: chart.topPad + chart.innerHeight + chart.bottomPad
      width: chart.width
      height: chart.labelsHeight

      Repeater {
        model: chart.history
        Column {
          id: dayLabel
          required property var modelData
          required property int index
          readonly property real px: chart.dayCount > 1 ? (index / (chart.dayCount - 1)) * dayLabels.width : dayLabels.width / 2
          x: px - width / 2
          spacing: 0

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: dayLabel.modelData.weekday
            color: Qt.darker(root.barForeground, 1.4)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
          }
          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: dayLabel.modelData.day
            color: Qt.darker(root.barForeground, 1.6)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }
}
