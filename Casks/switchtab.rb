# frozen_string_literal: true

cask "switchtab" do
  version "1.0.9"
  sha256 "c4c43df75f65d43c5491a84b93511bd1ea7cff9e4190bc72f8e70b6cc6bfb3bf"

  url "https://github.com/sonim1/switchtab/releases/download/v#{version}/SwitchTab-#{version}-10.dmg"
  name "SwitchTab"
  desc "Fast macOS application switcher"
  homepage "https://github.com/sonim1/switchtab"

  depends_on arch: :arm64
  depends_on macos: :ventura

  app "SwitchTab.app"
end
