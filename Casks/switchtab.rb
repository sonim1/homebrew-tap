# frozen_string_literal: true

cask "switchtab" do
  version "1.1.21"
  sha256 "4793c17a557882a8596451df72df8071c26c5e84a189b72ace129fd7ba422786"

  url "https://github.com/sonim1/switchtab/releases/download/v#{version}/SwitchTab-#{version}-32.dmg"
  name "SwitchTab"
  desc "Fast macOS application switcher"
  homepage "https://github.com/sonim1/switchtab"

  depends_on arch: :arm64
  depends_on macos: :ventura

  app "SwitchTab.app"
end
