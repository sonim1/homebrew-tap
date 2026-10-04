# frozen_string_literal: true

cask "updatebar-app" do
  version "0.6.29"
  sha256 "9383bfd52d940c42f6f99387e03c41c5ad335bc4d602f41e237903624bb44d1d"

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
