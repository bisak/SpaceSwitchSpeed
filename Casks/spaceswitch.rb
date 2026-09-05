cask "spaceswitch" do
  version "0.1.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/bisak/spaceswitch/releases/download/v#{version}/SpaceSwitch-#{version}.zip"
  name "SpaceSwitch"
  desc "Speed control for the macOS Space-switch animation"
  homepage "https://github.com/bisak/spaceswitch"

  depends_on arch: :arm64
  depends_on macos: ">= :ventura"

  app "SpaceSwitch.app"

  uninstall launchctl: "com.bisak.spaceswitch.helper",
            delete:    [
              "/Library/LaunchDaemons/com.bisak.spaceswitch.helper.plist",
              "/Library/Application Support/SpaceSwitch",
            ]

  caveats <<~EOS
    SpaceSwitch needs System Integrity Protection disabled and administrator
    privileges to change Dock. The app detects this and explains what it means
    before anything happens.
  EOS
end
