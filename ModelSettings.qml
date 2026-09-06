import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui

ColumnLayout {
  id: page
  required property var flow
  property string engine: flow.modelSettings.speech_engine || "nemo"
  spacing: Style.space(8)

  Text { visible:page.flow.modelSettings.configured === false; Layout.fillWidth:true; text:"Models not configured. Save your model choices, install the runtime and weights or start your server, then enable dictation below."; wrapMode:Text.Wrap; color:Color.popups.text; font.family:Style.font.family }
  Text { Layout.fillWidth:true; text:"Save the model names and server addresses below. Changes apply to the next dictation. Install your models separately before using them."; wrapMode:Text.Wrap; color:Util.alpha(Color.popups.text,0.65); font.family:Style.font.family; font.pixelSize:Style.font.caption }
  Text { text:"Cleanup (Ollama)"; color:Color.popups.text; font.family:Style.font.family; font.bold:true }
  TextField { id:cleanupModel; Layout.fillWidth:true; text:page.flow.modelSettings.cleanup_model || ""; placeholderText:"Ollama model tag"; maximumLength:512; foreground:Color.popups.text; Accessible.name:"Cleanup model" }
  TextField { id:cleanupEndpoint; Layout.fillWidth:true; text:page.flow.modelSettings.cleanup_endpoint || ""; placeholderText:"Ollama /api/chat endpoint"; maximumLength:2048; foreground:Color.popups.text; Accessible.name:"Cleanup server endpoint" }
  Text { text:"Speech recognition"; color:Color.popups.text; font.family:Style.font.family; font.bold:true }
  RowLayout {
    Repeater {
      model:[{key:"nemo",label:"NeMo"},{key:"openai",label:"Compatible API"},{key:"whisper-cpp",label:"whisper.cpp"}]
      ActionButton {
        required property var modelData
        text:modelData.label
        selected:page.engine === modelData.key || (modelData.key === "nemo" && page.engine === "parakeet")
        onClicked:page.engine=modelData.key
      }
    }
  }
  Text { Layout.fillWidth:true; text:page.engine === "nemo" || page.engine === "parakeet" ? "OmaFlow starts NeMo with an existing GGUF file. Enter its absolute path or a repository already in the standard NeMo cache. Models are never downloaded here." : page.engine === "whisper-cpp" ? "Start whisper-server yourself and use its /inference endpoint. Select the model in that server; the name below is for reference." : "Start an OpenAI-compatible speech server yourself and enter its /v1/audio/transcriptions endpoint. This does not connect to OpenAI automatically."; wrapMode:Text.Wrap; color:Util.alpha(Color.popups.text,0.65); font.family:Style.font.family; font.pixelSize:Style.font.caption }
  TextField { id:speechModel; Layout.fillWidth:true; text:page.flow.modelSettings.speech_model || ""; placeholderText:"Speech model name or absolute NeMo GGUF path"; maximumLength:512; foreground:Color.popups.text; Accessible.name:"Speech model" }
  TextField { id:speechEndpoint; Layout.fillWidth:true; text:page.flow.modelSettings.speech_endpoint || ""; placeholderText:"Speech endpoint"; maximumLength:2048; foreground:Color.popups.text; Accessible.name:"Speech server endpoint" }
  TextField { id:speechHealth; Layout.fillWidth:true; text:page.flow.modelSettings.speech_health_endpoint || ""; placeholderText:"Health endpoint (optional)"; maximumLength:2048; foreground:Color.popups.text; Accessible.name:"Speech health endpoint" }
  Text { text:"Language"; color:Color.popups.text; font.family:Style.font.family; font.pixelSize:Style.font.caption }
  TextField { id:speechLanguage; Layout.fillWidth:true; text:page.flow.modelSettings.speech_language || "auto"; placeholderText:"Language: auto or language code"; maximumLength:32; foreground:Color.popups.text; Accessible.name:"Speech language" }
  Text { visible:page.engine === "nemo" || page.engine === "parakeet"; text:"NeMo compute device"; color:Color.popups.text; font.family:Style.font.family; font.pixelSize:Style.font.caption }
  TextField { id:speechDevice; visible:page.engine === "nemo" || page.engine === "parakeet"; Layout.fillWidth:true; text:page.flow.modelSettings.speech_device || "cuda"; placeholderText:"NeMo device: cuda, cpu, auto, vulkan"; maximumLength:16; foreground:Color.popups.text; Accessible.name:"NeMo device" }
  Text { Layout.fillWidth:true; text:"Audio and cleanup context go to the addresses you choose. Use local servers to keep dictation on this computer. Authenticated cloud APIs are not supported."; wrapMode:Text.Wrap; color:Util.alpha(Color.popups.text,0.65); font.family:Style.font.family; font.pixelSize:Style.font.caption }
  ActionButton {
    text:"Save models"
    onClicked:page.flow.preference("models",{cleanup_model:cleanupModel.text,cleanup_endpoint:cleanupEndpoint.text,speech_engine:page.engine,speech_model:speechModel.text,speech_endpoint:speechEndpoint.text,speech_health_endpoint:speechHealth.text,speech_language:speechLanguage.text,speech_device:speechDevice.text})
  }
  ActionButton {
    visible:page.flow.modelSettings.configured === false
    text:"Enable dictation with saved models"
    onClicked:page.flow.preference("models_configured",true)
  }
}
