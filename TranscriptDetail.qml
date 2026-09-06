import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Ui

ColumnLayout {
  id: detail
  required property var flow
  required property var entry
  property bool original: false
  property string draft: ""
  property string currentId: ""
  function loadEntry() { if (entry && String(entry.id) !== currentId) { currentId=String(entry.id); draft=String(entry.text || "") } }
  Component.onCompleted: loadEntry()
  onEntryChanged: loadEntry()
  spacing: Style.space(8)

  RowLayout {
    Layout.fillWidth: true
    ActionButton { text: "Back"; onClicked: detail.flow.selectedEntryId = "" }
    Item { Layout.fillWidth: true }
    ActionButton { text:"Paste"; visible:!detail.original && detail.flow.pasteMode !== "clipboard"; onClicked:detail.flow.pasteHistory(detail.entry.id) }
    ActionButton {
      text: detail.original ? "Show edited" : "Show original"
      enabled: Boolean(detail.entry && detail.entry.raw_text)
      onClicked: detail.original = !detail.original
    }
    ActionButton {
      text: "Copy"
      onClicked: Quickshell.execDetached(["omaflow", detail.original ? "history-raw" : "history-copy", String(detail.entry.id)])
    }
  }
  Text {
    Layout.fillWidth: true
    text: detail.original ? "Original recognition (read only)" : "Review or correct your dictation. Save before copying changes."
    wrapMode: Text.Wrap
    color: Color.popups.text
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
  }
  Text { Layout.fillWidth:true; visible:detail.entry && Boolean(detail.entry.cleanup_warning); text:detail.entry ? String(detail.entry.cleanup_warning || "") : ""; wrapMode:Text.Wrap; textFormat:Text.PlainText; color:Color.urgent; font.family:Style.font.family; font.pixelSize:Style.font.caption }
  Controls.ScrollView {
    Layout.fillWidth: true
    Layout.fillHeight: true
    clip: true
    Controls.TextArea {
      id: editor
      text: detail.original ? String(detail.entry.raw_text || detail.entry.text) : detail.draft
      readOnly: detail.original
      selectByMouse: true
      wrapMode: TextEdit.Wrap
      textFormat: TextEdit.PlainText
      color: Color.popups.text
      selectionColor: Color.accent
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      background: Rectangle { color: Util.alpha(Color.popups.text, 0.04) }
      onTextChanged: if (!detail.original) detail.draft = text
      Accessible.name: detail.original ? "Original transcription" : "Edit transcription"
    }
  }
  RowLayout {
    Layout.fillWidth: true
    ActionButton {
      text: "Delete"
      foreground: Color.urgent
      onClicked: { detail.flow.deleteHistory(detail.entry.id); detail.flow.selectedEntryId = "" }
    }
    Item { Layout.fillWidth: true }
    ActionButton {
      text: detail.original ? "Restore original" : "Save changes"
      onClicked: {
        var value = detail.original ? String(detail.entry.raw_text || detail.entry.text) : detail.draft
        Quickshell.execDetached(["omaflow", "history-edit", String(detail.entry.id), value])
        if (detail.original) { detail.draft = value; detail.original = false }
      }
    }
  }
}
