import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "../Model.mjs" as Model

FocusScope {
  id: root
  required property var service
  property color background: "#151c26"
  property color foreground: "#e4e7ed"
  property color muted: "#a2adbd"
  property color accent: "#87b9ef"
  property color warning: "#e8ba79"
  property string fontFamily: "sans-serif"
  property real bodyFontSize: 11
  property real captionFontSize: 10
  property real headingFontSize: 12
  property real layoutScale: 1
  function px(value) { return Math.max(1, Math.round(value * layoutScale)) }
  function layoutBounds() {
    const at = headerClose.mapToItem(root, 0, 0)
    return { width: root.width, height: root.height, closeX: at.x, closeY: at.y,
      closeWidth: headerClose.width, closeHeight: headerClose.height }
  }
  property double nowMs: Date.now()
  property string selectedMessageId: ""
  readonly property var account: service.currentAccount
  readonly property var selectedMessage: account.messages.find(row => row.id === selectedMessageId) || null
  // Sized from the longest bold address so account identity is never elided.
  readonly property int sidebarWidth: Math.max(px(180), Math.ceil(addressMetrics.advanceWidth) + px(16))
  signal closeRequested()
  signal launched()

  // One shot per freshness expiry while this view exists. No polling and no
  // timer survives popup destruction. Cached counts always remain dated.
  function scheduleFreshness() {
    freshness.stop()
    nowMs = Date.now()
    let next = Infinity
    for (const item of service.accounts) {
      const due = item.checkedAt * 1000 + 60001
      if (item.state === "current" && item.checkedAt > 0 && due > nowMs) next = Math.min(next, due)
    }
    if (isFinite(next)) { freshness.interval = Math.max(1, next - nowMs); freshness.start() }
  }
  Timer { id: freshness; repeat: false; onTriggered: root.scheduleFreshness() }
  Component.onCompleted: { scheduleFreshness(); Qt.callLater(root.focusList) }
  function focusList() { messages.forceActiveFocus() }
  function moveSelection(delta) {
    if (!account.messages.length) return
    const index = account.messages.findIndex(row => row.id === selectedMessageId)
    const next = Math.max(0, Math.min(account.messages.length - 1, index + delta))
    selectedMessageId = account.messages[next].id
    messages.positionViewAtIndex(next, ListView.Contain)
  }
  function warns(item) {
    return Model.hasAccountWarning(item, nowMs)
  }
  // Compact stamp for rows and the sidebar: time today, day and month otherwise.
  function shortStamp(ms) {
    if (!ms) return "—"
    const date = new Date(ms)
    return date.toDateString() === new Date(nowMs).toDateString()
      ? date.toLocaleTimeString(Qt.locale(), Locale.ShortFormat)
      : date.toLocaleDateString(Qt.locale(), "d MMM")
  }
  onAccountChanged: {
    nowMs = Date.now()
    if (!account.messages.some(row => row.id === selectedMessageId)) selectedMessageId = ""
  }

  Keys.onPressed: function(event) {
    if (event.key === Qt.Key_Escape) root.closeRequested()
    else if (event.key === Qt.Key_R && (event.modifiers & Qt.ControlModifier)) service.refresh()
    else if (event.modifiers & Qt.ControlModifier && event.key >= Qt.Key_1 && event.key <= Qt.Key_3) {
      const target = service.accounts[event.key - Qt.Key_1]
      if (target) service.selectAccount(target.account)
    }
    else if (event.key === Qt.Key_Down) root.moveSelection(1)
    else if (event.key === Qt.Key_Up) root.moveSelection(-1)
    else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && root.selectedMessage)
      service.openMessage(root.selectedMessage.id)
    else return
    event.accepted = true
  }

  Connections {
    target: root.service
    function onAccountsChanged() { root.scheduleFreshness() }
    function onSelectedChanged() { root.selectedMessageId = ""; root.nowMs = Date.now() }
    function onOpenCompleted(success) { if (success) root.launched() }
  }

  TextMetrics {
    id: addressMetrics
    font.family: root.fontFamily
    font.pixelSize: root.bodyFontSize
    font.bold: true
    text: root.service.accounts.reduce((longest, item) =>
      item.account.length > longest.length ? item.account : longest, "")
  }

  Rectangle { anchors.fill: parent; color: root.background; radius: 8 }
  RowLayout {
    anchors.fill: parent
    anchors.margins: root.px(6)
    spacing: root.px(6)

    ColumnLayout {
      Layout.preferredWidth: root.sidebarWidth
      Layout.minimumWidth: root.sidebarWidth
      Layout.maximumWidth: root.sidebarWidth
      Layout.fillHeight: true
      spacing: root.px(3)
      RowLayout {
        Layout.fillWidth: true
        Layout.leftMargin: root.px(6)
        Layout.preferredHeight: root.px(21)
        Layout.minimumHeight: root.px(21)
        Layout.maximumHeight: root.px(21)
        spacing: root.px(5)
        Image {
          Layout.preferredWidth: root.px(16)
          Layout.preferredHeight: root.px(16)
          source: Qt.resolvedUrl("../assets/omagma-logo.png")
          sourceSize.width: 48
          sourceSize.height: 48
          fillMode: Image.PreserveAspectFit
          smooth: true
        }
        Text {
          Layout.fillWidth: true
          text: "omagma"
          textFormat: Text.PlainText
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: root.headingFontSize
          font.bold: true
        }
      }
      Repeater {
        model: root.service.accounts
        delegate: Button {
          id: accountButton
          required property var modelData
          readonly property bool isSelected: modelData.account === root.service.selected
          Layout.fillWidth: true
          implicitHeight: root.px(44)
          leftPadding: root.px(6)
          rightPadding: root.px(6)
          topPadding: root.px(5)
          bottomPadding: root.px(5)
          activeFocusOnTab: true
          onClicked: { root.service.selectAccount(modelData.account); root.focusList() }
          background: Rectangle {
            radius: 5
            color: accountButton.isSelected ? "#26394d" : accountButton.hovered ? "#24303f" : "#1c2532"
            border.width: accountButton.activeFocus ? 2 : 1
            border.color: accountButton.activeFocus ? root.accent
              : accountButton.isSelected ? "#537a9d" : "#303d4d"
          }
          contentItem: Column {
            spacing: root.px(2)
            Text {
              width: parent.width
              text: accountButton.modelData.account
              textFormat: Text.PlainText
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: root.bodyFontSize
              font.bold: accountButton.isSelected
              // Never elide account identity or replace it with a short name.
            }
            Item {
              width: parent.width
              height: Math.max(stamp.implicitHeight, count.implicitHeight)
              Text {
                id: stamp
                anchors.left: parent.left
                anchors.right: count.left
                anchors.rightMargin: root.px(6)
                anchors.baseline: count.baseline
                text: Model.stateLabel(accountButton.modelData, root.nowMs)
                  + (accountButton.modelData.checkedAt ? " · " + root.shortStamp(accountButton.modelData.checkedAt * 1000) : "")
                textFormat: Text.PlainText
                elide: Text.ElideRight
                color: root.warns(accountButton.modelData) ? root.warning : root.muted
                font.family: root.fontFamily
                font.pixelSize: root.captionFontSize
              }
              Text {
                id: count
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                // This account's whole-Inbox unread count; never summed across accounts.
                text: accountButton.modelData.unread === null ? "—" : String(accountButton.modelData.unread) + " unread"
                textFormat: Text.PlainText
                color: accountButton.modelData.unread ? root.accent : root.muted
                font.family: root.fontFamily
                font.pixelSize: root.bodyFontSize
                font.bold: accountButton.modelData.unread > 0
              }
            }
          }
        }
      }
      Item { Layout.fillHeight: true }
    }

    Rectangle { Layout.fillHeight: true; implicitWidth: 1; color: "#354151" }

    ColumnLayout {
      Layout.fillWidth: true
      Layout.minimumWidth: 0
      Layout.fillHeight: true
      spacing: root.px(5)
      ColumnLayout {
        Layout.fillWidth: true
        Layout.minimumWidth: 0
        spacing: root.px(2)
        RowLayout {
          Layout.fillWidth: true
          spacing: root.px(5)
          Text {
            Layout.fillWidth: true
            Layout.minimumWidth: 0
            elide: Text.ElideRight
            text: root.account.account
            textFormat: Text.PlainText
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: root.headingFontSize
            font.bold: true
          }
          MailButton {
            text: "Open inbox"
            fontFamily: root.fontFamily
            fontSize: root.bodyFontSize
            layoutScale: root.layoutScale
            foreground: root.foreground
            accent: root.accent
            onClicked: root.service.openInbox()
          }
          MailButton {
            // Fixed label avoids header reflow; loading shows in the status line.
            text: "Refresh"
            fontFamily: root.fontFamily
            fontSize: root.bodyFontSize
            layoutScale: root.layoutScale
            foreground: root.foreground
            accent: root.accent
            enabled: root.account.enabled && root.account.state !== "loading"
            onClicked: { root.nowMs = Date.now(); root.service.refresh() }
          }
          MailButton {
            id: headerClose
            text: "×"
            implicitWidth: root.px(22)
            fontFamily: root.fontFamily
            fontSize: root.bodyFontSize
            layoutScale: root.layoutScale
            foreground: root.foreground
            accent: root.accent
            Accessible.name: "Close"
            onClicked: root.closeRequested()
          }
        }
        Text {
          Layout.fillWidth: true
          text: (root.service.fixtures ? "Demo mail · " : "") + Model.stateLabel(root.account, root.nowMs) + " · " + Model.checkedLabel(root.account) + " · "
            + (root.account.unread === null ? "unread count unavailable" : root.account.unread + " unread in Inbox")
          textFormat: Text.PlainText
          color: root.warns(root.account) ? root.warning : root.muted
          font.family: root.fontFamily
          font.pixelSize: root.captionFontSize
          wrapMode: Text.WordWrap
        }
      }
      Text {
        Layout.fillWidth: true
        Layout.minimumWidth: 0
        visible: text !== ""
        text: root.account.error || root.service.lastError
        textFormat: Text.PlainText
        color: root.warning
        font.family: root.fontFamily
        font.pixelSize: root.captionFontSize
        wrapMode: Text.WordWrap
        maximumLineCount: 2
        elide: Text.ElideRight
      }
      Rectangle {
        Layout.fillWidth: true
        Layout.fillHeight: true
        Layout.minimumHeight: root.px(80)
        color: "#111822"
        radius: 5
        border.color: messages.activeFocus ? "#537a9d" : "#303d4d"

        ListView {
          id: messages
          anchors.fill: parent
          anchors.margins: 1
          clip: true
          model: root.account.messages
          boundsBehavior: Flickable.StopAtBounds
          cacheBuffer: 0
          reuseItems: true
          focus: true
          activeFocusOnTab: true
          // Up/Down must reach root.moveSelection rather than currentIndex.
          keyNavigationEnabled: false
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
          delegate: Rectangle {
            id: messageRow
            required property var modelData
            width: messages.width
            height: root.px(40)
            color: root.selectedMessageId === modelData.id ? "#293d53" : rowMouse.containsMouse ? "#202d3d" : "transparent"
            Column {
              anchors.left: parent.left
              anchors.leftMargin: root.px(16)
              anchors.right: parent.right
              anchors.rightMargin: root.px(8)
              anchors.verticalCenter: parent.verticalCenter
              spacing: root.px(2)
              Item {
                width: parent.width
                height: sender.implicitHeight
                Rectangle {
                  anchors.right: sender.left
                  anchors.rightMargin: root.px(5)
                  anchors.verticalCenter: sender.verticalCenter
                  width: root.px(5)
                  height: root.px(5)
                  radius: root.px(3)
                  color: root.accent
                  visible: messageRow.modelData.unread
                }
                Text {
                  id: sender
                  anchors.left: parent.left
                  anchors.right: received.left
                  anchors.rightMargin: root.px(6)
                  text: messageRow.modelData.sender || "(Unknown sender)"
                  textFormat: Text.PlainText
                  elide: Text.ElideRight
                  color: root.muted
                  font.family: root.fontFamily
                  font.pixelSize: root.captionFontSize
                  font.bold: messageRow.modelData.unread
                }
                Text {
                  id: received
                  anchors.right: parent.right
                  anchors.baseline: sender.baseline
                  text: root.shortStamp(messageRow.modelData.receivedAt)
                  textFormat: Text.PlainText
                  color: root.muted
                  font.family: root.fontFamily
                  font.pixelSize: root.captionFontSize
                }
              }
              Item {
                width: parent.width
                height: subject.implicitHeight
                TextMetrics {
                  id: subjectMetrics
                  font: subject.font
                  text: subject.text
                }
                Text {
                  id: subject
                  // Measure independently of the elided Text's geometry, and
                  // let long subjects use the full line; snippets use any remainder.
                  width: Math.min(subjectMetrics.advanceWidth,
                    parent.width)
                  text: messageRow.modelData.subject || "(No subject)"
                  textFormat: Text.PlainText
                  elide: Text.ElideRight
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: root.bodyFontSize
                  font.bold: messageRow.modelData.unread
                }
                Text {
                  x: subject.width + root.px(5)
                  width: Math.max(0, parent.width - x)
                  anchors.baseline: subject.baseline
                  visible: width >= root.px(40) && messageRow.modelData.snippet !== ""
                  text: "– " + messageRow.modelData.snippet
                  textFormat: Text.PlainText
                  elide: Text.ElideRight
                  color: root.muted
                  font.family: root.fontFamily
                  font.pixelSize: root.captionFontSize
                }
              }
            }
            Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: "#1c2532" }
            MouseArea {
              id: rowMouse
              anchors.fill: parent
              hoverEnabled: true
              onClicked: { root.selectedMessageId = messageRow.modelData.id; root.focusList() }
              onDoubleClicked: root.service.openMessage(messageRow.modelData.id)
            }
          }
        }
        Text {
          anchors.centerIn: parent
          width: parent.width - 40
          visible: root.account.messages.length === 0
          text: Model.emptyLabel(root.account, root.nowMs)
          textFormat: Text.PlainText
          horizontalAlignment: Text.AlignHCenter
          wrapMode: Text.WordWrap
          color: root.muted
          font.family: root.fontFamily
          font.pixelSize: root.bodyFontSize
        }
      }
      Rectangle {
        Layout.fillWidth: true
        Layout.minimumWidth: 0
        Layout.preferredHeight: root.px(80)
        visible: root.selectedMessage !== null
        color: "#1c2633"
        radius: 5
        ColumnLayout {
          anchors.fill: parent
          anchors.leftMargin: root.px(8)
          anchors.rightMargin: root.px(6)
          anchors.topMargin: root.px(5)
          anchors.bottomMargin: root.px(5)
          spacing: root.px(2)
          RowLayout {
            Layout.fillWidth: true
            Layout.minimumWidth: 0
            spacing: root.px(6)
            Text {
              Layout.fillWidth: true
              Layout.minimumWidth: 0
              text: root.selectedMessage ? root.selectedMessage.subject || "(No subject)" : "No message selected"
              textFormat: Text.PlainText
              elide: Text.ElideRight
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: root.bodyFontSize
              font.bold: true
            }
            MailButton {
              text: "Open in Gmail"
              fontFamily: root.fontFamily
            fontSize: root.bodyFontSize
            layoutScale: root.layoutScale
              foreground: root.foreground
              accent: root.accent
              enabled: root.selectedMessage !== null && !root.service.fixtures
              onClicked: root.service.openMessage(root.selectedMessage.id)
            }
          }
          Text {
            Layout.fillWidth: true
            Layout.minimumWidth: 0
            Layout.fillHeight: true
            text: root.selectedMessage ? root.selectedMessage.snippet
              : "Enter opens · Ctrl+R refreshes · Ctrl+1–3 switches account · Esc closes"
            textFormat: Text.PlainText
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: root.captionFontSize
            wrapMode: Text.WordWrap
            maximumLineCount: 3
            elide: Text.ElideRight
          }
        }
      }
      Text {
        Layout.fillWidth: true
        Layout.minimumWidth: 0
        visible: root.selectedMessage === null
        text: "Enter opens · Ctrl+R refreshes · Ctrl+1–3 switches account · Esc closes"
        textFormat: Text.PlainText
        color: root.muted
        font.family: root.fontFamily
        font.pixelSize: root.captionFontSize
        elide: Text.ElideRight
      }
    }
  }
}
