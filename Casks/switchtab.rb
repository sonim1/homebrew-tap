# frozen_string_literal: true

cask "switchtab" do
  version "1.1.32"
  sha256 "d4f7338cf8231376db7201b691c0b757dc77c106d8795def759bc0e1486f759f"

  url "https://github.com/sonim1/switchtab/releases/download/v#{version}/SwitchTab-#{version}-43.dmg"
  name "SwitchTab"
  desc "Fast macOS application switcher"
  homepage "https://github.com/sonim1/switchtab"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "SwitchTab.app"
end
