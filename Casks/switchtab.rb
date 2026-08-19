# frozen_string_literal: true

cask "switchtab" do
  version "1.1.17"
  sha256 "6a6fb65cc1816fcb4307d0ac095136e1d6ed3bfbf4de60acefdd17d391e90445"

  url "https://github.com/sonim1/switchtab/releases/download/v#{version}/SwitchTab-#{version}-28.dmg"
  name "SwitchTab"
  desc "Fast macOS application switcher"
  homepage "https://github.com/sonim1/switchtab"

  depends_on arch: :arm64
  depends_on macos: :ventura

  app "SwitchTab.app"
end
