# frozen_string_literal: true

cask "switchtab" do
  version "1.1.11"
  sha256 "6e438642b0f82268222fa483d209a3cb2588bde3df5a1e17e1f489e868494049"

  url "https://github.com/sonim1/switchtab/releases/download/v#{version}/SwitchTab-#{version}-22.dmg"
  name "SwitchTab"
  desc "Fast macOS application switcher"
  homepage "https://github.com/sonim1/switchtab"

  depends_on arch: :arm64
  depends_on macos: :ventura

  app "SwitchTab.app"
end
