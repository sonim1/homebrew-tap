# frozen_string_literal: true

cask "switchtab" do
  version "1.1.14"
  sha256 "1800438c996dda423b764e42ddcc289b45fe9ec8acb960221d82b688699cc175"

  url "https://github.com/sonim1/switchtab/releases/download/v#{version}/SwitchTab-#{version}-25.dmg"
  name "SwitchTab"
  desc "Fast macOS application switcher"
  homepage "https://github.com/sonim1/switchtab"

  depends_on arch: :arm64
  depends_on macos: :ventura

  app "SwitchTab.app"
end
