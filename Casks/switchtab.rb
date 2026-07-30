# frozen_string_literal: true

cask "switchtab" do
  version "1.1.2"
  sha256 "5a537d4aa00f312d14fa015c14db5b8e943098d749cff66b3a95c9df1df95b3d"

  url "https://github.com/sonim1/switchtab/releases/download/v#{version}/SwitchTab-#{version}-13.dmg"
  name "SwitchTab"
  desc "Fast macOS application switcher"
  homepage "https://github.com/sonim1/switchtab"

  depends_on arch: :arm64
  depends_on macos: :ventura

  app "SwitchTab.app"
end
