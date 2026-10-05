# frozen_string_literal: true

cask "switchtab" do
  version "1.1.28"
  sha256 "36d02fb7319310032245448c515dd17ab58e19128d309d6a1d0cc35d62d8af5a"

  url "https://github.com/sonim1/switchtab/releases/download/v#{version}/SwitchTab-#{version}-39.dmg"
  name "SwitchTab"
  desc "Fast macOS application switcher"
  homepage "https://github.com/sonim1/switchtab"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "SwitchTab.app"
end
