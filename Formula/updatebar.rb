# typed: strict
# frozen_string_literal: true

# Formula for UpdateBar.
class Updatebar < Formula
  desc "CLI-first update tracker for local tools"
  homepage "https://github.com/sonim1/UpdateBar"
  url "https://github.com/sonim1/UpdateBar/releases/download/v0.6.23/updatebar-0.6.23-macos-arm64.tar.gz"
  version "0.6.23"
  sha256 "292bca72a1cd91a752692894c0c5c466c3f29738830cecc393e48a5c0fc8ce1d"

  depends_on arch: :arm64
  depends_on macos: :ventura

  def install
    bin.install "updatebar"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/updatebar --version").strip
  end
end
