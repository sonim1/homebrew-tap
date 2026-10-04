# frozen_string_literal: true

cask "switchtab" do
  version "1.1.27"
  sha256 "426b47d3a98086bc0f93041a5125a22978a2cbe5e4654df0e137423ecb3da089"

  url "https://github.com/sonim1/switchtab/releases/download/v#{version}/SwitchTab-#{version}-38.dmg"
  name "SwitchTab"
  desc "Fast macOS application switcher"
  homepage "https://github.com/sonim1/switchtab"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "SwitchTab.app"
end
