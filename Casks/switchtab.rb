# frozen_string_literal: true

cask "switchtab" do
  version "1.1.9"
  sha256 "f817ac906e683a1607ba6b124bdbfd63f3d0d36a74a619bf1cdb993a4a567b0e"

  url "https://github.com/sonim1/switchtab/releases/download/v#{version}/SwitchTab-#{version}-20.dmg"
  name "SwitchTab"
  desc "Fast macOS application switcher"
  homepage "https://github.com/sonim1/switchtab"

  depends_on arch: :arm64
  depends_on macos: :ventura

  app "SwitchTab.app"
end
