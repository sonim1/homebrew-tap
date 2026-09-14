# frozen_string_literal: true

cask "switchtab" do
  version "1.1.25"
  sha256 "10a734aa60bec9076264dd145fb936255ea112d4cedba0f9e1e96f09f5eabe50"

  url "https://github.com/sonim1/switchtab/releases/download/v#{version}/SwitchTab-#{version}-36.dmg"
  name "SwitchTab"
  desc "Fast macOS application switcher"
  homepage "https://github.com/sonim1/switchtab"

  depends_on arch: :arm64
  depends_on macos: :ventura

  app "SwitchTab.app"
end
