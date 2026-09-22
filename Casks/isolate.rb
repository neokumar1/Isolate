cask "isolate" do
  version "1.2.5"
  sha256 "e6a68d336be4acedd6f9c72237e7d102265fef30cc07459c1c4834258ab6c48c"

  url "https://github.com/neokumar1/Isolate/releases/download/v#{version}/Isolate.dmg"
  name "Isolate"
  desc "Four-stem audio separation and mixing with Core ML"
  homepage "https://github.com/neokumar1/Isolate"

  depends_on macos: ">= :sonoma"
  depends_on arch: :arm64

  app "Isolate.app"

  zap trash: [
    "~/Library/Application Support/Isolate",
    "~/Library/Preferences/com.isolate.Isolate.plist",
    "~/Library/Caches/com.isolate.Isolate",
  ]
end
