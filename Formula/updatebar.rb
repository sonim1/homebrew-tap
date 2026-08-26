# typed: strict
# frozen_string_literal: true

# Formula for UpdateBar.
class Updatebar < Formula
  desc "CLI-first update tracker for local tools"
  homepage "https://github.com/sonim1/UpdateBar"
  url "https://github.com/sonim1/UpdateBar/releases/download/v0.6.20/updatebar-0.6.20-macos-arm64.tar.gz"
  version "0.6.20"
  sha256 "aa642e2b1f879fc453ceea09ed667db575f9d03d98779d8ff3f4709af71ee9e1"

  depends_on arch: :arm64
  depends_on macos: :ventura

  def install
    bin.install "updatebar"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/updatebar --version").strip
  end
end
