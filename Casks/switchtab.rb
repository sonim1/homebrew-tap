# frozen_string_literal: true

cask "switchtab" do
  version "1.0.7"
  sha256 "d6d7fcd6865a5a90df8b44bab6e043ce68ee12db8c562823ca63d4e71bff790f"

  url "https://github.com/sonim1/switchtab/releases/download/v#{version}/SwitchTab-#{version}-8.dmg"
  name "SwitchTab"
  desc "Fast macOS application switcher"
  homepage "https://github.com/sonim1/switchtab"

  depends_on arch: :arm64
  depends_on macos: :ventura

  app "SwitchTab.app"
end
