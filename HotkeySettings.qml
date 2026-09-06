import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Layouts
import Quickshell.Io
import qs.Commons
import qs.Ui

ColumnLayout {
  id: page
  required property var flow
  property string statusText: ""
  property bool failed: false
  spacing: Style.space(8)
  Text { Layout.fillWidth:true; text:"Use XKB key names joined with +. For example F9, or Control_L + Shift_L + F9."; wrapMode:Text.Wrap; color:Util.alpha(Color.popups.text,0.65); font.family:Style.font.family; font.pixelSize:Style.font.caption }
  TextField { id:keys; Layout.fillWidth:true; text:(page.flow.shortcutSettings.keys || []).join(" + "); placeholderText:"Trigger keys"; foreground:Color.popups.text; maximumLength:160; Accessible.name:"Dictation trigger keys" }
  TextField { id:reserved; Layout.fillWidth:true; text:(page.flow.shortcutSettings.consumed || []).join(" + "); placeholderText:"Keys to reserve globally (optional)"; foreground:Color.popups.text; maximumLength:160; Accessible.name:"Globally reserved keys" }
  Text { Layout.fillWidth:true; text:"Reserved keys are swallowed in every application, even outside the chord. Reserve a dedicated key such as Menu or F13; avoid letters and Space."; wrapMode:Text.Wrap; color:Util.alpha(Color.popups.text,0.65); font.family:Style.font.family; font.pixelSize:Style.font.caption }
  RowLayout {
    ActionButton { text:save.running ? "Saving…" : "Save shortcut"; enabled:!save.running && keys.text.trim().length>0; onClicked: { page.statusText=""; save.command=["python3", page.flow.pluginDir+"/tools/set_hotkey.py", "--keys", keys.text, "--consumed", reserved.text]; save.running=true } }
    ActionButton { text:"AltGr + Menu"; onClicked: { keys.text="ISO_Level3_Shift + Menu"; reserved.text="Menu" } }
    ActionButton { text:"F13"; onClicked: { keys.text="F13"; reserved.text="F13" } }
  }
  Text { Layout.fillWidth:true; visible:text.length>0; text:page.statusText; wrapMode:Text.Wrap; color:page.failed ? Color.urgent : Color.accent; font.family:Style.font.family; font.pixelSize:Style.font.caption }
  Process {
    id:save
    stdout: StdioCollector { onStreamFinished: { try { var response=JSON.parse(text); page.statusText=response.message; page.failed=!response.ok } catch(error) { page.failed=true; page.statusText="Could not save shortcut. Check that Python and Hyprland are running." } } }
    stderr: StdioCollector { onStreamFinished: if(text.trim()) { page.failed=true; page.statusText=text.trim() } }
  }
}
