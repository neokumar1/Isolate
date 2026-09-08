cask "isolate" do
  version "1.2.5"
  sha256 "e6a68d336be4acedd6f9c72237e7d102265fef30cc07459c1c4834258ab6c48c"

  url "https://github.com/neokumar1/Isolate/releases/download/v#{version}/Isolate.dmg"
  name "Isolate"
  desc "Raw 4-stem audio isolation powered by Demucs v4 Neural Engine CoreML"
  homepage "https://github.com/neokumar1/Isolate"

  depends_on macos: ">= :sonoma"
  depends_on arch: :arm64

  app "Isolate.app"

  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/Isolate.app"],
                   sudo: false
  end

  zap trash: [
    "~/Library/Application Support/Isolate",
    "~/Library/Preferences/com.isolate.Isolate.plist",
    "~/Library/Caches/com.isolate.Isolate",
  ]
end
