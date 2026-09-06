import QtQuick
import qs.Ui as Ui

Ui.Button {
  focusable: true
  Accessible.role: Accessible.Button
  Accessible.name: text
  Accessible.onPressAction: clicked()
}
