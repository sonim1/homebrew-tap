# frozen_string_literal: true

cask "switchtab" do
  version "1.1.3"
  sha256 "91e4d87496291e4521defd011adeac9ead8cf37a9e296ac7cc4b9d52203e8c53"

  url "https://github.com/sonim1/switchtab/releases/download/v#{version}/SwitchTab-#{version}-14.dmg"
  name "SwitchTab"
  desc "Fast macOS application switcher"
  homepage "https://github.com/sonim1/switchtab"

  depends_on arch: :arm64
  depends_on macos: :ventura

  app "SwitchTab.app"
end
