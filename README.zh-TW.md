# swift_tar

以 Swift 撰寫的**多核心 `tar` 打包工具**，建構於 `lzfse2` 壓縮引擎之上，
並仿照 **libarchive** 的 filter 架構設計。

- **English: [README.md](./README.md)**

## 特色

- **ustar + pax** 容器：支援長路徑、大於 8 GiB 的檔案、符號連結、硬連結
  去重，可與 `bsdtar` / GNU `tar` 互通。
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

需要 Xcode 工具鏈（`swiftc`）與數個 Homebrew 函式庫：

```sh
brew install lz4 xz zstd      # liblz4 / liblzma / libzstd
git submodule update --init   # 取得 lzfse2 + libarchive + zlib
./compile_tar.sh              # → release/swift_tar
```

建置時將 `lzfse2/lzfse-cli.swift` 當函式庫重用（剝除其頂層 `runCLI()`
進入點後兩檔合併編譯），並連結 `-lz -lbz2 -llz4 -llzma -lzstd` 與內附的
靜態 libarchive ZIP 後端。
二進位輸出至 **`release/swift_tar`**。若缺少 `lzfse2` submodule，建置會以錯誤中止，
並提示執行 `git submodule update --init` 或改用下方不含 LZFSE 的建置。

### 不含 LZFSE 的公開版

`compile_no_lzfse.sh`（`compile_tar.sh --no-lzfse` 的包裝）建置「公開／可散布」版
binary，完全**不含**私有 LZFSE 引擎——不編譯 `lzfse-cli.swift`，因此既不能建立也
不能解碼任何 LZFSE 家族封存（`other3` / `bvx3` / `bvx2`），binary 內也無任何 LZFSE
程式碼或格式字串。標準外部 codec、純 tar 與 ZIP/ZIP64 不受影響。
此建置不需要 `lzfse2` submodule。

```sh
./compile_no_lzfse.sh         # → release/swift_tar（公開版、不含 LZFSE）
./test_no_lzfse.sh            # 驗證排除是否生效，且標準 codec 仍可用
```

### Windows

Windows 需要 Swift、CMake 與 Visual Studio 2022 C++ workload。建置腳本會把
固定版本的 zlib、zstd 與 libarchive submodule 編譯成 MSVC 靜態庫，再直接把
gzip、zstd 與 ZIP 支援連結進 `swift_tar.exe`；執行時不需要 `zlib.dll`、外部 `gzip.exe`，也不再每個
chunk 生一個 `zstd.exe`。

```bat
git submodule update --init
zsh ./build_zlib-win.sh
zsh ./build_zstd-win.sh
compile_tar-win.bat
```

`build_zlib-win.sh` 與 `build_zstd-win.sh` 是相依套件維護步驟：各自同步固定的
gitlink、重建靜態庫（`zs.lib`／`zstd_static.lib`），並將精確的 tag、commit 與
連結方式寫入 `version.txt`。首次 clone 或變更任一 submodule 後才需執行；平常的
`compile_tar-win.bat` 會增量重建 libarchive 後端並重用既有 zlib/zstd 靜態庫。
建置版本產生流程會在 `version.txt` 保留 `zlib_*`、`zstd_*` 與 `libarchive_*`
provenance 欄位，封裝步驟也會將
該檔案放入 Windows ZIP，供 release 驗證。

其餘外部 codec（bzip2、xz、lz4、lzip）仍需要對應的 Scoop CLI 工具；
`build_tool_install-win.sh` 可安裝完整工具鏈。

