# frozen_string_literal: true

cask "switchtab" do
  version "1.1.19"
  sha256 "1dd44c3be8f09d452668a4e91ab3baa9ea5f6f70e7d97be068aa09984cec6476"

  url "https://github.com/sonim1/switchtab/releases/download/v#{version}/SwitchTab-#{version}-30.dmg"
  name "SwitchTab"
  desc "Fast macOS application switcher"
  homepage "https://github.com/sonim1/switchtab"

  depends_on arch: :arm64
  depends_on macos: :ventura

  app "SwitchTab.app"
end
