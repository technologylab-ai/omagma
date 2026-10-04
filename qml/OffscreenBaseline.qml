import QtQuick
import Quickshell

ShellRoot {
  id: root
  readonly property real fontBase: Number(Quickshell.env("OMAGMA_TEST_FONT_BASE")) || 9
  readonly property real uiScale: fontBase / 12
  FloatingWindow {
    title: "omagma offscreen memory baseline"
    implicitWidth: Math.round(740 * root.uiScale)
    implicitHeight: Math.round(440 * root.uiScale)
    color: "#151c26"
    visible: Quickshell.env("QT_QPA_PLATFORM") === "offscreen"
    MailButton { anchors.centerIn: parent; text: "Synthetic memory baseline"; fontSize: Math.round(root.fontBase * 0.917); layoutScale: root.uiScale }
  }
}
