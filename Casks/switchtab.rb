# frozen_string_literal: true

cask "switchtab" do
  version "1.1.1"
  sha256 "fa93ac29eac084be54fb0bbdf827ce23ac8866dfc8aee257171fc53d2969bc37"

  url "https://github.com/sonim1/switchtab/releases/download/v#{version}/SwitchTab-#{version}-12.dmg"
  name "SwitchTab"
  desc "Fast macOS application switcher"
  homepage "https://github.com/sonim1/switchtab"

  depends_on arch: :arm64
  depends_on macos: :ventura

  app "SwitchTab.app"
end
