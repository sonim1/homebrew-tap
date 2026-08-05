# frozen_string_literal: true

cask "switchtab" do
  version "1.1.10"
  sha256 "d3f5dfceb242afe2fa914bc857762356c35e5c5c8ab08706acea73cd0368e3d9"

  url "https://github.com/sonim1/switchtab/releases/download/v#{version}/SwitchTab-#{version}-21.dmg"
  name "SwitchTab"
  desc "Fast macOS application switcher"
  homepage "https://github.com/sonim1/switchtab"

  depends_on arch: :arm64
  depends_on macos: :ventura

  app "SwitchTab.app"
end
