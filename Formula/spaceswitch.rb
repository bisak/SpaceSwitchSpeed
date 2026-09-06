class Spaceswitch < Formula
  desc "Speed control for the macOS Space-switch animation"
  homepage "https://github.com/bisak/spaceswitch"
  url "https://github.com/bisak/spaceswitch/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  license "AGPL-3.0-or-later"
  head "https://github.com/bisak/spaceswitch.git", branch: "main"

  depends_on arch: :arm64
  depends_on macos: :ventura
  depends_on xcode: ["14.0", :build]

  def install
    system "swift", "build", "--disable-sandbox", "-c", "release", "--product", "spaceswitch"
    system "swift", "build", "--disable-sandbox", "-c", "release", "--product", "spaceswitchd"
    bin.install ".build/release/spaceswitch"
    libexec.install ".build/release/spaceswitchd"
    doc.install "README.md", "docs/REVERSE-ENGINEERING.md"
  end

  def caveats
    <<~EOS
      SpaceSwitch writes to the running Dock process, which macOS only permits with
      System Integrity Protection disabled AND root privileges. Both are required:

        csrutil status         # must report "disabled" (change it from Recovery)
        sudo spaceswitch 0.5   # set the speed
        spaceswitch status     # see what is applied

      To keep the setting across Dock restarts and reboots:

        sudo spaceswitch install

      Read the SIP section of the documentation before disabling it:
        #{doc}/README.md
    EOS
  end

  test do
    assert_match "preset", shell_output("#{bin}/spaceswitch presets")
    assert_match "Balanced", shell_output("#{bin}/spaceswitch presets")
  end
end
