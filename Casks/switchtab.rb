# frozen_string_literal: true

cask "switchtab" do
  version "1.1.20"
  sha256 "34e67d9b58095c9a099b86e95dded85b655a6e1d1c74e0a40e4072d9f2c220c5"

  url "https://github.com/sonim1/switchtab/releases/download/v#{version}/SwitchTab-#{version}-31.dmg"
  name "SwitchTab"
  desc "Fast macOS application switcher"
  homepage "https://github.com/sonim1/switchtab"

  depends_on arch: :arm64
  depends_on macos: :ventura

  app "SwitchTab.app"
end
