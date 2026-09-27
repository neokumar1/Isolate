cask "isolate" do
  version "1.2.5"
  sha256 "e6a68d336be4acedd6f9c72237e7d102265fef30cc07459c1c4834258ab6c48c"

  url "https://github.com/neokumar1/Isolate/releases/download/v#{version}/Isolate.dmg"
  name "Isolate"
  desc "Stem player that splits songs into vocals, drums, bass and other"
  homepage "https://github.com/neokumar1/Isolate"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on arch: :arm64
  depends_on macos: ">= :sonoma"

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
    Isolate is ad-hoc signed and not notarized by Apple, so macOS asks you to
    approve its first launch:
      macOS 15 or later: open Isolate and click Done. In System Settings >
      Privacy & Security, click Open Anyway next to the Isolate message,
      authenticate, then click Open.
      macOS 14: Control-click Isolate in Applications, choose Open, then Open.
    Details: https://github.com/neokumar1/Isolate#first-launch
  EOS
end
