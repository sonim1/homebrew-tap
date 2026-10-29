# frozen_string_literal: true

cask "updatebar-app" do
  version "0.6.35"
  sha256 "74864302d72e68a9841a6a59a7ef8c0765bb40c988303561a06db3da6f1993ea"

  url "https://github.com/sonim1/UpdateBar/releases/download/v#{version}/UpdateBar-#{version}-macos-arm64.dmg"
  name "UpdateBar"
  desc "Menu bar update tracker for local tools"
  homepage "https://github.com/sonim1/UpdateBar"

  depends_on arch: :arm64
  depends_on macos: :ventura

  app "UpdateBar.app"
  binary "#{appdir}/UpdateBar.app/Contents/Resources/updatebar"

  zap trash: [
    "~/.updatebar",
    "~/Library/Logs/UpdateBar",
    "~/Library/Preferences/com.sonim1.UpdateBar.plist",
  ]

  caveats <<~EOS
    The updatebar CLI is included with this app. For a CLI-only installation, use:
      brew install --formula sonim1/tap/updatebar

    For the Open TUI menu item, install the terminal UI:
      brew install sonim1/tap/updatebar-tui
  EOS
end
