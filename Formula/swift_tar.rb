# Homebrew formula for swift_tar, the public build (no LZFSE).
#
# This repository is its own tap:
#
#   brew tap raliclo/swift_tar https://github.com/raliclo/swift_tar
#   brew trust raliclo/swift_tar
#   brew install raliclo/swift_tar/swift_tar
#
# `brew trust` is required: Homebrew refuses to load a formula from a third-party tap until the
# tap is trusted ("Refusing to load formula ... from untrusted tap"), as csv2 found under
# Homebrew 6 and 7.
#
# The url and sha256 below are written by publish.zsh from the archive it published, never by
# hand, and read back afterwards. Only macOS arm64 is offered. The url is at the top level, as
# the formula's default, because Homebrew 7 evaluates a formula for every (OS, arch) it knows
# and one with no url at all fails the whole tap; `depends_on` then refuses the contexts that
# have no archive, rather than letting them fetch a binary they cannot run.
#
# swift_tar 的 Homebrew formula，公開版（不含 LZFSE）。
#
# 這個 repo 本身就是 tap：
#
#   brew tap raliclo/swift_tar https://github.com/raliclo/swift_tar
#   brew trust raliclo/swift_tar
#   brew install raliclo/swift_tar/swift_tar
#
# `brew trust` 不能省：Homebrew 在第三方 tap 被信任之前拒絕載入其 formula（「Refusing to load
# formula ... from untrusted tap」），csv2 在 Homebrew 6 與 7 都遇過。
#
# 下面的 url 與 sha256 由 publish.zsh 依它發布的封存寫入，絕不手打，寫完再讀回。只提供 macOS
# arm64。url 放在頂層當作預設，因為 Homebrew 7 會對它認識的每一種 (OS, 架構) 各求值一次，完全沒有
# url 的組合會讓整個 tap 失敗；`depends_on` 則拒絕沒有封存的組合，而不是讓它們抓走一個執行不了的
# 執行檔。
class SwiftTar < Formula
  desc "Multi-core tar archiver: gzip, bzip2, xz, zstd, lz4, ZIP/ZIP64, encryption"
  homepage "https://github.com/raliclo/swift_tar"
  version "0.1.5"
  license "GPL-3.0-only"

  url "https://github.com/raliclo/swift_tar/releases/download/v0.1.5/swift_tar-0.1.5-macos-arm64.tar.zst"
  sha256 "a196eb8b5aea4f871f50902bd552b93296defab06b4d7ba4d5f8bc61d3b18c75"

  depends_on arch: :arm64
  depends_on :macos

  def install
    bin.install "swift_tar"
    prefix.install Dir["*.txt"]
  end

  # A round trip, not only --version: a binary that prints its version has shown only that it
  # starts.
  # 做一次往返，而不只是 --version：印得出版本只證明它啟動得起來。
  test do
    (testpath/"in/a.txt").write("pkg,license\nzlib,MIT\n")
    system bin/"swift_tar", "-c", "--gzip", "-f", testpath/"a.tar.gz", "-C", testpath/"in", "a.txt"
    mkdir testpath/"out"
    system bin/"swift_tar", "-x", "-f", testpath/"a.tar.gz", "-C", testpath/"out"
    assert_equal "pkg,license\nzlib,MIT\n", (testpath/"out/a.txt").read
    assert_match "swift_tar 0.1.5 (v0.1.5 / ", shell_output("#{bin}/swift_tar --version")
  end
end
