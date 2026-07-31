# frozen_string_literal: true

cask "switchtab" do
  version "1.1.4"
  sha256 "609b1f3feb9d498bc0a7cb85afc8d36dd4956ccf87b74ea8ce77f4ae730c934c"

  url "https://github.com/sonim1/switchtab/releases/download/v#{version}/SwitchTab-#{version}-15.dmg"
  name "SwitchTab"
  desc "Fast macOS application switcher"
  homepage "https://github.com/sonim1/switchtab"

  depends_on arch: :arm64
  depends_on macos: :ventura

  app "SwitchTab.app"
end
