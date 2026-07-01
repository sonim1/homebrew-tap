# typed: strict
# frozen_string_literal: true

# Formula for UpdateBar.
class Updatebar < Formula
  desc "CLI-first update tracker for local tools"
  homepage "https://github.com/sonim1/UpdateBar"
  version "0.2.0"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/sonim1/UpdateBar/releases/download/v0.2.0/updatebar-0.2.0-macos-arm64.tar.gz"
      sha256 "2e5446ce1e4aa7eddc66041fa031820950beb90efc71a0c97b3836d62b006bd1"
    end
  end

  def install
    bin.install "updatebar"
  end

  test do
    assert_match "\"version\":\"#{version}\"", shell_output("#{bin}/updatebar version --json")
  end
end
