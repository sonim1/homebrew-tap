# frozen_string_literal: true

cask "switchtab" do
  version "1.1.31"
  sha256 "cb2c477bfaa167b4399dc9a0a4fb9f6d91022e99dae07735c67e3ac07e245381"

  url "https://github.com/sonim1/switchtab/releases/download/v#{version}/SwitchTab-#{version}-42.dmg"
  name "SwitchTab"
  desc "Fast macOS application switcher"
  homepage "https://github.com/sonim1/switchtab"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "SwitchTab.app"
end
