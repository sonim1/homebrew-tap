# frozen_string_literal: true

cask "switchtab" do
  version "1.1.22"
  sha256 "a84cd970741b620cc93ca1f24dc19b39cedfc78ae5fea7e467eec4760fc28db4"

  url "https://github.com/sonim1/switchtab/releases/download/v#{version}/SwitchTab-#{version}-33.dmg"
  name "SwitchTab"
  desc "Fast macOS application switcher"
  homepage "https://github.com/sonim1/switchtab"

  depends_on arch: :arm64
  depends_on macos: :ventura

  app "SwitchTab.app"
end