Windows ZIP 包含靜態連結的執行檔、Swift runtime DLL、`version.txt`、
`zlib-LICENSE.txt`、`zstd-LICENSE.txt` 與 `libarchive-COPYING.txt`。
`zs.lib`、`zstd_static.lib`、headers 與
CMake build tree 屬於開發產物，並非 runtime dependency，因此不放入 release。

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
release/swift_tar -c --zstd -f src.tar.zst -C /path/to parent-leaf
tar -cf - src/ | release/swift_tar -c --xz -f src.tar.xz -    # （或以管線灌入）
```

建立模式下，`-C <dir>` 會先切換輸入工作目錄，再封存後方列出的 leaf path，
語意與系統 tar 一致。相對 `-f` 路徑仍以原始呼叫目錄為基準建立。使用
`-C <parent> <leaf>` 可避免封存項目名稱包含 parent path 或 `..`。

輸出格式由 codec 旗標決定，不是由副檔名決定。例如
`--gzip -f archive.zip` 寫出的仍是 gzip 壓縮 tar stream（magic `1f 8b`），
不是真正的 ZIP container。建立真實 ZIP 請使用 `--zip`；libarchive 會在需要時
自動寫入 ZIP64，`--zip64` 則可強制寫入 ZIP64 記錄。

### 加密與解密

`--encrypt` 以 **ChaCha20-Poly1305** 加密封存。加密層位於壓縮引擎**之外**，
因此任何 codec——或純 tar——都能加密，解開時內層的 codec 仍會自動偵測。

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
`./test_encrypt.sh`。Windows/MSYS 可用 `verifications/encrypt_windows_correctness.sh`
針對 `release/swift_tar.exe` 重跑 self-test 與 CLI smoke suite；Windows MB/s
吞吐量則使用 `verifications/encrypt_mbps_win.sh`。

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
- `-u`（更新）：僅在成員比封存副本新（或不存在）時追加，不改寫也不刪除舊項目——
  解壓時取最後一份。
- `--delete`：重寫封存、去除指定成員（依名稱比對，目錄名可帶或不帶結尾 `/`）。
  這是 swift_tar 擴充功能——macOS 內建的 BSD tar 沒有 `--delete`。

### 解出／列出（格式自動偵測）

```sh
release/swift_tar -t -f src.tar.gz
release/swift_tar -t -f src.zip
release/swift_tar -x -f src.tar.bvx3 -C /tmp/out
release/swift_tar --cat -f package.rpm > payload.cpio          # 剝除 RPM 外包裝
```

### 辨識未知檔案

讀取從不看副檔名——codec 由 magic 位元組自動偵測。`--identify` 把這個偵測以類似
`file` 指令的形式回報、但不解壓任何內容，也可從 stdin 讀取：

```sh
release/swift_tar --identify -f mystery.bin     # 例如「mystery.bin: gzip → tar」
cat mystery.bin | release/swift_tar --identify  # 「<stdin>: gzip → tar」
```

一般讀取時，`-v` 會印出相同的偵測結果（`compression format: gzip`，未壓縮則印
`none`）。

## 壓縮引擎旗標（僅建立時）

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

## 讀取端 filter（自動偵測、可疊層）

uuencode（傳統與 base64）· 帶 RPM 外包裝的檔案 · gzip · bzip2 ·
compress/LZW（`.Z`）· lzma · lzip · xz · lz4 · zstandard · LZFSE 家族
（bvx2/bvx3，以多核心平行解碼器解開）· swift_tar 自有的加密層
（先解密，內層 codec 再照常偵測）。

`lzop` 可被偵測，但除非系統有 `liblzo2`，否則回報為不支援——與未編入 lzo
支援的 libarchive 行為一致。

## 選項

| 選項 | 意義 |
|------|------|
| `-f <path>` | 封存檔路徑（`-` 表標準輸入／輸出；預設 `-`） |
| `-C <dir>`  | 建立前切換輸入目錄；讀取時解出至此目錄 |
| `--strip-components <N>` | （僅 `-x` tar 解出）寫入前移除成員路徑前 N 層；也接受 `--strip-components=N` |
| `-n <N>`    | 平行在途分塊數（預設 2 × 核心數） |
| `-v`        | 詳細輸出（列出項目／顯示套用的 filter 鏈） |
| `--encrypt` | （僅 `-c`）以 ChaCha20-Poly1305 加密，並提示輸入密語 |
| `--keyfile <path>` | 以檔案位元組作為金鑰材料取代密語（建立與讀取皆適用；stdin 非終端機時為必要） |
| `-h`        | 顯示說明 |
| `--version` | 顯示固定的建置日期版本（`yyyyMMdd-HHmmss`） |
| `--crypto-selftest` | 執行密碼學單元測試（公開向量、標頭解析、分塊切分）後結束 |

`--version` 回報編譯 binary 時擷取的本機日期時間，例如
`swift_tar 20260712-143015`。相同值會以 `swift_tar_version` 儲存在封裝的
`version.txt` 中。

## 檔案結構

```
swift_tar.swift    tar 寫入／讀取 + 壓縮引擎 + libarchive 式 filter
crypto.swift       ChaCha20-Poly1305 / scrypt 與加密容器
rgb1.swift         RGB1 原始影像容器
compile_tar.sh     建置腳本 → release/swift_tar
build_libarchive.sh / build_libarchive-win.sh  靜態 ZIP 後端建置
libarchive_zip_bridge.c  macOS/Windows 共用 ZIP C ABI
build_zlib-win.sh  同步／重建 Windows 固定版本的 zlib 靜態相依套件
build_zstd-win.sh  同步／重建 Windows 固定版本的 zstd 靜態相依套件
release/swift_tar  編譯後的二進位
lzfse2/            子模組 —— LZFSE 引擎（other3 / bvx3）
libarchive/        子模組 —— 實際使用的靜態 ZIP/ZIP64 後端
zlib/              子模組 —— Windows 固定版本的靜態 gzip backend
zstd/              子模組 —— Windows 固定版本的靜態 zstd backend
```

## 授權

壓縮引擎授權見 [lzfse2](./lzfse2)；libarchive 與 zlib 保留各自授權。
