# typed: strict
# frozen_string_literal: true

# Formula for UpdateBar.
class Updatebar < Formula
  desc "CLI-first update tracker for local tools"
  homepage "https://github.com/sonim1/UpdateBar"
  url "https://github.com/sonim1/UpdateBar/releases/download/v0.6.8/updatebar-0.6.8-macos-arm64.tar.gz"
  version "0.6.8"
  sha256 "cee9ea9934fbd932f2b8017f12877ca984eaca68c88f04377553bb8becb7361f"

  depends_on arch: :arm64
  depends_on macos: :ventura

  def install
    bin.install "updatebar"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/updatebar --version").strip
  end
end
