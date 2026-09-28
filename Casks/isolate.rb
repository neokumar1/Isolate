cask "isolate" do
  version "1.3.2"
  sha256 "12950691697ad0b638142b2a0e85008f1d0b70b90723f659eb0cd18c4d5e2831"

  url "https://github.com/neokumar1/Isolate/releases/download/v#{version}/Isolate.dmg"
  name "Isolate"
  desc "Stem player that splits songs into vocals, drums, bass and other"
  homepage "https://github.com/neokumar1/Isolate"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "Isolate.app"

  # The library lives in Application Support/Isolate. Never add the shared
  # ~/Library/Application Support/default.store, which other apps also use.
  zap trash: [
    "~/Library/Application Scripts/com.isolate.Isolate",
    "~/Library/Application Support/Isolate",
    "~/Library/Caches/com.isolate.Isolate",
    "~/Library/Preferences/com.isolate.Isolate.plist",
    "~/Library/Saved Application State/com.isolate.Isolate.savedState",
  ]

  caveats <<~EOS
    The separation model is included. macOS 26 or later is recommended for
    separation; on macOS 14 or 15, Isolate may refuse an incompatible Core ML
    compute path and ask you to update.

    Isolate is ad-hoc signed and not notarized by Apple, so macOS asks you to
    approve its first launch:
      macOS 15 or later: open Isolate and click Done. In System Settings >
      Privacy & Security, click Open Anyway next to the Isolate message,
      authenticate, then click Open.
      macOS 14: Control-click Isolate in Applications, choose Open, then Open.
    Details: https://github.com/neokumar1/Isolate#first-launch
  EOS
end
