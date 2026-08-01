# frozen_string_literal: true

cask "switchtab" do
  version "1.1.5"
  sha256 "928332ef3a8ab607915df177799d6262241d9df7c70502a26d8e98932c979fec"

  url "https://github.com/sonim1/switchtab/releases/download/v#{version}/SwitchTab-#{version}-16.dmg"
  name "SwitchTab"
  desc "Fast macOS application switcher"
  homepage "https://github.com/sonim1/switchtab"

  depends_on arch: :arm64
  depends_on macos: :ventura

  app "SwitchTab.app"
end
