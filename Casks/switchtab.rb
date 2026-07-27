# frozen_string_literal: true

cask "switchtab" do
  version "1.0.6"
  sha256 "6d3ef94d8e014fc3ab611d1b1a40ea62d052346836c260fd2ce0586116b9eac0"

  url "https://github.com/sonim1/switchtab/releases/download/v#{version}/SwitchTab-#{version}-7.dmg"
  name "SwitchTab"
  desc "Fast macOS application switcher"
  homepage "https://github.com/sonim1/switchtab"

  depends_on arch: :arm64
  depends_on macos: :ventura

  app "SwitchTab.app"
end
