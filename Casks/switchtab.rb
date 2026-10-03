# frozen_string_literal: true

cask "switchtab" do
  version "1.1.26"
  sha256 "461a44223cf8264545a4d0916edd88ad4f56e7fd88281995b068fe18dcb6e998"

  url "https://github.com/sonim1/switchtab/releases/download/v#{version}/SwitchTab-#{version}-37.dmg"
  name "SwitchTab"
  desc "Fast macOS application switcher"
  homepage "https://github.com/sonim1/switchtab"

  depends_on arch: :arm64
  depends_on macos: :ventura

  app "SwitchTab.app"
end
