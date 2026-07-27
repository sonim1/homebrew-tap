# frozen_string_literal: true

cask "switchtab" do
  version "1.0.4"
  sha256 "954c82077c18f4040ff919a881775b6bcfb278c2eb484363cae2d0808381b42b"

  url "https://github.com/sonim1/switchtab/releases/download/v#{version}/SwitchTab-#{version}-5.dmg"
  name "SwitchTab"
  desc "Fast macOS application switcher"
  homepage "https://github.com/sonim1/switchtab"

  depends_on arch: :arm64
  depends_on macos: :ventura

  app "SwitchTab.app"
end
