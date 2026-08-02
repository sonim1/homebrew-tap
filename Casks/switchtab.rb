# frozen_string_literal: true

cask "switchtab" do
  version "1.1.6"
  sha256 "300c3eb36b2cb8935d61fc4876f2499adaa281d83ac8f1797ed8ed3a44c6c493"

  url "https://github.com/sonim1/switchtab/releases/download/v#{version}/SwitchTab-#{version}-17.dmg"
  name "SwitchTab"
  desc "Fast macOS application switcher"
  homepage "https://github.com/sonim1/switchtab"

  depends_on arch: :arm64
  depends_on macos: :ventura

  app "SwitchTab.app"
end
