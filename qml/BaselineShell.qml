import QtQuick
import Quickshell
import Quickshell.Wayland

ShellRoot {
  PanelWindow {
    WlrLayershell.namespace: "omagma-test-baseline"
    WlrLayershell.layer: WlrLayer.Overlay
    anchors.top: true
    anchors.left: true
    margins.top: 50
    margins.left: 100
    exclusionMode: ExclusionMode.Ignore
    implicitWidth: 1030
    implicitHeight: 74
    color: "#151c26"
    visible: true
    Row {
      anchors.centerIn: parent
      spacing: 18
      MailButton { text: "Open synthetic Inbox" }
      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: "Fixture mode · no Gmail/keyring · Chrome opening disabled"
        textFormat: Text.PlainText
        color: "#a2adbd"
        font.pixelSize: 13
      }
    }
  }
}
