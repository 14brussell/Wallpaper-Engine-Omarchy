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

  // Written as ignored installation state by scripts/install.sh. Keeping the
  // generation outside tracked QML lets Omarchy retain a clean, updateable git
  // checkout while the installer can still verify the exact loaded build.
  property string buildGeneration: ""

  FileView {
    id: generationFile
    path: root.manifest && root.manifest.__sourceDir
      ? String(root.manifest.__sourceDir) + "/.we-build-generation"
      : ""
    printErrors: false
    onLoaded: root.buildGeneration = text().trim()
    onLoadFailed: function(error) { root.buildGeneration = "" }
  }

  IpcHandler {
    target: "wallpaper-engine-generation"
    function ping(): string { return root.buildGeneration }
  }
}
