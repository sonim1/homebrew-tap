# frozen_string_literal: true

cask "switchtab" do
  version "1.1.12"
  sha256 "9729d8c4dec498b1df74b8d9821d89034ae7ffbac52c1e7261ffd642b67f1712"

  url "https://github.com/sonim1/switchtab/releases/download/v#{version}/SwitchTab-#{version}-23.dmg"
  name "SwitchTab"
  desc "Fast macOS application switcher"
  homepage "https://github.com/sonim1/switchtab"

  depends_on arch: :arm64
  depends_on macos: :ventura

  app "SwitchTab.app"
end
