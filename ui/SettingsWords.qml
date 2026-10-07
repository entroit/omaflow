import QtQuick

// Names and jargon are what recognition gets wrong, and the words a person
// notices. This page is that list and nothing else.
Column {
  id: page
  required property var app
  spacing: 22
  property string filter: ""

  readonly property var shown: app.customVocabulary.filter(function(word) {
    return page.filter.trim().length === 0 || String(word).toLowerCase().indexOf(page.filter.trim().toLowerCase()) >= 0
  })
  // A word already in the list keeps what you typed and says so, rather than
  // clearing the field as if it had been added.
  function add(value) {
    var term = String(value || "").trim().replace(/\s+/g, " ")
    var existing = app.customVocabulary.find(function(word) { return String(word).toLowerCase() === term.toLowerCase() })
    if (existing !== undefined) {
      newWord.text = term
      newWord.problem = existing + " is already in your words."
        + (existing !== term ? " To change how it is written, remove it first." : "")
      return false
    }
    app.addVocabulary(term)
    newWord.text = ""
    return true
  }

  PageTitle { width: parent.width; title: "Words"; subtitle: "Names and terms you want spelled exactly. They apply with or without cleanup." }

  Row {
    width: parent.width
    spacing: 8
    Field {
      id: newWord
      width: parent.width - add.width - 8
      name: "Add a word"
      placeholderText: "Add a name, product or term"
      maximumLength: 80
      onTextChanged: problem = ""
      onAccepted: if (text.trim().length > 0) page.add(text)
    }
    Pill {
      id: add
      y: newWord.input.y + (newWord.input.height - height) / 2
      kind: "primary"; text: "Add word"; size: 13; verticalPadding: 9; horizontalPadding: 14
      enabled: newWord.text.trim().length > 0
      onClicked: page.add(newWord.text)
    }
  }

  SearchField {
    id: search
    visible: page.app.customVocabulary.length > 8
    width: parent.width
    placeholder: "Search " + page.app.customVocabulary.length + " words"
    onTextChanged: page.filter = text
    // A search that finds nothing is usually a word you meant to add.
    onAccepted: if (page.shown.length === 0 && text.trim().length > 0 && page.add(text)) text = ""
  }

  UiText {
    visible: page.filter.trim().length > 0 && page.shown.length === 0
    width: parent.width
    wrapMode: Text.Wrap
    muted: true
    text: "No word matches “" + page.filter.trim() + "”. Press Enter to add it."
  }

  Rectangle {
    visible: page.shown.length > 0
    width: parent.width
    height: table.implicitHeight
    radius: Theme.radiusCard + 2
    color: "transparent"
    border.width: 1
    border.color: Theme.divider

    Column {
      id: table
      width: parent.width
      Item {
        width: parent.width
        height: 38
        UiText { x: 14; anchors.verticalCenter: parent.verticalCenter; text: "Write it as"; muted: true; font.pixelSize: 12 }
      }
      Repeater {
        model: page.shown
        Item {
          required property var modelData
          width: table.width
          height: 42
          Rectangle { width: parent.width; height: 1; color: Theme.divider }
          // A long word, up to 80 characters, stops short of Remove.
          UiText { x: 14; width: remove.x - x - 12; anchors.verticalCenter: parent.verticalCenter; text: String(modelData); font.pixelSize: 14; weight: Font.DemiBold; elide: Text.ElideRight }
          Pill {
            id: remove
            anchors.right: parent.right
            anchors.rightMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            kind: "ghost"; text: "Remove"; size: 12
            Accessible.name: "Remove " + modelData
            onClicked: page.app.removeVocabulary(modelData)
          }
        }
      }
    }
  }

  UiText {
    visible: page.app.customVocabulary.length === 0
    width: parent.width
    wrapMode: Text.Wrap
    muted: true
    text: "Nothing here yet. Add a colleague's name or a product you say often, and it stops coming back spelled three different ways."
  }
}
