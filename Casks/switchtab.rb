# frozen_string_literal: true

cask "switchtab" do
  version "1.1.18"
  sha256 "356796b1274ddc6b7d47737f96e78b461ca2b2313f45010771b24a99790d603a"

  url "https://github.com/sonim1/switchtab/releases/download/v#{version}/SwitchTab-#{version}-29.dmg"
  name "SwitchTab"
  desc "Fast macOS application switcher"
  homepage "https://github.com/sonim1/switchtab"

  depends_on arch: :arm64
  depends_on macos: :ventura

  app "SwitchTab.app"
end
