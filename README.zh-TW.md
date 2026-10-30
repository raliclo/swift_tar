# swift_tar

以 Swift 撰寫的**多核心 `tar` 打包工具**，建構於 `lzfse2` 壓縮引擎之上，
並仿照 **libarchive** 的 filter 架構設計。

- **English: [README.md](./README.md)**
- **[FAQ.md](./FAQ.md)** — VM 核心數、模擬成本，以及傳輸時該用 swift_tar 還是
  bsdtar 打包，皆附實測數字

## 特色

- **ustar + pax** 容器：支援長路徑、大於 8 GiB 的檔案、符號連結、硬連結
  去重、FIFO（POSIX），可與 `bsdtar` / GNU `tar` 互通。
- **多核心壓縮**：封存位元組串流切成 4 MiB 分塊併發壓縮、再按序寫回——
  與 `lzfse2` 的 `runParallelEncode` 為同一套併發骨架。
- **libarchive 式讀取 filter**：依 magic 位元組自動偵測格式，且 filter
  可疊層（例如 `payload.tar.gz.uu`）。
- **真實 ZIP/ZIP64 後端**：macOS 與 Windows 均使用內附 libarchive 建立及讀取
  標準 ZIP 容器；需要時自動使用 ZIP64，也可明確強制。
- **認證加密**：以 ChaCha20-Poly1305 對 4 MiB 分塊加密，並如 codec 一般依
  `-n` 併發封裝；加密層疊在壓縮引擎之外，因此任何封存皆可加密；竄改、重排與
  截斷都能偵測；讀取時會自動偵測並解密，不需任何旗標。純 Swift 實作——
  不使用 CryptoKit 或 OpenSSL。
- **C 庫用法仿 libarchive**：`zlib` / `libbz2` / `liblzma` / `libzstd` /
  `liblz4` 只提供壓縮原語，容器框架由 swift_tar 自組；`compress`/LZW、
  uudecode 與 RPM 外包裝為 libarchive 內建 filter 的純 Swift 移植。

## 建置

需要 Xcode 工具鏈（`swiftc`）與 `cmake`：

```sh
git submodule update --init   # lzfse2 + libarchive + zlib + xz + lz4 + zstd
./build.zsh                    # → release/swift_tar
```

不需要任何 Homebrew 套件。`liblzma`、`liblz4` 與 `libzstd` 由 `build_codecs.zsh`
以固定版本的 submodule 建出並靜態連結，因此執行檔內的版本是一項被 commit 過的事實，
而非 `brew upgrade` 最後裝上的那一份。`zlib` 與 `libbz2` 取自 SDK，動態連結，
`compile_tar.zsh` 會把實際連結的 dylib 記入 `version-mac.txt`。macOS 採用系統 zlib，
因為在 Apple silicon 上它的解壓比固定版 1.3.2 快約 1.9 倍（gzip 與 ZIP 解壓快 1.6–1.7 倍），
壓縮輸出逐位元組相同。其他平台仍使用固定版 zlib。

`build.zsh` 以 `uname` 偵測平台並執行該平台的建置——macOS 用 `compile_tar.zsh`、
Linux 用 `compile_tar-linux.zsh`、Windows 用 `compile_tar-win.bat`——故同一道指令在
三者皆可用。`./build.zsh --platform` 只印出偵測到的平台名稱而不建置。直接呼叫各平台
腳本仍然可行。

在 macOS 上，**單獨執行 `compile_tar.zsh` 只會建置**：結果留在 `release/swift_tar`，建置結束時印出
安裝用的指令。加上 `--install`（或 `-install`）才會另外複製到 `/opt/homebrew/bin/swift_tar`。
`build.zsh` 與 `compile_no_lzfse.zsh` 會自行帶上 `--install`，所以它們會安裝。

### Linux

`compile_tar-linux.zsh` 需要 Swift 工具鏈與各 codec 的 header 與共享函式庫。兩者皆以
探測而非假設決定：存在時使用 `/workspace/opt/swift` 與 `/workspace/sysroot`（即
`sos/linux_kernal_vm_interactive` 下的 buildroot aarch64 設備），否則改用 `PATH` 上的
`swiftc` 與 `/usr`。可用 `SWIFT_PREFIX` 與 `SYSROOT` 覆寫。

libarchive 一律由 `libarchive/` submodule 加上本樹的 patch 靜態建出，與 macOS 相同；缺 cmake
或原始碼時腳本直接停止。與 macOS 版仍有兩點不同。只有在 cmake 與原始碼都在時，四個有
submodule 的 codec（zlib、liblzma、liblz4、libzstd）才由本樹靜態建出；缺少時腳本改連結
sysroot 的共享庫並明白說出來，而這種建置的內容不是 submodule 的 pin。bzip2 一律使用 sysroot
的。設定 `CODECS_STATIC` 為 `1` 或 `0` 可直接決定。另外，未 checkout `lzfse2/` 時會自動套用 `-DEXCLUDE_LZFSE`，使同一支腳本無需
旗標即可服務完整 clone 與純原始碼投放兩種情況。

工具鏈的 `ld.lld` 起得來時，連結就用它。`ld.lld` 載入時需要 `libxml2.so.2`；只缺這一項時，
腳本用 clang 從 `libxml2/` submodule 建出它，並且只放進連結器的函式庫路徑。其餘情況改用系統的
`ld` 連結並明白說出來。swift_tar 本身不連結 libxml2。編譯與連結分成兩步：aarch64 上的 Swift 會把
`.rodata` 標成可寫，腳本在兩步之間把目的檔上的這個旗標拿掉，並拒絕 `.rodata` 可寫的執行檔。

已於 QEMU 下的 aarch64 Linux（buildroot、glibc、Swift 6.4.0）驗證：建置無誤、正確記錄
RPATH，並將所連結的函式庫寫入 `version-linux.txt`。

建置時將 `lzfse2/lzfse-cli.swift` 當函式庫重用（剝除其頂層 `runCLI()`
進入點後兩檔合併編譯），並連結 `-lz -lbz2 -llz4 -llzma -lzstd` 與內附的
靜態 libarchive ZIP 後端。
二進位輸出至 **`release/swift_tar`**。若缺少 `lzfse2` submodule，建置會以錯誤中止，
並提示執行 `git submodule update --init` 或改用下方不含 LZFSE 的建置。

### 不含 LZFSE 的公開版

`compile_no_lzfse.zsh`（`compile_tar.zsh --no-lzfse` 的包裝）建置「公開／可散布」版
binary，完全**不含**私有 LZFSE 引擎——不編譯 `lzfse-cli.swift`，因此既不能建立也
不能解碼任何 LZFSE 家族封存（`other3` / `bvx3` / `bvx2`），binary 內也無任何 LZFSE
程式碼或格式字串。標準外部 codec、純 tar 與 ZIP/ZIP64 不受影響。
此建置不需要 `lzfse2` submodule。

```sh
./compile_no_lzfse.zsh         # → release/swift_tar（公開版、不含 LZFSE）
./test/test_no_lzfse.zsh            # 驗證排除是否生效，且標準 codec 仍可用
```

### Windows

Windows 需要 Swift、CMake 與 Visual Studio 2022 C++ workload。建置腳本會以 Swift 工具鏈的
clang（MSVC ABI；量測比 cl.exe 快，見 `verifications/README.zh-TW.md`）把固定版本的 zlib、zstd 與
libarchive submodule 編譯成靜態庫，再直接把
gzip、zstd 與 ZIP 支援連結進 `swift_tar.exe`；執行時不需要 `zlib.dll`、外部 `gzip.exe`，也不需要每個
chunk 生一個 `zstd.exe`。

```bat
build_tool_install-win.bat
git submodule update --init
zsh ./build_zlib-win.zsh
zsh ./build_zstd-win.zsh
compile_tar-win.bat
```

在乾淨 Windows 上，`build_tool_install-win.bat` 會先透過 PowerShell 建立 Scoop 與
zsh，再交給完整的 zsh 安裝器；已安裝 zsh 時重跑亦安全。

`build_zlib-win.zsh` 與 `build_zstd-win.zsh` 是相依套件維護步驟：各自同步固定的
gitlink、重建靜態庫（`zs.lib`／`zstd_static.lib`），並將精確的 tag、commit 與
連結方式寫入 `version-win.txt`。zstd 的 CMake binary tree 位於 submodule 外的
`build/zstd-win`，因此產生檔不會被廣泛的 submodule ignore 規則隱藏。
首次 clone 或變更任一 submodule 後才需執行；平常的
`compile_tar-win.bat` 會增量重建 libarchive 後端並重用既有 zlib/zstd 靜態庫。
建置版本產生流程會在 `version-win.txt` 保留 `zlib_*`、`zstd_*` 與 `libarchive_*`
provenance 欄位，封裝步驟也會將該檔案以 `version.txt` 之名放入 Windows ZIP，供
release 驗證。

