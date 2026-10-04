import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "."

Panel {
  id: root
  moduleName: "io.github.technologylab_ai.omagma"
  manageIpc: false
  property var anchorItem: null
  property var hostWidget: null
  property var service: null
  readonly property var barIdentity: hostWidget || root
  function layoutBounds() { return content.item ? content.item.layoutBounds() : null }
  onOpenedChanged: if (service) service.setVisible(opened)

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: content.item
    contentWidth: panel.fittedContentWidth(Style.space(772))
    contentHeight: panel.fittedContentHeight(Style.space(440))
    Loader {
      id: content
      anchors.fill: parent
      active: root.opened && root.service !== null
      sourceComponent: Component {
        MailView {
          service: root.service
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          bodyFontSize: Style.font.bodySmall
          captionFontSize: Style.font.caption
          headingFontSize: Style.font.body
          layoutScale: Style.effectiveSpacingScale
          foreground: root.bar ? root.bar.foreground : Color.foreground
          background: Color.popups.background
          onCloseRequested: root.close()
          onLaunched: root.close()
        }
      }
      onLoaded: Qt.callLater(function() { if (content.item) content.item.forceActiveFocus() })
    }
  }
}
