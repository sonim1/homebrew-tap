# frozen_string_literal: true

cask "switchtab" do
  version "1.1.13"
  sha256 "50f64a638244a6eea44f94990a8834a8fa7f3e633f28aa68f82cee51c0e0bef3"

  url "https://github.com/sonim1/switchtab/releases/download/v#{version}/SwitchTab-#{version}-24.dmg"
  name "SwitchTab"
  desc "Fast macOS application switcher"
  homepage "https://github.com/sonim1/switchtab"

  depends_on arch: :arm64
  depends_on macos: :ventura

  app "SwitchTab.app"
end
