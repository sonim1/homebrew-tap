# frozen_string_literal: true

cask "switchtab" do
  version "1.1.8"
  sha256 "bef3f375ebb51aff61b66c72d40a0a629c46464217e58af51ce50c6912f8f466"

  url "https://github.com/sonim1/switchtab/releases/download/v#{version}/SwitchTab-#{version}-19.dmg"
  name "SwitchTab"
  desc "Fast macOS application switcher"
  homepage "https://github.com/sonim1/switchtab"

  depends_on arch: :arm64
  depends_on macos: :ventura

  app "SwitchTab.app"
end
