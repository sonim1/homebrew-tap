# frozen_string_literal: true

cask "switchtab" do
  version "1.1.15"
  sha256 "2a52e4ae210b4e38a21a01a3829ebe69495459a8dd3531ddaa277ea7dc5273fc"

  url "https://github.com/sonim1/switchtab/releases/download/v#{version}/SwitchTab-#{version}-26.dmg"
  name "SwitchTab"
  desc "Fast macOS application switcher"
  homepage "https://github.com/sonim1/switchtab"

  depends_on arch: :arm64
  depends_on macos: :ventura

  app "SwitchTab.app"
end
