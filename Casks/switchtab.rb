# frozen_string_literal: true

cask "switchtab" do
  version "1.1.0"
  sha256 "17e3d60c6326bd89af1352e4567c7a9a15ed688f64fb2234f6233fc83863c455"

  url "https://github.com/sonim1/switchtab/releases/download/v#{version}/SwitchTab-#{version}-11.dmg"
  name "SwitchTab"
  desc "Fast macOS application switcher"
  homepage "https://github.com/sonim1/switchtab"

  depends_on arch: :arm64
  depends_on macos: :ventura

  app "SwitchTab.app"
end
