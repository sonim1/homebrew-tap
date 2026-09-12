# frozen_string_literal: true

cask "switchtab" do
  version "1.1.24"
  sha256 "4dc7d7cad5f5197fb0e7ec20e50e7682c6e4117c37d4330a8ea7eed999686225"

  url "https://github.com/sonim1/switchtab/releases/download/v#{version}/SwitchTab-#{version}-35.dmg"
  name "SwitchTab"
  desc "Fast macOS application switcher"
  homepage "https://github.com/sonim1/switchtab"

  depends_on arch: :arm64
  depends_on macos: :ventura

  app "SwitchTab.app"
end
