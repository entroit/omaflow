import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui

// Names and jargon are what recognition gets wrong, and they are the words a
// person notices. This page is nothing but that list.
ColumnLayout {
  id: page

  required property var flow

  spacing: Style.space(10)

  SettingsHeading {
    title: "Custom vocabulary"
    note: "Names, products and technical terms you want spelled exactly. They are used whether or not cleanup is on."
  }

  Repeater {
    model: page.flow.customVocabulary

    Rectangle {
      required property var modelData
      Layout.fillWidth: true
      Layout.preferredHeight: vocabularyRow.implicitHeight + Style.space(10)
      radius: Style.cornerRadius
      color: Util.alpha(Color.popups.text, 0.045)

      RowLayout {
        id: vocabularyRow
        anchors.fill: parent
        anchors.leftMargin: Style.space(10)
        anchors.rightMargin: Style.space(6)

        Text {
          Layout.fillWidth: true
          textFormat: Text.PlainText
          wrapMode: Text.Wrap
          text: String(modelData)
          color: Color.popups.text
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }

        ActionButton {
          text: "Remove"
          foreground: Util.alpha(Color.popups.text, 0.62)
          onClicked: page.flow.removeVocabulary(modelData)
        }
      }
    }
  }

  Text {
    visible: page.flow.customVocabulary.length === 0
    Layout.fillWidth: true
    textFormat: Text.PlainText
    wrapMode: Text.Wrap
    text: "Nothing here yet. Add a colleague's name or a product you say often, and it will stop coming back spelled three different ways."
    color: Util.alpha(Color.popups.text, 0.5)
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
  }

  RowLayout {
    Layout.fillWidth: true
    spacing: Style.space(8)

    TextField {
      id: vocabularyField
      Layout.fillWidth: true
      foreground: Color.popups.text
      accent: Color.accent
      placeholderText: "Add a word or phrase"
      maximumLength: 80
      onAccepted: {
        page.flow.addVocabulary(text)
        text = ""
        focus = false
      }
    }

    ActionButton {
      text: "Add"
      foreground: Color.popups.text
      background: Util.alpha(Color.accent, 0.22)
      bordered: true
      enabled: vocabularyField.text.trim().length > 0
      onClicked: {
        page.flow.addVocabulary(vocabularyField.text)
        vocabularyField.text = ""
      }
    }
  }
}
