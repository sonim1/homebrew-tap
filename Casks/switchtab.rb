# frozen_string_literal: true

cask "switchtab" do
  version "1.1.30"
  sha256 "9cf1e8e905cfd8c157be2878ec95f77c32728a85f59d531f09d418b5a7b79095"

  url "https://github.com/sonim1/switchtab/releases/download/v#{version}/SwitchTab-#{version}-41.dmg"
  name "SwitchTab"
  desc "Fast macOS application switcher"
  homepage "https://github.com/sonim1/switchtab"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "SwitchTab.app"
end
