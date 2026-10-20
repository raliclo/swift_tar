# licenses/ — 隨正式版出貨的第三方授權 / third-party licences shipped with releases

`release.zsh` 把這裡的檔案原封不動放進正式封存。它們對應的是**連結進執行檔、或與執行檔一起
出貨**的元件，而這些元件的原始碼不在本 repo 的子模組裡（zlib、zstd、libarchive、xz、lz4 的授權
直接取自各自的子模組，不在這裡）。

`release.zsh` copies these files unchanged into the release archives. They cover the components
that are linked into the binary, or shipped beside it, whose source is not a submodule of this
repo. zlib, zstd, libarchive, xz and lz4 take their licences from their own submodules instead.

哪些平台帶哪些 / Which archive carries which:

- **Linux（musl 靜態）**：全部。Swift Static Linux SDK 6.4.0（static-linux-0.1.0）把 Swift runtime、
  Foundation（含 ICU）、libdispatch、musl、musl-fts、libc++／libc++abi／libunwind／compiler-rt 與
  bzip2 靜態連入。2026-10-20 以 `-Xlinker -Map` 確認實際被拉進來的封存檔；SDK 裡的 mimalloc、curl、
  libxml2、BoringSSL 沒有被連入，所以不在這裡。
  **Linux (static musl)**: all of them. The Swift Static Linux SDK links in the Swift runtime,
  Foundation (with ICU), libdispatch, musl, musl-fts, libc++/libc++abi/libunwind/compiler-rt and
  bzip2. Confirmed on 2026-10-20 from a `-Xlinker -Map` link map; the SDK's mimalloc, curl,
  libxml2 and BoringSSL are not linked, so they are not here.
- **Windows**：Swift runtime 那一組（下表標 W），因為封存附帶 Swift runtime DLL。
  **Windows**: the Swift runtime set (marked W), because the archive carries the Swift runtime DLLs.
- **macOS**：沒有。執行檔動態連結系統的 Swift runtime 與 libbz2。
  **macOS**: none; the binary links the system's Swift runtime and libbz2 dynamically.

| 檔案 / file | 元件 / component | 版本 / version | 授權 / licence | 平台 | 來源 / source |
|---|---|---|---|---|---|
| swift-LICENSE.txt | Swift runtime (swiftCore, Concurrency, Synchronization, swiftMusl) | swift-6.4.0-RELEASE | Apache-2.0 + Runtime Library Exception | L W | github.com/swiftlang/swift `LICENSE.txt` |
| swift-experimental-string-processing-LICENSE.txt | _StringProcessing, _RegexParser | swift-6.4.0-RELEASE | Apache-2.0 + RLE | L W | github.com/swiftlang/swift-experimental-string-processing `LICENSE.txt` |
| swift-corelibs-foundation-LICENSE.txt | Foundation, CoreFoundation | swift-6.4.0-RELEASE | Apache-2.0 + RLE | L W | github.com/swiftlang/swift-corelibs-foundation `LICENSE` |
| swift-foundation-LICENSE.txt | FoundationEssentials, FoundationInternationalization, _FoundationCollections | swift-6.4.0-RELEASE | Apache-2.0 + RLE | L W | github.com/swiftlang/swift-foundation `LICENSE.md` |
| swift-foundation-icu-LICENSE.txt | _FoundationICU（Apple 的封裝 / Apple's packaging） | swift-6.4.0-RELEASE | Apache-2.0 + RLE | L W | github.com/swiftlang/swift-foundation-icu `LICENSE.md` |
| icu-LICENSE.txt | ICU4C（_FoundationICU 內含 / inside _FoundationICU） | 76.1 | Unicode-3.0 等 / and others | L W | github.com/unicode-org/icu `release-76-1` `LICENSE` |
| swift-corelibs-libdispatch-LICENSE.txt | libdispatch, BlocksRuntime, swiftDispatch | swift-6.4.0-RELEASE | Apache-2.0 | L W | github.com/swiftlang/swift-corelibs-libdispatch `LICENSE` |
| llvm-libcxx-LICENSE.txt | libc++ | swift-6.4.0-RELEASE | Apache-2.0 WITH LLVM-exception | L | github.com/swiftlang/llvm-project `libcxx/LICENSE.TXT` |
| llvm-libcxxabi-LICENSE.txt | libc++abi | swift-6.4.0-RELEASE | Apache-2.0 WITH LLVM-exception | L | github.com/swiftlang/llvm-project `libcxxabi/LICENSE.TXT` |
| llvm-libunwind-LICENSE.txt | libunwind | swift-6.4.0-RELEASE | Apache-2.0 WITH LLVM-exception | L | github.com/swiftlang/llvm-project `libunwind/LICENSE.TXT` |
| llvm-compiler-rt-LICENSE.txt | compiler-rt builtins | swift-6.4.0-RELEASE | Apache-2.0 WITH LLVM-exception | L | github.com/swiftlang/llvm-project `compiler-rt/LICENSE.TXT` |
| musl-COPYRIGHT.txt | musl libc | 1.2.5 | MIT | L | git.musl-libc.org `COPYRIGHT` @ v1.2.5 |
| musl-fts-COPYING.txt | musl-fts | 1.2.7 | BSD-3-Clause | L | github.com/void-linux/musl-fts `COPYING` @ v1.2.7 |
| bzip2-LICENSE.txt | libbz2 | 1.0.8 | bzip2-1.0.6 | L | sourceware.org/git bzip2 `LICENSE` @ bzip2-1.0.8 |

版本取自 SDK 的 `sbom.spdx.json` 與 swift-foundation-icu 的 `uvernum.h`。換 Swift 或 SDK 版本時，
請依新版本重新取這些檔案，並更新上表。

Versions come from the SDK's `sbom.spdx.json` and swift-foundation-icu's `uvernum.h`. When the
Swift toolchain or SDK changes, fetch these again at the new versions and update the table.
