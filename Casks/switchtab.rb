# frozen_string_literal: true

cask "switchtab" do
  version "1.0.5"
  sha256 "a539b85787e999d9b47f8b467d5604a05620327785b09c4fce84f8202c6765a3"

  url "https://github.com/sonim1/switchtab/releases/download/v#{version}/SwitchTab-#{version}-6.dmg"
  name "SwitchTab"
  desc "Fast macOS application switcher"
  homepage "https://github.com/sonim1/switchtab"

  depends_on arch: :arm64
  depends_on macos: :ventura

  app "SwitchTab.app"
end
