import QtQuick
import QtQuick.Controls

Button {
  id: root
  property color foreground: "#e4e7ed"
  property color accent: "#87b9ef"
  property string fontFamily: "sans-serif"
  property real fontSize: 11
  property real layoutScale: 1
  function px(value) { return Math.max(1, Math.round(value * layoutScale)) }
  leftPadding: px(8)
  rightPadding: px(8)
  topPadding: px(2)
  bottomPadding: px(2)
  activeFocusOnTab: true
  implicitHeight: px(24)
  contentItem: Text {
    text: root.text
    textFormat: Text.PlainText
    color: root.enabled ? root.foreground : "#7e8794"
    font.family: root.fontFamily
    font.pixelSize: root.fontSize
    elide: Text.ElideRight
    horizontalAlignment: Text.AlignHCenter
    verticalAlignment: Text.AlignVCenter
  }
  background: Rectangle {
    radius: 4
    color: !root.enabled ? "#1b2330" : root.down ? "#35475e" : root.hovered ? "#2c3746" : "#222c3a"
    border.width: root.activeFocus ? 2 : 1
    border.color: root.activeFocus ? root.accent : root.enabled ? "#3c4857" : "#2c3644"
  }
}
