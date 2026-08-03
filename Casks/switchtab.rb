# frozen_string_literal: true

cask "switchtab" do
  version "1.1.7"
  sha256 "a1bae0db0dc13bd647f556e699ce3d0c034049330d84f771072f1bf323f2a1ea"

  url "https://github.com/sonim1/switchtab/releases/download/v#{version}/SwitchTab-#{version}-18.dmg"
  name "SwitchTab"
  desc "Fast macOS application switcher"
  homepage "https://github.com/sonim1/switchtab"

  depends_on arch: :arm64
  depends_on macos: :ventura

  app "SwitchTab.app"
end
