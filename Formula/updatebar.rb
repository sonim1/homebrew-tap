# typed: strict
# frozen_string_literal: true

# Formula for UpdateBar.
class Updatebar < Formula
  desc "CLI-first update tracker for local tools"
  homepage "https://github.com/sonim1/UpdateBar"
  url "https://github.com/sonim1/UpdateBar/releases/download/v0.6.26/updatebar-0.6.26-macos-arm64.tar.gz"
  version "0.6.26"
  sha256 "de348631918fb0493e139a5a0b2657fe76360a4ecad765e42da3b9876f5629cd"

  depends_on arch: :arm64
  depends_on macos: :ventura

  def install
    bin.install "updatebar"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/updatebar --version").strip
  end
end
