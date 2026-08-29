import Quickshell.Io
import QtQuick

// Deliberately tiny. Applying a wallpaper is a backend operation and must not
// create a full-screen QML surface on every output. This service exists only
// so the atomic installer can prove that the newly copied plugin generation
// loaded successfully.
Item {
  id: root

  property var shell: null
  property var manifest: null

  // Replaced in the hidden staging directory by scripts/install.sh.
  readonly property string buildGeneration: "__WE_BUILD_GENERATION__"

  IpcHandler {
    target: "wallpaper-engine-generation-" + root.buildGeneration
    function ping(): string { return root.buildGeneration }
  }
}