版本戳檔案依平台加後綴——`version-mac.txt`、`version-win.txt`、`version-musl-<arch>.txt`，
以及不入版控、由 glibc 開發建置產生的 `version-linux.txt`——因為它記錄的是*本次*建置實際連結到哪些函式庫。共用單一檔案時，
最後建置的那個平台會覆寫掉另一個平台的 provenance。

其餘外部 codec（bzip2、xz、lz4、lzip）仍需要對應的 Scoop CLI 工具；
`build_tool_install-win.bat` 會先完成 bootstrap，再交給
`build_tool_install-win.zsh` 安裝完整工具鏈。

Windows ZIP 包含靜態連結的執行檔、Swift runtime DLL、`version.txt`（由
`version-win.txt` 放入）、
`swift_tar-LICENSE.txt`、`zlib-LICENSE.txt`、`zstd-LICENSE.txt` 與
`libarchive-COPYING.txt`。
`zs.lib`、`zstd_static.lib`、headers 與
CMake build tree 屬於開發產物，並非 runtime dependency，因此不放入 release。

## 安裝正式版

正式版是公開版（不含 LZFSE），每個平台一份 `.tar.zst`，放在
[GitHub Releases](https://github.com/raliclo/swift_tar/releases)，旁邊各附一個 `.sha256`。
`swift_tar --version` 會印出版本號、build id（在 tag 上建的執行檔是 `v0.1.1 / <commit>`）
與來源戳記。

```sh
# macOS（Apple silicon）——這個 repo 本身就是 tap；`brew trust` 不能省
brew tap raliclo/swift_tar https://github.com/raliclo/swift_tar
brew trust raliclo/swift_tar
brew install raliclo/swift_tar/swift_tar

# Windows（x86-64）——bucket 在上層的 lzfse2 repo
scoop bucket add raliclo https://github.com/raliclo/lzfse2
scoop install raliclo/swift_tar

# Linux（x86-64 或 aarch64）——完全靜態：解開後把 swift_tar 放上 PATH
sha256sum -c swift_tar-0.1.1-linux-x86_64.tar.zst.sha256
zstd -dc swift_tar-0.1.1-linux-x86_64.tar.zst | tar -xf -
```

### 發布正式版

`VERSION` 記著下一個正式版要帶的版本號。順序是：預演、打 tag、在 tag 上建置、收集、發布。

1. 每個平台都先預演一次，再把封存丟掉。這一步要在打 tag 之前做：封存建好之後才移動 tag，
   每一份都會作廢。
   - macOS arm64，在 Mac 上：`./compile_tar.zsh --no-lzfse`，再 `./release.zsh`。
   - Windows x86-64，在 Windows 上：`EXCLUDE_LZFSE=1 zsh ./compile_tar-win.zsh`，再
     `./release.zsh`。封存會帶著 Swift runtime DLL。
   - Linux aarch64 與 x86-64，都在 Mac 上：`./compile_tar-musl.zsh <arch>`，再
     `SWIFT_TAR_PLATFORM=musl-<arch> ./release.zsh`。這兩份對 musl 完全靜態連結（Swift 的
     Static Linux SDK、swift.org toolchain 6.4.0），所以目標機器上什麼都不需要：不需要某個
     版本的 glibc、不需要 libbz2、不需要 Swift。Mac 跑不了它們，所以 `release.zsh` 從檔案
     檢查，再由 `./verify_release.zsh <封存>` 在同架構的 Linux 機器上執行。
2. 把 commit 打上 `v<VERSION>` 並推送 tag；各節點 fetch tag。
3. 每個平台再建一次並跑 `release.zsh`。它拒絕：工作區不乾淨、執行檔的 build id 不是這個
   checkout 的、完整版、以及已存在的封存。macOS 與 Windows 上它以解開、執行、完成一次
   `.tar.gz` 往返、確認 LZFSE 被拒絕來驗證；Linux 則在每種架構上跑 `verify_release.zsh`，
   它在空環境下做同樣的事，並執行內建的自我測試。
4. 把四份封存與它們的 `.sha256` 收到 Mac 的 `dist/`
   （`/Volumes/LinuxCS/helper/collect_release.zsh swift_tar <VERSION>` 會取回 Windows 那份）。
5. `./publish.zsh <VERSION>` 只說會做什麼；`./publish.zsh <VERSION> --publish` 建立 GitHub
   Release、從公開網址把每個資產下載回來比對，並改寫 `Formula/swift_tar.rb` 與上層 repo 的
   `bucket/swift_tar.json`。兩者都要提交。

`test/test_release.zsh` 涵蓋 build id、`release.zsh` 的每一道拒絕、套件檔的改寫，以及
`publish.zsh` 前段的拒絕，全程不發布。

## 使用方式

```
swift_tar -c|-x|-t|-r|-u|--delete|--identify|--cat|--encrypt-only|--decrypt-only
          [-f <archive>] [codec]
          [--encrypt|--keyfile <path>] [-C <dir>] [--strip-components N] [-n N] [-v] [files...]
```

| 指令 | 意義 |
|------|------|
| `-c`    | 建立封存檔 |
| `-x`    | 解出封存檔（若已加密會自動解密） |
| `-t`    | 列出封存內容（若已加密會自動解密） |
| `-r`    | 將檔案追加到封存檔尾端（僅未壓縮 tar） |
| `-u`    | 僅追加比封存副本新、或尚不存在的檔案（僅未壓縮 tar） |
| `--delete` | 就地從封存移除指定項目（僅未壓縮 tar；swift_tar 獨有——BSD tar 無 `--delete`） |
| `--identify` | 依 magic 位元組偵測壓縮格式並印出 filter 鏈（例如 `gzip → tar`）後即停，不解壓；任何檔名皆可 |
| `--cat` | 解密並僅解壓 filter 鏈、原始內容輸出至 stdout（等同 `bsdcat`） |
| `--encrypt-only` | 原樣加密 `-f` 指定的檔案（不做 tar、不壓縮）並輸出至 stdout |
| `--decrypt-only` | 僅剝除 `-f` 的加密層並輸出至 stdout；壓縮內容維持壓縮 |
| `--rgb1-pack` / `--rgb1-info` / `--rgb1-raw` | RGB1 原始影像容器：將 raw RGB bytes 包上標頭、印出標頭欄位，或移除標頭還原 raw payload |

`-f -`（或省略 `-f`）表示讀取標準輸入／寫至標準輸出，可組進管線。


### 建立範例

```sh
release/swift_tar -c --bvx3-optimal -f src.tar.bvx3 src/
release/swift_tar -c --gzip         -f src.tar.gz    src/     # 標準 .tar.gz
release/swift_tar -c --zip          -f src.zip       src/     # 標準 ZIP
release/swift_tar -c --zip64        -f src.zip       src/     # 強制 ZIP64 記錄
release/swift_tar -c --zip --zip-unsorted -f src.zip src/     # 成員依檔案系統的順序，不排序
release/swift_tar -c --zstd -f src.tar.zst -C /path/to parent-leaf
tar -cf - src/ | release/swift_tar -c --xz -f src.tar.xz -    # （或以管線灌入）
```

建立模式下，`-C <dir>` 會先切換輸入工作目錄，再封存後方列出的 leaf path，
語意與系統 tar 一致。相對 `-f` 路徑仍以原始呼叫目錄為基準建立。使用
`-C <parent> <leaf>` 可避免封存項目名稱包含 parent path 或 `..`。

`-C` 在目標目錄不存在時，兩側行為並不相同：

| 模式 | `-C` 目標不存在時 | |
|---|---|---|
| 解壓（`-x`） | **自動建立，含中間各層**，再解出至該處 | exit 0 |
| 建立（`-c`） | 拒絕：`cannot chdir to '<dir>'` | exit 1 |

由於解壓端會建立目錄而非失敗，`-C` 路徑打錯時會在打錯的位置長出一棵新的目錄樹，且離開碼
為 0。若您的腳本需要攔下這種情形，請在解壓前自行檢查目錄是否存在。

輸出格式由 codec 旗標決定，不是由副檔名決定。例如
`--gzip -f archive.zip` 寫出的仍是 gzip 壓縮 tar stream（magic `1f 8b`），
不是真正的 ZIP container。建立真實 ZIP 請使用 `--zip`；libarchive 會在需要時
自動寫入 ZIP64，`--zip64` 則可強制寫入 ZIP64 記錄。

### 加密與解密

`--encrypt` 以 **ChaCha20-Poly1305** 加密封存。加密層位於壓縮引擎**之外**，
因此任何 **tar** codec——或純 tar——都能加密，解開時內層的 codec 仍會自動偵測。

**`--zip` 與 `--zip64` 無法加密。** 加密僅適用於 tar 壓縮引擎，與 ZIP 輸出併用會被拒絕：

```sh
release/swift_tar -c --zip --encrypt -f out.zip src/
# -> Error: --encrypt is not supported for ZIP output ...   離開碼 1，不產生檔案
```

請改用 tar 壓縮引擎加密（`--zstd`、`--gzip` 或純 tar）。

```sh
release/swift_tar -c --encrypt        -f secret.tar.enc src/   # 提示輸入密語
release/swift_tar -c --encrypt --gzip -f secret.tgz.enc src/   # 加密的 .tar.gz
release/swift_tar -c --keyfile k.bin  -f secret.tar.enc src/   # 金鑰取自檔案
```

#### 解密

**沒有 `--decrypt` 旗標，因為不需要。** 讀取時會依 magic 偵測加密並自動解密，
與自動偵測 gzip 或 zstd 完全一樣。只要提供金鑰，用你原本就要用的讀取模式即可：

| 指令 | 得到什麼 |
|------|---------|
| `-x` | 解出檔案（解密 → 解壓 → 解 tar） |
| `-t` | 項目清單 |
| `--cat` | stdout 上的原始內容（解密**並**解壓） |
| `--decrypt-only` | stdout 上仍為壓縮狀態的封存（僅解密） |
| `--identify` | filter 鏈與 tar／raw 類型；加密輸入只解密足以辨識內層 filter 與 payload 類型的資料，不解出檔案 |

```sh
release/swift_tar -x -f secret.tar.enc -C /tmp/out      # 提示輸入密語
release/swift_tar -t --keyfile k.bin -f secret.tar.enc  # 金鑰取自檔案
release/swift_tar --identify --keyfile k.bin -f secret.tgz.enc
#   secret.tgz.enc: encrypted (ChaCha20-Poly1305) → gzip → tar
```

金鑰錯誤、遭竄改或被截斷時，指令會以非零狀態碼失敗。解密採串流處理；若較後的
chunk 驗證失敗，先前已通過驗證的明文可能已寫入 stdout 或解出目錄。失敗指令的
所有輸出都應視為不完整並丟棄。

#### 不重新打包的加密與解密

`--decrypt-only` **只**剝除加密層，內容維持壓縮；`--encrypt-only` 則原樣加密
既有檔案。兩者都以 `-f` 指定輸入、寫到 stdout，形狀與 `--cat` 相同：

```sh
swift_tar --decrypt-only --keyfile k.bin -f secret.tgz.enc > secret.tar.gz
swift_tar --encrypt-only --keyfile k.bin -f archive.tar.gz > archive.tgz.enc
```

若連壓縮也要解開請改用 `--cat`——它回傳原始 tar，而 `--decrypt-only` 交還的是
仍然合法的 `.tar.gz`。

#### 金鑰

密語自終端機讀取且不回顯（因此不會進入 shell 歷史），建立時需再次確認；
並以 **scrypt**（N=2¹⁵、r=8、p=1）延展。`--keyfile <path>` 則改用該檔案的
位元組作為金鑰材料，且在 **stdin 不是終端機時（例如管線中）為必要**——
swift_tar 寧可報錯，也不會靜默寫出未加密的封存。

keyfile **沒有格式要求**：文字或二進位、任何長度皆可，位元組原樣使用，
僅空檔案會被拒絕。有兩點務必知道：

- **結尾換行也是金鑰的一部分。** `printf 'secret' > k` 與 `echo secret > k`
  產生的是**不同**金鑰。請用產生的方式而非手動輸入：
  `head -c 64 /dev/urandom > k.bin && chmod 600 k.bin`。
- **`--keyfile` 不執行 KDF**，因為假設其材料為高熵。請勿把人為選定的短密碼放進
  keyfile——那種情況應改用 `--encrypt`，讓它經過 scrypt。

**這個格式防護什麼**。每個 4 MiB 分塊各自封裝，且每個分塊的 AAD 都綁定完整
標頭與分塊索引，並以一個已認證的結尾標記收尾：

| 攻擊 | 由什麼偵測 |
|------|-----------|
| 竄改密文 | 每分塊的 Poly1305 tag |
| 竄改標頭（salt、KDF 成本） | 完整標頭是每個分塊 AAD 的一部分 |
| 重排或重複分塊 | AAD 與 nonce 中的分塊索引 |
| 截斷封存 | 必須存在已認證的結尾標記 |

金鑰錯誤、任何竄改或檔案被截斷，都會讓指令以非零狀態碼失敗；絕不會把不完整
的明文當成有效內容回傳。

`-r`、`-u` 與 `--delete` 不適用於加密封存。

密碼學原語依規範實作，並對照其公開測試向量驗證（RFC 8439、RFC 4231、
RFC 7914、FIPS 180-4）。可用 `--crypto-selftest` 執行，完整測試套件則為
`./test/test_encrypt.zsh`。Windows/MSYS 可用 `verifications/encrypt_windows_correctness.zsh`
針對 `release/swift_tar.exe` 重跑 self-test 與 CLI smoke suite；Windows MB/s
吞吐量則使用 `verifications/encrypt_mbps_win.zsh`。

### 追加／更新／刪除

```sh
release/swift_tar -r -f archive.tar -C src newfile      # 追加 newfile
release/swift_tar -u -f archive.tar -C src src/         # 僅追加較新／不存在的成員
release/swift_tar --delete -f archive.tar old.txt dir/  # 就地移除成員
```

`-r`、`-u`、`--delete` 僅作用在**未壓縮** tar——帶 codec 旗標會被拒絕，壓縮的
`-f` 封存也會被拒。主流 tar（GNU、BSD/libarchive、star）同樣都不支援對壓縮封存
做這些操作，原因相同：尾端 EOF 封在最後一個壓縮 frame 內，無法廉價 seek 續接。
三者都需要可定位的 `-f` 封存（不可用 stdin/stdout）。

- `-r`（追加）：目標封存不存在時直接建立（GNU tar 語意）。

**`-f` 指定的封存不存在時，兩個追加模式會建立它，其餘模式則拒絕**，因此您身處哪個模式，
決定了封存路徑打錯時會不會被擋下：

| 模式 | `-f` 封存不存在時 |
|---|---|
| `-r`、`-u` | 建立後追加成員——離開碼 0 |
| `--delete`、`-t`、`-x` | 拒絕：`cannot open '<path>'`——離開碼 1 |

對 `-u` 而言這是其自身規則的推論，而非特例：它追加的是較新**或不存在**的成員，而在一個
尚不存在的封存中，每個成員都不存在。
- `-u`（更新）：僅在成員比封存副本新（或不存在）時追加，不改寫也不刪除舊項目——
  解壓時取最後一份。
- `--delete`：重寫封存、去除指定成員（依名稱比對，目錄名可帶或不帶結尾 `/`）。
  這是 swift_tar 擴充功能——macOS 內建的 BSD tar 沒有 `--delete`。

tar 封存中允許同名成員存在，`-r` 與 `-u` 都可能造出重複。由此衍生兩條規則，且與重複是
怎麼產生的無關：

- **解壓時取最後一份。** `-r` 是無條件追加，故追加一個已存在的名稱會讓列表出現兩筆
  項目，解出的是較新的那一份。
- **`--delete` 會刪除該名稱的每一份，而非只刪一份。** 對含有兩筆 `a.txt` 的封存刪除
  `a.txt`，兩筆都不會留下。

### 解出／列出（格式自動偵測）

```sh
release/swift_tar -t -f src.tar.gz
release/swift_tar -t -f src.zip
release/swift_tar -x -f src.tar.bvx3 -C /tmp/out
release/swift_tar --cat -f package.rpm > payload.cpio          # 剝除 RPM 外包裝
```

**同一封存的兩個成員不得落到同一個檔案。** 在區分大小寫的檔案系統上寫出的封存可同時持有
`file.txt` 與 `File.txt`；在不區分大小寫的目的地上，後者會摧毀前者。此情形會被拒絕：

```sh
release/swift_tar -x -f from-linux.tar
# -> 'File.txt' would overwrite 'file.txt', written earlier in this archive
#    (the destination does not distinguish case); pass --force to allow it
```

加上 `--force` 即恢復覆寫。**先前**執行留在磁碟上的既有檔案照常覆寫——本機制僅涵蓋單次解出
之內的碰撞。同一名稱在封存中出現兩次屬合法且不受影響：由最後一份勝出，如上文所述。

**解出行為不會離開 `-C` 指定的目錄。** 成員名稱一律視為懷有敵意，因為封存不保證是由本工具
寫出的：

| 封存中的成員名稱 | 處理方式 |
|---|---|
| `../../x`、`dir/../../x`、`..\..\x` | 略過該項目：`skipping unsafe path '<name>'` |
| `/etc/x`、`C:\Windows\x` | 去除開頭的 `/` 與磁碟機代號，寫入目的地**之內** |
| 路徑穿過「較早項目所建立之 symlink」的成員 | 略過該項目：`path passes through a symlink` |
| 目標指向外部的 symlink 成員，例如 `portal -> ../..` | **照封存內容建立**，以 `0` 結束；加 `--no-links` 則不建立：`skipping link 'portal' (symlink -> ../..)` |

第三列是與第一列不同的攻擊：封存可攜帶一個 symlink `portal -> ../../..`，接著一個成員
`portal/pwned.txt`，而在連結解析後兩者的名稱皆不含 `..`。

**連結本身仍會被建立**，如最後一列所示：被拒絕的是「穿過」它寫入，而不是連結本身。所以封存可以
在您的目錄樹裡留下一個指向外部的連結，之後任何跟隨它的動作都會離開目的地。輸入不可信時，請以
**`--no-links`** 解出：tar 與 ZIP 兩條路徑都不建立任何符號連結或硬連結成員，改為逐一在 stderr
報出。這些訊息是固定格式、供比對用，呼叫端可據以精確回報丟掉了什麼。與 `--exclude` 相同，以此
丟掉的連結不算 `--strict` 的略過；名稱本身不安全的連結仍以不安全路徑拒絕，仍然計數。

```sh
release/swift_tar -x --no-links -f upload.tar.zst -C staging
# -> swift_tar: skipping link 'portal' (symlink -> ../..) / 略過連結 'portal'（符號連結 -> ../..）
# -> swift_tar: skipping link 'b.txt' (hardlink -> a.txt) / 略過連結 'b.txt'（硬連結 -> a.txt）
# -> 離開碼 0，其餘成員全部解出
```

封存能指定的任何名稱，都不會被寫到解出目錄之上。被略過的項目**會**改變離開碼：因為
`--strict` 是預設，`-x` 會回報略過數，並在整次執行結束時以非零結束。其餘每個成員仍會解出。
見[離開碼](#離開碼)一節。

```sh
release/swift_tar -x -f untrusted.tar     # 內含 ../escape.txt 與 good.txt
# -> swift_tar: skipping unsafe path '../escape.txt' / 略過不安全路徑 '../escape.txt'
# -> swift_tar: I/O error: 1 member(s) skipped; pass --no-strict to exit 0 anyway / 略過了 1 個成員；如仍要以 0 結束請加 --no-strict
# -> 離開碼 1，good.txt 已解出
```

只有 stderr 會說出被略過的是*哪一個*成員。

**哪些項目型別會被存下與還原。** 一般檔案、目錄、符號連結、硬連結與 FIFO。納入 FIFO 是因為
任何 POSIX 系統上的 `mkfifo` 都不需權限，該項目必定還原得回來——而且不花成本：它只是一次
`mknod`，比一個空的一般檔案還略便宜。裝置節點與 socket 則不納入：前者需要 root，後者無法由
封存有意義地重建。兩者皆會回報後略過：

```sh
release/swift_tar -c -f out.tar /dev/null
# -> swift_tar: skipping special file '/dev/null' / 略過特殊檔案 '/dev/null'
```

在 Windows 上，FIFO 成員會在 stderr 上被指名並略過，因為該平台沒有 FIFO。**離開碼不會改變**
——含有管線的封存是再尋常不過的封存，其中其餘一切都照常解出：

```sh
release/swift_tar -x -f from-linux.tar -C out
# -> swift_tar: skipping FIFO 'pipe': Windows has no FIFOs / 略過 FIFO 'pipe'：Windows 沒有 FIFO
# -> 離開碼 0，其餘每個成員皆已解出
```

**解出到既有的樹上會取代所遇到的東西。** 重跑一次解出以更新某個目錄是很平常的事，而目的地
很少是乾淨的：

| 目的地既有的東西 | 結果 |
|---|---|
| 可寫的一般檔案 | 覆蓋 |
| 唯讀檔案（`chmod 444`，或 Windows 的唯讀屬性） | 覆蓋——取代一個檔案的權限來自其目錄，而非該檔案本身 |
| FIFO、socket 或裝置節點 | 先移除，再於原處寫入該成員 |
| symlink | 移除，**不**跟隨——成員絕不會穿透它寫到連結目標 |
| 一般檔案，而封存中有同名的**目錄** | 移除，並於原處建立該目錄——`config` 檔案演變成 `config/` 目錄是尋常事件，GNU tar 與 bsdtar 亦同 |
| 目錄，而封存中有同名的**檔案** | 該成員失敗；封存其餘部分照常解出，整次執行以非 0 結束 |

只有最後一列會中止任何東西，而且只中止該成員。無法寫入的成員會在 stderr 上被指名，其餘仍會
落地。另需注意 `-v` 是在處理成員時列出它們，因此失敗的成員同樣會出現在 `-v` 輸出中——要判斷
實際寫出了什麼，應讀 stderr 與離開碼，而非只看 `-v` 的清單。

### 辨識未知檔案

讀取從不看副檔名——codec 由 magic 位元組自動偵測。`--identify` 把這個偵測以類似
`file` 指令的形式回報、但不解壓任何內容，也可從 stdin 讀取：

```sh
release/swift_tar --identify -f mystery.bin     # 例如「mystery.bin: gzip → tar」
cat mystery.bin | release/swift_tar --identify  # 「<stdin>: gzip → tar」
```

一般讀取時，`-v` 會將相同的偵測結果印至 stderr，格式與本工具其他訊息一致為雙語：

```
swift_tar: compression format / 壓縮格式：gzip
swift_tar: compression format / 壓縮格式：none
```

搜尋時請用 `compression format`，不要用 `compression format: gzip`——實際的值接在
中文標籤之後的全形冒號後面。

**ZIP 是例外**：對 ZIP 封存，`-v` 不會印出這一行，因為 ZIP 是容器而非疊在 tar 之上的
filter。請改用 `--identify`，它會正確回報 `zip`。

### RGB1 原始影像容器

`--rgb1-pack` 會把 raw RGB 位元組串包上標頭，標頭中帶有影像尺寸、WGS84 位置與來源
資訊。`--rgb1-info` 將這些欄位印回；`--rgb1-raw` 移除標頭，把原始 payload 寫至 stdout。

**`--rgb1-pack` 需要十個 metadata 旗標**，且皆無預設值——少任何一個都會以
`Missing RGB1 argument ...` 失敗並回傳 1。

```sh
release/swift_tar --rgb1-pack \
  --width 4 --height 4 \
  --lat 25.0330 --lng 121.5654 --height-m 12.5 \
  --title "test tile" --country "Taiwan" \
  --creator-email "you@example.com" --right "CC" \
  --created-ms 1755500000000 \
  -f out.rgb1 raw.rgb

release/swift_tar --rgb1-info -f out.rgb1     # 印出下表欄位
release/swift_tar --rgb1-raw  -f out.rgb1 > back.rgb   # 與 raw.rgb 位元組相同
```

| 旗標 | 型別／範圍 | 說明 |
|---|---|---|
| `--width <W>` | UInt32 像素 | 必要 |
| `--height <H>` | UInt32 像素 | 必要 |
| `--lat <deg>` | WGS84 度，−90…90 | 必要；可為負值 |
| `--lng <deg>` | WGS84 度，−180…180 | 必要；可為負值 |
| `--height-m <m>` | 公尺 | 必要；**標頭中以毫米儲存** |
| `--title <text>` | ASCII，最多 64 bytes | 必要 |
| `--country <text>` | ASCII，最多 512 bytes | 必要 |
| `--creator-email <email>` | ASCII，最多 254 bytes | 必要 |
| `--right <text>` | 1–4 個英文字母 | 必要 |
| `--created-ms <unix_ms>` | Int64，UTC Unix 毫秒 | 必要 |
| `--tz-offset-min <minutes>` | Int16 | **可省**，預設 `480`（台灣） |

位置引數是 raw 輸入，`-f` 指定輸出——與 `-x` 時兩者的角色相反。`--rgb1-info` 會回報
`format`、`width`、`height`、`latitude`、`longitude`、`height_m`、`geo_datum_code`、
`title`、`country`、`creator_email`、`right`、`created_unix_ms`、
`timezone_offset_minutes` 與 `payload_bytes`。已實測往返：以上述指令打包 48 bytes 的
payload 得到 924 bytes 的容器，`--rgb1-raw` 取回的 payload 以 `cmp` 比對完全相同。

## 壓縮引擎旗標（僅建立時）

**本表旗標至多擇一。** 指定兩個不同的旗標會以 `at most one codec flag` 拒絕，離開碼 1，
且不產生任何輸出檔。重複指定同一個旗標（`--gzip --gzip`）則可接受。由此可知
**`--zip64` 本身就是一個 codec，而非 `--zip` 的修飾詞**——`--zip --zip64` 會被視為
衝突而遭拒，故 `--zip64` 請單獨使用。

讀取檔案時一律自動偵測。若 ZIP 來自 stdin，因無法在不消耗輸入的情況下探測，
可明確指定 `--zip`。

| 旗標 | 等同 | 說明 |
|------|------|------|
| `--zip`             | libarchive ZIP                   | Deflate；需要時自動 ZIP64 |
| `--zip64`           | libarchive ZIP64                 | Deflate；強制 ZIP64 記錄 |
| `--other3-fast`    | `lzfse -algo other3`             | 標準 bvx2，Apple 可解 |
| `--other3-optimal` | `lzfse -algo other3 -optimal3`   | 價格驅動 DP，仍是標準 bvx2 |
| `--bvx3-fast`      | `lzfse -algo bvx3`               | 私有大字母表區塊（僅本工具可解） |
| `--bvx3-optimal`   | `lzfse -algo bvx3 -optimal`      | 壓縮率最高、最慢 |
| `--gzip`, `-z`     | zlib                             | 每分塊一個 gzip 成員（pigz 式 `.tar.gz`；不是 ZIP） |
| `--bzip2`, `-j`    | libbz2                           | 每分塊一個 bzip2 串流（pbzip2 式 `.tar.bz2`） |
| `--xz`, `-J`       | liblzma                          | 每分塊一個 xz 串流（標準 xz 多串流） |
| `--lzip`           | lzip CLI                         | 每分塊一個 lzip 串流 |
| `--zstd`           | libzstd                          | 每分塊一個 zstd frame |
| `--lz4`            | liblz4                           | 標準 LZ4 frame |
| *（無）*           | —                                | 不壓縮的純 tar |

tar 壓縮引擎皆輸出可串接串流，故 `gunzip`、`bunzip2`、`xz`、`lzip`、
`zstd` 與 `lz4` 可直接解開。ZIP/ZIP64 是容器後端，可與 `unzip`、`bsdtar`
及其他 ZIP 工具互通。

**FIFO 也會存進 ZIP**，存成長度 0、Unix 模式標示為 FIFO 的項目。swift_tar 會把它解回 FIFO。**其他工具不一定：**
Info-ZIP 的 `unzip` 會解成空的一般檔案，原版 libarchive（`bsdtar`）也一樣，因為它把每個 FIFO
項目都當成一般檔案讀——那是為了 Info-ZIP 會把「正在讀取的管線」記錄成項目型別而做的變通。內附的
libarchive 只在項目不帶任何資料時才保留為 FIFO；見 `patch/libarchive/0002-zip-store-fifo.patch`。

## 已壓縮的後綴（`--skip-compressed`）

`-c --skip-compressed` 搭配串流壓縮引擎（`--zstd`、`--gzip`、`--xz`……）時，若只有**一個一般檔案、
且檔名以下表的後綴結尾**，就改寫成純 tar，並在 stderr 說明。其餘情況一律不變：兩個以上的運算元、
目錄、不在清單內的後綴，或沒加這個旗標，都照常套用壓縮引擎。`--zip` 與 `--zip64` 是容器而非串流
壓縮引擎，不受影響。此旗標預設關閉，所以 `-c --zstd -f out.tar.zst movie.mp4` 除非另外指定，仍會
寫出 zstd。

理由：這些檔案本身已經壓縮過，再套壓縮引擎毫無收益——zstd 會把它們的區塊原樣存放——接收端卻仍要
付出解碼的成本。在 M4 上，512 MiB 隨機資料經管線解出：`--zstd` 封存為 5076 MB/s，`--zstd-parallel` 封存為
2503 MB/s；純 tar 只受管線本身限制。讀取時會自動偵測格式，所以接收端照舊用 `-x --zstd` 也能解出
純 tar。

只依檔名判斷，比較時轉為小寫（`.MP4` 也算 `.mp4`），不檢查檔案內容。清單位於 `swift_tar.swift` 的
`alreadyCompressedSuffixes`，兩邊要一起修改。

| 類別 | 後綴 |
|------|------|
| 壓縮串流與封存——`~/.zshrc` 的 `extract()` 所辨識的格式，再加上幾個同類格式 | `.zip` `.zipx` `.gz` `.tgz` `.bz2` `.tbz2` `.tbz` `.xz` `.txz` `.7z` `.rar` `.zst` `.tzst` `.lz4` `.lz4a` `.lz` `.tlz` `.lzma` `.z`（`.Z`）`.br` `.cab` |
| 本專案的 LZFSE 輸出（`.bvx3` 與 `.other3` 系列只在完整版：公開版不帶任何私有引擎的名稱） | `.lzfse` `.lzfse.apple`；完整版另有 `.lzfse.bvx3` `.lzfse.bvx3.lazy2` `.lzfse.bvx3.optimal` `.lzfse.other3` `.lzfse.other3.optimal3` |
| 內部為 ZIP 或壓縮容器的套件與文件 | `.jar` `.war` `.apk` `.aab` `.ipa` `.xip` `.whl` `.nupkg` `.epub` `.docx` `.xlsx` `.pptx` `.odt` `.ods` `.odp` `.dmg` `.pkg` |
| 影片——MPEG-4 與其他高壓縮率格式（常見容器內的 H.264、HEVC、VP9、AV1） | `.mp4` `.m4v` `.mov` `.mkv` `.webm` `.avi` `.wmv` `.flv` `.mpg` `.mpeg` `.m2v` `.m2ts` `.mts` `.3gp` `.hevc` `.h264` `.h265` |
| 音訊 | `.mp3` `.aac` `.m4a` `.ogg` `.oga` `.opus` `.flac` `.wma` |
| 影像 | `.jpg` `.jpeg` `.png` `.gif` `.webp` `.heic` `.heif` `.avif` `.jxl` |

刻意不列入：`.tar`（未壓縮）、`.iso` 與 `.vmdk`（通常是原始磁碟映像）、`.ts`（也是 TypeScript
原始碼）、`.pdf`（只有部分壓縮）、`.wav` 與 `.bmp`（未壓縮）。

## 讀取端 filter（自動偵測、可疊層）

uuencode（傳統與 base64）· 帶 RPM 外包裝的檔案 · gzip · bzip2 ·
compress/LZW（`.Z`）· lzma · lzip · xz · lz4 · zstandard · LZFSE 家族
（bvx2/bvx3，以多核心平行解碼器解開）· swift_tar 自有的加密層
（先解密，內層 codec 再照常偵測）。

`lzop` 可被偵測，但除非系統有 `liblzo2`，否則回報為不支援——與未編入 lzo
支援的 libarchive 行為一致。

## 選項

**`--` 表示選項到此為止。** 其後的一切皆視為檔名，這正是封存「以減號開頭的名稱」的方法：

```sh
swift_tar -c -f out.tar -- -report.csv notes.txt   # 封存 -report.csv
swift_tar -c -f out.tar ./-report.csv              # 不用 -- 也可行
swift_tar -c -f out.tar -report.csv                # 遭拒：被讀成短旗標叢集
```

若不加 `--`，開頭的減號會被讀成短旗標叢集，於是 `-report.csv` 回報 `unknown option -e`
——一個本工具並不存在的旗標。以減號開頭的檔名是循正常途徑產生的：下載、自他人封存中解出、
自動產生的報表名稱。

**同一個選項重複出現時，生效的是第一個，而非最後一個。** 這與一般慣例相反，且適用於所有
帶值的選項，不只某一個：

```sh
swift_tar -c -f out.tar -C c1 -C c2 f.txt        # 封存的是 c1/f.txt
swift_tar -c --zstd --zstd-level 1 --zstd-level 19 ...   # 以等級 1 壓縮
swift_tar -c -f first.tar -f second.tar ...      # 寫出 first.tar；second.tar 不會被建立
```

較後出現的那一個被捨棄時不會有任何提示——指令以 0 結束，產出的是依較早的值建立的封存。
因此，編輯長命令列時多打的一個重複選項，或是把旗標附加到既有引數清單的腳本，都會無聲地
生效，且方向與多數人的預期相反。

| 選項 | 意義 |
|------|------|
| `-f <path>` | 封存檔路徑（`-` 表標準輸入／輸出；預設 `-`） |
| `-C <dir>`  | 建立前切換輸入目錄（須已存在）；讀取時解出至此目錄（不存在則自動建立） |
| `--strip-components <N>` | （僅 `-x` tar 解出）寫入前移除成員路徑前 N 層；也接受 `--strip-components=N` |
| `--zstd-level <N>` | （僅 `--zstd`）壓縮等級，`1`…`22`，預設 `9`。超出範圍或非數字時離開碼為 **2**。未同時指定 `--zstd` 則靜默忽略——見下 |
| `--no-checksum`、`-no-checksum` | （`-c` 搭配 `--zstd`、`--lz4` 或 `--xz`）不寫入內容校驗碼。**預設會寫入**：每個 zstd frame 一個 XXH64 的低 32 位元、每個 lz4 frame 一個 XXH32、每個 xz 串流一個 CRC64，使損壞的分塊解碼失敗，而不是解出錯誤的位元組。gzip、bzip2、lzip 與 ZIP 一律帶 CRC，此旗標對它們沒有影響。 |
| `--skip-compressed` | （`-c` 搭配串流壓縮引擎）只有一個一般檔案且後綴屬於已壓縮格式時，改寫成純 tar。預設關閉；清單與理由見〈已壓縮的後綴（`--skip-compressed`）〉一節 |
| `--strict`、`--no-strict` | （`-x`）**預設為嚴格：** 略過成員時，`-x` 在其餘成員都解出之後以非零結束；`--exclude` 命中者不算。`--no-strict` 在略過後仍以 `0` 結束。`--strict` 供想明說的呼叫端使用。見〈離開碼〉一節 |
| `--no-links` | （`-x`，tar 與 ZIP）不建立任何符號連結或硬連結成員，改為在 stderr 逐一報出，每個成員一行：`swift_tar: skipping link '<名稱>' (symlink -> <目標>)` 或 `(hardlink -> <目標>)`，` / ` 之後接繁體中文的同一句。與 `--exclude` 相同，以此丟掉的連結不算 `--strict` 的略過。名稱不安全（`../x`）的連結仍以不安全路徑拒絕，仍然計數。不加此選項時，`-x` 會建立連結，包括指向目的地之外的連結；它只拒絕「穿過」連結寫入。`-t` 不受影響 |
| `-n <N>`    | 平行在途分塊數（預設每核一個，上限 4 × 核心數） |
| `-v`        | 於 stderr 逐一報出處理中的成員，並印出偵測到的 filter 鏈。**它不會產生長格式列表**——沒有大小、權限或時間戳記，而 `-t -v` 印出的名稱與 `-t` 相同，只多一行 filter 鏈。若你是帶著 `tar -tvf` 的表格預期而來，這不是那個東西。 |
| `-m`、`--touch` | （僅 `-x`）**不**還原封存中的 mtime；解出的檔案取得當下時間。`-m` 是 GNU tar 的寫法，此處作為完全等價的別名接受 |
| `-O`、`--to-stdout` | （僅 `-x`）將成員內容輸出至 stdout，完全不寫入檔案系統——此為 bsdtar／GNU tar 的寫法。與 `--cat` 不同：後者輸出的是 tar **串流本身**，而非其中的成員內容 |
| `-p`、`--same-permissions` | （僅 `-x`）原樣還原封存中的權限位元。**此處本來就是預設值，與 GNU tar 不同——在該處這只有 root 才是預設**，所以 `-p` 不改變任何行為，僅為相容而存在。真正會改變行為的是下一列 |
| `--no-same-permissions` | （僅 `-x`）對解出的 mode 套用行程 umask，那是 GNU tar 以非 root 身分解壓時的預設。與 `-p` 同時給定時由 `-p` 勝出，與 GNU tar 相同。**若你自 GNU tar 移植過來並依賴 umask 生效，需要的是這個旗標**——否則權限會原樣自封存還原，包含 group 與 world 可寫位元 |
| `-i`、`--ignore-zeros` | （`-x`、`-t`）越過封存結尾的零區塊繼續讀取，使串接的多個封存被當成一個讀入 |
| `-o`、`--no-same-owner` | 為與 `tar` 相容而接受，實際不做任何事：swift_tar 從不還原擁有者，加不加都一樣 |
| `--encrypt` | （僅 `-c`）以 ChaCha20-Poly1305 加密，並提示輸入密語 |
| `--keyfile <path>` | 以檔案位元組作為金鑰材料取代密語（建立與讀取皆適用；stdin 非終端機時為必要）。**建立時它本身即會開啟加密**——`-c --keyfile k.bin -f out.enc src/` 就會加密，不需要另外再加 `--encrypt`。 |
| `--force`   | （僅 `-x`）允許某成員覆蓋**同一次**解出中較早寫出的檔案；未加時該情形會被拒絕 |
| `-h`、`--dereference` | （`-c`、`-r`、`-u`）跟隨符號連結：存入它所指向的內容，而非連結本身。**`-h` 解析不了的連結會被回報並存成連結，絕不丟掉**——不論它是斷掉的、目標 `stat` 不到，或是指回當前路徑上已走過的目錄（迴圈，會被回報且不展開）。兩個經由不同路徑抵達同一目錄的連結**不是**迴圈，兩者都會被收錄。見〈`--dereference` 會收錄什麼〉一節。 |
| `--exclude <pattern>` | （`-c`、`-r`、`-u`）略過命中該 glob 的成員，可重複給定；亦接受 `--exclude=PATTERN`。比對規則與 bsdtar 相同，且是**實測而非臆測**得出：`*` 會跨越 `/`；不含 `/` 的樣式另外會逐一比對每個路徑元件；命中目錄的樣式會連整棵子樹一併排除。被排除的目錄**不會被走進去**，故它能繞開一個讀不到的子樹，而非僅僅把它從列表中略去。 |
| `--help`    | 顯示說明。**`-h` 不是說明**：它等同 `--dereference`，與 GNU tar 及 bsdtar 一致；說明是 `--help`，即 GNU tar 與 bsdtar 的寫法。 |
| `--version` | 顯示版本號、build id 與建置戳記（`swift_tar 0.1.1 (v0.1.1 / d3e2f887) 20261020-102103`） |
| `--crypto-selftest` | 執行密碼學單元測試（公開向量、標頭解析、分塊切分）後結束 |

`--zstd-level` 只有在同時指定 `--zstd` 時才生效。單獨給定時它會被接受，並寫出一個
未壓縮的純 tar，等級被丟棄。可用 `--identify` 檢查：以
`-c --zstd-level 9 -f out.tar dir` 產生的封存會回報 `tar`，而非 `zstd → tar`。
各離開碼的意義見[離開碼](#離開碼)一節。

### 兩種 tar 分歧之處，`--exclude` 跟隨 bsdtar

bsdtar 3.5.3 與 GNU tar 1.35 的 `--exclude` 實作並不相同，把命令列從一邊搬到另一邊之前
值得先知道。以 `src/` 內含 `keep.txt`、`skip.log`、`sub/deep.log` 為例：

| 樣式 | bsdtar | GNU tar | swift_tar |
| --- | --- | --- | --- |
| `sub`、`*.log`、`deep.log`、`*` | 一致 | 一致 | 相同 |
| `src/sub/*` | 連 `src/sub` 一併排除 | 保留 `src/sub` | **同 bsdtar** |
| `src/*` | 連 `src` 一併排除，封存為空 | 保留 `src` | **同 bsdtar** |

bsdtar 的目錄成員名帶結尾斜線，故以 `/*` 結尾的樣式，其 `*` 會匹配到空字串而連目錄本身
一併帶走；GNU 只比對目錄內的東西。

swift_tar 跟隨 bsdtar，因為本工具在其他各處的對照對象一向是它。`test/test_exclude.zsh`
把**兩半都當成斷言**——swift_tar 必須與 bsdtar 相同，*且* 必須與 GNU 不同——因此日後任
何一邊的行為改變都會被回報，而不是被默默吸收。

若要以兩種 tar 都一致的方式排除一個目錄，就別加結尾的 `/*`：`--exclude sub` 或
`--exclude src/sub`。

### `-h` 是 `--dereference`，不是說明

`-h` 等同 `--dereference`，與 GNU tar 及 bsdtar 一致；說明是 `--help`。
`swift_tar -c -h -f out.tar src/` 會寫出一個把每個符號連結都解析成目標的封存——體積更大，
存的是內容而非連結——並以 0 結束。

單獨執行 `swift_tar -h` 會明確失敗，因為 `-h` 本身並未指名任何操作。

### `--dereference` 會收錄什麼

不加時，符號連結被存成連結：零位元組加上它的目標字串。加上之後，連結被解析，存入的是
它所指向的內容。

```
src/link -> ../real          # real/ 裡有 inside.txt

-c -f a.tar src              # 預設
  drwxr-xr-x  src/
  lrwxr-xr-x  src/link -> ../real

-c -h -f b.tar src           # 跟隨
  drwxr-xr-x  src/
  drwxr-xr-x  src/link/
  -rw-r--r--  src/link/inside.txt
```

解壓端因而有兩個後果，且**都不需要任何旗標**：

- 對**每一個被跟隨的連結**，封存都不含其 symlink 項目，故解出的是純檔案與目錄。例外是
  `-h` **跟不上**的連結：它會存成連結，並在發生時於 stderr 回報。見下文。
- 「拒絕穿過封存中較早項目所植入的 symlink 寫入」那道守門照常作用，包括 `-h` 因跟不上而
  存下的連結。

**`-h` 跟不上的連結會存成連結，不會被丟掉。** 斷掉的連結，或目標 `stat` 不到的連結，會保留
自己的項目與目標字串，並在執行時說明：

```
swift_tar: './mmm': --dereference cannot follow it, storing the link itself
```

`-h` 唯一被允許失敗的是「解參照」——不是「把名稱留在封存裡」。`bsdtar` 有同樣的後援
（macOS、`bsdtar 3.5.3`）但不作聲；GNU tar 則丟掉該項目並以非零結束。

**迴圈屬於同一種情形。** 指回「當前路徑上已走過的目錄」的連結不會被展開——迴圈偵測正是為此
存在——但連結項目會保留，理由相同：迴圈背後的內容早已以其真實路徑存在封存裡，所以從頭到尾
有風險的只有連結的名稱與目標。

```
cyc/d/up -> ..

swift_tar -c -h   ./  ./d/  ./d/up -> ..     exit 0, "would loop here, storing the link itself"
bsdtar    -c -h   ./  ./d/  ./d/up          exit 0, silent
GNU tar   -c -h   2,200+ nested members     exit 2 — it does not detect this cycle at all
```

**仍刻意丟掉者，皆有實測理由：**

- **不經連結抵達、而識別碼已在堆疊上的目錄。** 於 Windows 以自我指涉的 junction 實測
  （`mklink /J d\up <root>`，tag `0xa0000003`）：NT 穿得過去，故迴圈檢查丟掉的成員是
  `./d/up/d`——一個真實目錄，不是連結。沒有東西可以取代它，而其內容早已存在 `./d/` 之下。
- **裝置節點與 socket**（`skipping special file`）：前者重建需要 root，後者無法由封存有意義
  地重建。GNU tar 與 bsdtar 也都略過這兩者。
- **列不出內容的目錄，其內容。** 該目錄自身的項目會寫出，接著回報列目錄失敗並繼續走訪，
  最後與 bsdtar 一樣以 1 結束：
  `swift_tar: ./mmm/: cannot read directory, contents left out: Permission denied`。
  bsdtar 的封存含有同樣的項目，而它也會回報。

代價是重複：多個指向同一目錄的連結會各自再存一份其內容，而指向樹外的連結會把該內容
拉進封存。

**在 Windows 上這對 WSL／MSYS 連結同樣有效。** WSL 下的 `ln -s`
留下的是 `IO_REPARSE_TAG_LX_SYMLINK` reparse point，而 **NT 完全不穿過這種連結**——`cmd`
會把它列成 `<JUNCTION> name [...]`、目標為空，對它執行 `type` 得到「The file cannot be
accessed by the system」。因此 `-h` 必須自行解析該連結、經由解析後的路徑讀取，同時仍把成員
存在連結自己的名稱之下。對 LX 連結 `dlink -> realdir`，封存內含
`./ ./dlink/ ./dlink/f.txt ./realdir/ ./realdir/f.txt`——與 GNU tar 存下的五個成員相同。真正斷掉的 LX 連結會被回報並存成連結本身，
與其他 `-h` 跟不上的連結相同；指回自身路徑的 LX 連結會被判定為迴圈。兩個參照實作如何處理同一批連結，見
[bugs/bsdtar-bug.md](bugs/bsdtar-bug.md)——兩者都不安全。

### `-f` 指向哪一邊

`-f` 指定封存檔，但該封存究竟是被讀取還是被寫入，由命令決定，而非由 `-f` 決定：

| 命令 | `-f` 是 |
|---|---|
| `-c`、`--rgb1-pack` | **輸出**——要寫出的檔案 |
| `-x`、`-t`、`--cat`、`--identify`、`--encrypt-only`、`--decrypt-only`、`--rgb1-info`、`--rgb1-raw` | **輸入**——要讀取的檔案 |
| `-r`、`-u`、`--delete` | **兩者**——就地修改 |

`--rgb1-pack` 特別容易誤用：它在上方表格中緊鄰 `--encrypt-only` 與
`--decrypt-only`，方向卻相反——那兩者是讀取 `-f` 並寫至 stdout，而 `--rgb1-pack`
是**寫入** `-f`。

`--version` 回報**來源資訊**（provenance）最後一次改變時的本機日期時間，例如
`swift_tar 20260712-143015`。相同值會以 `swift_tar_version` 儲存在封裝的
`version-<平台>.txt` 中，與該版本戳所描述的函式庫版本及連結方式並列。

**它不是編譯時間，也無法辨識執行檔。** 只要記錄下來的函式庫與連結方式沒變，改過原始碼再
建置也不會更動這個戳記，因此由不同原始碼建出的兩個執行檔可能回報同一個版本。不在 git
checkout 內時——QEMU guest 是刻意不含 `.git` 佈建的——沒有可比對的對象，每次建置都會產生
新的戳記。若需確認手上是哪一個執行檔，請取它的 `sha256`。

## 可重現的輸出

**swift_tar 的執行方式不會改變它寫出的位元組**——平行度不會，重跑也不會。真正會改變它們
的是 tar 所儲存的中繼資料，而**檔案的 mtime 正是其中之一**：

```sh
# 內容、檔名、權限皆相同，只有 mtime 不同
swift_tar -c -f a.tar -C a f.txt
swift_tar -c -f b.tar -C b f.txt
cmp a.tar b.tar     # -> 第 138 個位元組起不同
```

由於 tar 標頭會帶有每個檔案的 mtime，該時間戳本身即屬於輸入的一部分。
**`git clone`、解開 tarball、CI checkout 都會把 mtime 設為當次操作的時間**，因此兩台機器
即使打包內容完全相同的樹，仍會得到不同的封存。本工具沒有 `--mtime` 旗標，也不參考
`SOURCE_DATE_EPOCH`；若您需要跨機器比對 checksum，請先自行將時間戳正規化。

在時間戳固定的前提下，以下保證成立。以橫跨三個 4 MiB 分塊的 12 MB 語料實測：

| 項目 | 可重現？ |
|---|---|
| 純 tar 與所有串流 codec（`--zstd`、`--gzip`、`--xz`、`--bzip2`、`--lz4`）| **是**，跨執行成立 |
| 同上，跨 `-n 1`、`2`、`4`、`8`、`16` | **是**——平行度不會改變任何一個位元組 |
| `--encrypt` | **否，且是刻意如此**——每次執行使用新的 nonce；解密後的明文相同 |
| `--zip`、`--zip64` | **是**，跨執行成立——每個項目只記錄 mtime，不記錄讀取這棵樹本身就會改變的 atime 與 ctime |
| `--zip`、`--zip64`，換一個檔案系統或平台，使用同一個 `TZ` | **是**——macOS 與 Linux 逐位元組相同。成員的排序方式與 tar 路徑相同，一次處理一個目錄。ZIP 檔頭存的是本地時間，所以 `TZ` 必須相同 |
| 同上，加 `--zip-unsorted` | **否**——成員依檔案系統列出的順序寫出：同一棵樹在 macOS（APFS）與 Linux（tmpfs）得到不同的 ZIP，大小相同、順序不同。兩種方式的記憶體相同：1,008,901 個項目排序時最大 177 MB，不排序時 176 MB |
| `--zip`、`--zip64`，`-n 1`、`2`、`4`、`8`、`10`、`16` 之間 | **是**——成員由 `-n` 個執行緒壓縮、依序寫出，每個成員都是單一執行緒會壓出的那條 deflate 串流。M4 上的 claw-code（1.3 GB，5,448 個檔案）：`-n 1` 28.6 秒、`-n 4` 8.7 秒、`-n 10` 6.7 秒；最大記憶體分別為 9 MB、237 MB、280 MB（`verifications/zip_parallel_speed.zsh`）。Windows 的建置不論 `-n` 為何都只用一個執行緒壓縮 |

其中 `-n` 那一列才是真正有用的結論：分塊是決定性的，而不只是「碰巧以正確順序重組」，
因此在一台機器上以 `-n 16` 建立的封存，會與另一台機器上以 `-n 1` 建立的完全相同。加密
是刻意的例外——一個跨執行不會變化的加密封存，意味著 nonce 被重複使用。

## 離開碼

**請判斷「零或非零」，不要針對某個特定的非零值分支**——實際拿到哪個值並非穩定介面，
可能隨建置而變。

| 離開碼 | 意義 |
|---|---|
| `0` | 所要求的操作已完成 |
| 非零 | 未完成；原因輸出至 stderr |

**被截斷的封存屬於失敗，而非空封存。** 空檔案是合法的空封存並以 `0` 結束，與 `bsdtar`
一致；其餘無法被讀為封存的輸入一律以非零結束——包括在 gzip 標頭內就被切斷的 `.tar.gz`，
它與空封存一樣解出零位元組。故 `-t` 以 `0` 結束，確實代表該封存讀得出來。

**非零離開碼並不代表什麼都沒寫出。** 作業是串流進行而非先暫存後提交，因此失敗前已完成
的部分會留在磁碟上：

```sh
swift_tar -c -f mixed.tar tree/a.txt tree/typo.txt tree/sub/b.txt
# -> cannot stat 'tree/typo.txt'，離開碼 1
# -> mixed.tar 確實存在、是合法可讀的 tar，且「只」含 tree/a.txt。
#    tree/sub/b.txt 根本沒被處理到，就這樣無聲缺席。
```

失敗時的實測行為：

| 情況 | 留下什麼 |
|---|---|
| 建立時，壞路徑夾在好路徑之間 | 一個合法封存，內含壞路徑之前已處理的項目 |
| 建立時，壞路徑排在最前 | 該封存檔本身，內容為空（0 bytes） |
| 建立時（`-c`、`-r`、`-u`、`--zip`），有讀不到的目錄或檔案（權限不足） | 一個合法封存，內含其餘全部；每一項在遇到時回報，最後以非零結束，與 bsdtar 相同 |
| 解出時，封存在中途被截斷 | 已解出的那些項目，且內容完整；截斷點落在其中的那個成員完全不會被建立，故不會留下半寫的檔案 |
| 解出時，有成員被略過（路徑不安全、寫入或建立失敗……） | 其餘每個成員，內容完整；略過數與非零離開碼在最後才回報（見下方 `--strict`） |
| 尚未開始工作即被拒絕（未知選項、封存檔不存在、金鑰錯誤） | 無 |

`-f` 會在執行展開後開啟，因此**建立失敗會摧毀原本位於該路徑的封存**。實測：一個
365,568 bytes 的封存，以打錯的輸入路徑重新建立後變成 0 bytes，離開碼 1。例外是在選項
驗證階段就被攔下的失敗——該階段早於開啟 `-f`，故未知旗標不會動到原有封存。

**請把非零離開碼理解為「輸出狀態未定義」：刪掉重來。切勿理解為「輸出未被更動」。**
若原有封存必須在失敗時存活，請先寫到暫存路徑，待離開碼為 0 再移動到目標位置。

有兩種情形值得單獨列出，否則腳本必然寫錯：

- **`--identify` 即使無法辨識輸入也回傳 `0`。** 它會印出
  `<file>: unrecognized (not tar) / 無法辨識（非 tar）` 並視為成功，與 `file` 的精神
  一致。只有檔案讀不到才會失敗。故 `swift_tar --identify -f x && ...` **不代表**
  「x 是封存檔」——若您要判斷的是這件事，請比對印出的文字。
- **`-x` 搭配指向不存在目錄的 `-C` 會回傳 `0`** 並自動建立該目錄。詳見上方 `-C`
  對照表。
- **`-x` 略過成員時以非 0 結束（`--strict`，預設）。** 因路徑不安全（絕對路徑、
  `..`、穿過 symlink）而被拒絕的成員、寫不進去或建立不了的成員、此平台無法建立其型別的成員，都算
  略過；`--exclude` 排除的成員、`--no-links` 丟掉的連結不算，因為那是您要求的。其餘成員仍會全部解出——略過數在最後才回報。
  `--no-strict` 則在略過後仍以 `0` 結束。

## 檔案結構

```
swift_tar.swift    tar 寫入／讀取 + 壓縮引擎 + libarchive 式 filter
crypto.swift       ChaCha20-Poly1305 / scrypt 與加密容器
rgb1.swift         RGB1 原始影像容器
build.zsh           會偵測平台的進入點 → 下方對應的建置腳本
compile_tar.zsh     macOS 建置腳本 → release/swift_tar
compile_tar-linux.zsh  Linux 建置腳本 → release/swift_tar
platform.zsh        供 source：決定平台後綴的唯一來源
VERSION             下一個正式版要帶的版本號
build_id.zsh        供 source：決定 --version 所印 build id 的唯一來源
compile_tar-musl.zsh  在 Mac 上交叉建置靜態的 Linux 正式版（musl）→ release/linux-<arch>/swift_tar
release.zsh         把這個平台的公開版打包成 dist/ 裡的 .tar.zst
verify_release.zsh  在同架構的 Linux 機器上執行一份 Linux 正式版封存
publish.zsh         打 tag、發布四份封存、改寫 brew 與 scoop 的檔案
publish_rewrite.zsh 供 source：publish.zsh 改寫套件檔的部分
win_dlls.zsh        供 source：release.zsh 挑選 Windows 要附的 runtime DLL
Formula/swift_tar.rb  Homebrew formula（這個 repo 本身就是 tap）
version-mac.txt / version-win.txt / version-musl-<arch>.txt   各平台的建置版本戳與連結來源（glibc 開發建置的 version-linux.txt 不入版控）
licenses/           隨 Linux 與 Windows 封存出貨的第三方授權（見 licenses/README.md）
build_libarchive.zsh / build_libarchive-win.zsh  靜態 ZIP 後端建置
libarchive_zip_bridge.c  macOS/Windows 共用 ZIP C ABI
build_zlib-win.zsh  同步／重建 Windows 固定版本的 zlib 靜態相依套件
build_zstd-win.zsh  同步／重建 Windows 固定版本的 zstd 靜態相依套件
release/swift_tar  編譯後的二進位
lzfse2/            子模組 —— LZFSE 引擎（other3 / bvx3）
libarchive/        子模組 —— 實際使用的靜態 ZIP/ZIP64 後端
zlib/              子模組 —— Windows 固定版本的靜態 gzip backend
zstd/              子模組 —— Windows 固定版本的靜態 zstd backend
```

## 授權

swift_tar 採用 GNU General Public License v3.0
（`GPL-3.0-only`）授權。

Copyright (C) 2026 Ralic Lo <raliclo@gmail.com>

專案授權聲明見 [LICENSE](./LICENSE)。Bundled 或 linked components 保留各自授權：
壓縮引擎授權見 [lzfse2](./lzfse2)；zlib、zstd 與 libarchive 保留各自授權。
