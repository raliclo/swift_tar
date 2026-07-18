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
進入點後兩檔合併編譯），並連結 `-lz -lbz2 -llz4 -llzma -lzstd`。
二進位輸出至 **`release/swift_tar`**。

### Windows

Windows 需要 Swift、CMake 與 Visual Studio 2022 C++ workload。建置腳本會把
固定版本的 zlib 與 zstd submodule 各編譯成 MSVC 靜態庫，再直接把 gzip 與 zstd
連結進 `swift_tar.exe`；執行時不需要 `zlib.dll`、外部 `gzip.exe`，也不再每個
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
`compile_tar-win.bat` 會重用既有靜態庫，不會再次呼叫 CMake。建置版本產生流程會
在 `version.txt` 保留 `zlib_*` 與 `zstd_*` provenance 欄位，封裝步驟也會將
該檔案放入 Windows ZIP，供 release 驗證。

其餘外部 codec（bzip2、xz、lz4、lzip）仍需要對應的 Scoop CLI 工具；
`build_tool_install-win.sh` 可安裝完整工具鏈。

Windows ZIP 包含靜態連結的執行檔、Swift runtime DLL、`version.txt`、
`zlib-LICENSE.txt` 與 `zstd-LICENSE.txt`。`zs.lib`、`zstd_static.lib`、headers 與
CMake build tree 屬於開發產物，並非 runtime dependency，因此不放入 release。

## 使用方式

```
swift_tar -c|-x|-t|--cat [-f <archive>] [codec] [-C <dir>] [-n N] [-v] [files...]
```

| 指令 | 意義 |
|------|------|
| `-c`    | 建立封存檔 |
| `-x`    | 解出封存檔 |
| `-t`    | 列出封存內容 |
| `--cat` | 僅解壓 filter 鏈、原始內容輸出至 stdout（等同 `bsdcat`） |

`-f -`（或省略 `-f`）表示讀取標準輸入／寫至標準輸出，可組進管線。

### 建立範例

```sh
release/swift_tar -c --bvx3-optimal -f src.tar.bvx3 src/
release/swift_tar -c --gzip         -f src.tar.gz    src/     # 標準 .tar.gz
release/swift_tar -c --zstd -f src.tar.zst -C /path/to parent-leaf
tar -cf - src/ | release/swift_tar -c --xz -f src.tar.xz -    # （或以管線灌入）
```

建立模式下，`-C <dir>` 會先切換輸入工作目錄，再封存後方列出的 leaf path，
語意與系統 tar 一致。相對 `-f` 路徑仍以原始呼叫目錄為基準建立。使用
`-C <parent> <leaf>` 可避免封存項目名稱包含 parent path 或 `..`。

輸出格式由 codec 旗標決定，不是由副檔名決定。例如
`--gzip -f archive.zip` 寫出的仍是 gzip 壓縮 tar stream（magic `1f 8b`），
不是真正的 ZIP container，因此 `unzip` 無法解開。gzip 封存檔應命名為
`.tgz` 或 `.tar.gz`，並使用 `tar` 或 `swift_tar` 解壓。目前尚未支援建立真正的
`.zip` 封存檔。

### 解出／列出（格式自動偵測）

```sh
release/swift_tar -t -f src.tar.gz
release/swift_tar -x -f src.tar.bvx3 -C /tmp/out
release/swift_tar --cat -f package.rpm > payload.cpio          # 剝除 RPM 外包裝
```

## 壓縮引擎旗標（僅建立時）

讀取一律自動偵測，故引擎旗標只作用於 `-c`。

| 旗標 | 等同 | 說明 |
|------|------|------|
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

所有標準引擎輸出皆為可串接串流，故 `gunzip`、`bunzip2`、`xz`、`lzip`、
`zstd`、`lz4` 與 `bsdtar` 可直接解開 swift_tar 的輸出。

## 讀取端 filter（自動偵測、可疊層）

uuencode（傳統與 base64）· 帶 RPM 外包裝的檔案 · gzip · bzip2 ·
compress/LZW（`.Z`）· lzma · lzip · xz · lz4 · zstandard · LZFSE 家族
（bvx2/bvx3，以多核心平行解碼器解開）。

`lzop` 可被偵測，但除非系統有 `liblzo2`，否則回報為不支援——與未編入 lzo
支援的 libarchive 行為一致。

## 選項

| 選項 | 意義 |
|------|------|
| `-f <path>` | 封存檔路徑（`-` 表標準輸入／輸出；預設 `-`） |
| `-C <dir>`  | 建立前切換輸入目錄；讀取時解出至此目錄 |
| `-n <N>`    | 平行在途分塊數（預設 2 × 核心數） |
| `-v`        | 詳細輸出（列出項目／顯示套用的 filter 鏈） |
| `-h`        | 顯示說明 |
| `--version` | 顯示固定的建置日期版本（`yyyyMMdd-HHmmss`） |

`--version` 回報編譯 binary 時擷取的本機日期時間，例如
`swift_tar 20260712-143015`。相同值會以 `swift_tar_version` 儲存在封裝的
`version.txt` 中。

## 檔案結構

```
swift_tar.swift    tar 寫入／讀取 + 壓縮引擎 + libarchive 式 filter
compile_tar.sh     建置腳本 → release/swift_tar
build_zlib-win.sh  同步／重建 Windows 固定版本的 zlib 靜態相依套件
build_zstd-win.sh  同步／重建 Windows 固定版本的 zstd 靜態相依套件
release/swift_tar  編譯後的二進位
lzfse2/            子模組 —— LZFSE 引擎（other3 / bvx3）
libarchive/        子模組 —— filter 模型的 C 參考實作
zlib/              子模組 —— Windows 固定版本的靜態 gzip backend
zstd/              子模組 —— Windows 固定版本的靜態 zstd backend
```

## 授權

壓縮引擎授權見 [lzfse2](./lzfse2)；libarchive 與 zlib 保留各自授權。
