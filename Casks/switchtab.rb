# frozen_string_literal: true

cask "switchtab" do
  version "1.1.16"
  sha256 "eaacf53966c475e82686cd997dd26e0e20ccfc7b0269e3517e0d6b35a2f94b8a"

  url "https://github.com/sonim1/switchtab/releases/download/v#{version}/SwitchTab-#{version}-27.dmg"
  name "SwitchTab"
  desc "Fast macOS application switcher"
  homepage "https://github.com/sonim1/switchtab"

  depends_on arch: :arm64
  depends_on macos: :ventura

  app "SwitchTab.app"
end
