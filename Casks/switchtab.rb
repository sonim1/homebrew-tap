# frozen_string_literal: true

cask "switchtab" do
  version "1.1.23"
  sha256 "3c801cf4c6b36083a747c2bc1f97aae14740b4587106868068ffebf0bfa6524c"

  url "https://github.com/sonim1/switchtab/releases/download/v#{version}/SwitchTab-#{version}-34.dmg"
  name "SwitchTab"
  desc "Fast macOS application switcher"
  homepage "https://github.com/sonim1/switchtab"

  depends_on arch: :arm64
  depends_on macos: :ventura

  app "SwitchTab.app"
end
