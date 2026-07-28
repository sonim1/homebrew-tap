# frozen_string_literal: true

cask "switchtab" do
  version "1.0.8"
  sha256 "837c60229c825bf3b3beb7d29e5335e33c7f65651b02dcc659419b6d3f78368b"

  url "https://github.com/sonim1/switchtab/releases/download/v#{version}/SwitchTab-#{version}-9.dmg"
  name "SwitchTab"
  desc "Fast macOS application switcher"
  homepage "https://github.com/sonim1/switchtab"

  depends_on arch: :arm64
  depends_on macos: :ventura

  app "SwitchTab.app"
end
