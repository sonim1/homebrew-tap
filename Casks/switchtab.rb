# frozen_string_literal: true

cask "switchtab" do
  version "1.1.29"
  sha256 "b6feeb97ee0a52ade1b48e12f6f4e2276d04973385018518b5a5b641fdf6e76d"

  url "https://github.com/sonim1/switchtab/releases/download/v#{version}/SwitchTab-#{version}-40.dmg"
  name "SwitchTab"
  desc "Fast macOS application switcher"
  homepage "https://github.com/sonim1/switchtab"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "SwitchTab.app"
end
