# typed: strict
# frozen_string_literal: true

# Formula for UpdateBar.
class Updatebar < Formula
  desc "CLI-first update tracker for local tools"
  homepage "https://github.com/sonim1/UpdateBar"
  url "https://github.com/sonim1/UpdateBar/releases/download/v0.6.28/updatebar-0.6.28-macos-arm64.tar.gz"
  sha256 "0812c08bbb922b716c5ecdcbe94e0f98b12d09cacfb66bbbfb9c617552e91b7e"

  depends_on arch: :arm64
  depends_on macos: :ventura

  def install
    bin.install "updatebar"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/updatebar --version").strip
  end
end
