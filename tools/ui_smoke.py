#!/usr/bin/env python3
"""Render actual QML views with synthetic data and installed Omarchy components.
Does not run dictation, copy text, change settings, or replace the live shell.
Layer-shell placement and physical keyboard/audio tests remain desktop checks.
"""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile
ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--output", type=Path)
args = parser.parse_args()
output = args.output or Path(tempfile.mkdtemp(prefix="omaflow-ui-images-"))
output.mkdir(parents=True, exist_ok=True)
output = output.resolve()
shell = Path(os.environ.get("OMARCHY_PATH", "/usr/share/omarchy"))/"shell"
if not shell.is_dir(): raise SystemExit("UI smoke tests require an installed Omarchy shell")
with tempfile.TemporaryDirectory(prefix="omaflow-ui-smoke-") as staging:
    p=Path(staging)
    for d in shell.iterdir():
        if d.is_dir() and not (p/d.name).exists(): (p/d.name).symlink_to(d,target_is_directory=True)
    s=(ROOT/'OmaFlow.qml').read_text()
    s=s.replace('import QtQuick\n','import QtQuick\nimport QtQuick.Window\n',1).replace('Panel {','Item {',1)
    s=s.replace('  moduleName: "entroit.omaflow"\n  ipcTarget: "entroit.omaflow"','''  property bool opened: true
      property var bar: null
      property QtObject controller: QtObject { function hide() {} function show() {} }
      function auditExec(args) {}
      property string auditMode: Quickshell.env("AUDIT_MODE") || "history"
    ''',1)
    s=s.replace('implicitWidth: barButton.implicitWidth','implicitWidth: 520').replace('implicitHeight: barButton.implicitHeight','implicitHeight: 610')
    s=s.replace('Quickshell.execDetached','root.auditExec')
    a=s.index('  onMeterPreviewActiveChanged:'); b=s.index('  Component {\n    id: pillBarsIcon',a); s=s[:a]+s[b:]
    a=s.index('  BarIconButton {'); b=s.index('  component Waveform:',a); s=s[:a]+s[b:]
    s=s[:-2]+'''
      Component.onCompleted: {
        root.stateVersion = 2; root.connected = true
        root.asrRunning = true; root.cleanupLoaded = true; root.cleanupAvailable = true
        root.trainingLogEnabled = true; root.gpuMemoryMib = 6300
        root.runningVersion = "0.14.0"; root.hotkeyDisplay = "AltGr + Menu"
        root.modelSettings = {speech_engine:"nemo",speech_model:"nvidia/parakeet-tdt-0.6b-v3",speech_endpoint:"http://127.0.0.1:18103/v1/audio/transcriptions",speech_device:"cuda",speech_language:"auto",cleanup_model:"gemma4:e4b",cleanup_endpoint:"http://127.0.0.1:11434/api/chat"}
        root.shortcutSettings = {keys:["ISO_Level3_Shift","Menu"],consumed:["Menu"]}
        root.customVocabulary = ["OmaFlow", "Omarchy", "Hyprland", "Parakeet", "Gemma", "Quickshell"]
        root.transcript = "The completed transcript is safely on your clipboard. This is a synthetic audit sample."
        root.errorText = "OmaFlow could not reach the microphone. Check the input device in your sound settings."
        if (auditMode.indexOf("settings") === 0) root.idlePage = "settings"
        else if (auditMode !== "history" && auditMode !== "empty") root.phase = auditMode
        if (auditMode === "recording") { root.latched=true; root.micDetected=true; root.micLevel=0.5; root.micBars=[0.1,0.3,0.2,0.6,0.4,0.2,0.1,0.3,0.5,0.2,0.3,0.4,0.1]; root.waveHistory=[0.1,0.35,0.6,0.75,0.55,0.3,0.15,0.4,0.7,0.65,0.45,0.25] }
        if (auditMode === "recording-held") { root.phase="recording"; root.latched=false; root.micDetected=true; root.micLevel=0.5 }
        if (auditMode === "detail") { root.phase="idle"; root.selectedEntryId="2" }
        if (auditMode === "warning") { root.phase="result"; root.errorText=""; root.pasteSent=true; root.feedbackError=true; root.feedback="Cleanup changed a number. The original transcript was preserved." }
        if (auditMode.indexOf("settings-models") === 0) { root.editModels=true }
        if (auditMode.indexOf("settings-models-pending") === 0) { root.modelSettings = Object.assign({}, root.modelSettings, {configured:false}) }
        if (auditMode === "hotkey") { root.phase="idle"; root.idlePage="settings"; root.editShortcut=true }
        if (auditMode !== "empty") root.history = [
          {id:1, created_at_ms:Date.now(), text:"Please send the updated proposal to the team before Thursday's meeting. I've added the revised timeline and the notes from our last review."},
          {id:2, created_at_ms:Date.now()-300000, text:"The client approved the new layout. Let's finish the mobile version this week and schedule a final review for Monday. Please check the contact form, update the pricing page, and make sure the links in the footer work before we send it over. I'll prepare the handover notes and share them with the team."},
          {id:3, created_at_ms:Date.now()-3600000, text:"I've uploaded the meeting notes to the shared folder. Let me know if I missed anything."}
        ]
      }
      Window {
        width: root.phase === "idle" ? 560 : root.overlayWidth
        height: root.phase === "idle" ? 650 : root.overlayHeight
        visible: true
        color: Color.popups.background
        Item {
          id: captureFrame
          anchors.fill: parent
          Rectangle { anchors.fill:parent; color:Color.popups.background }
          FocusReveal { scope:captureFrame }
          Loader {
            id: auditLoader
            anchors.fill: parent
            anchors.margins: 12
            sourceComponent: root.phase === "idle" ? idleView
              : root.phase === "recording" ? recordingView
              : root.phase === "processing" ? processingView
              : root.phase === "success" ? successView
              : root.phase === "notice" ? noticeView
              : root.phase === "result" ? resultView : errorView
          }
        }
        Timer {
          interval: 500; running:true
          onTriggered: { if (root.auditMode === "settings-model-status") auditLoader.item.moveCursor(10)
            if (root.auditMode === "settings-bottom") auditLoader.item.moveCursor(100)
            if ((root.auditMode === "settings-models" || root.auditMode === "settings-models-pending")) auditLoader.item.moveCursor(12)
            if (root.auditMode === "settings-models-bottom") auditLoader.item.moveCursor(21)
            if (root.auditMode === "settings-models-pending-bottom") auditLoader.item.moveCursor(23) }
        }
        Timer {
          interval: 1000; running:true
          onTriggered: captureFrame.grabToImage(function(result) {
            result.saveToFile(Quickshell.env("OMAFLOW_UI_OUTPUT")+"/"+root.auditMode+".png")
            Qt.quit()
          })
        }
      }
    }
    '''
    (p/'shell.qml').write_text(s)

    for component in ROOT.glob("*.qml"):
        if component.name != "OmaFlow.qml": (p/component.name).write_text(component.read_text())
    for mode in ["history","empty","detail","settings","settings-bottom","settings-models","settings-model-status","settings-models-bottom","settings-models-pending","settings-models-pending-bottom","hotkey","recording","recording-held","processing","result","warning","success","notice","error"]:
        result = subprocess.run(["quickshell","-p",str(p)], env=dict(os.environ, QT_QPA_PLATFORM="offscreen", AUDIT_MODE=mode, OMAFLOW_UI_OUTPUT=str(output)), capture_output=True, text=True, timeout=10)
        log = result.stdout+result.stderr
        (output/(mode+".log")).write_text(log)
        if result.returncode or " ERROR:" in log or "Unable to assign" in log or "ReferenceError" in log or "Error:" in log or not (output/(mode+".png")).is_file():
            raise SystemExit(log)
        print("PASS render", mode, flush=True)
print(output)
