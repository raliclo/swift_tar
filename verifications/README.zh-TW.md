# 驗證工具與結果

- **English: [README.md](README.md)**

本目錄收錄 swift_tar 的臨時量測腳本，涵蓋主 benchmark pipeline
（`../../benchmark.sh`／`../../benchmark2.sh`）未測試的行為。這些結果屬於
探索性質；採信結論前，請先閱讀各節的「狀態」。

## claw-code ZIP 吞吐量與 RSS

`zip_claw_code_mbps_rss.sh` 以完整 `claw-code` 語料執行真實 ZIP encode 與
decode，逐輪回報 logical-input MiB/s 與程序 peak RSS，並比較第一輪解壓目錄和
來源。預設執行三輪，結果寫入 `zip_claw_code_mbps_rss_output.txt`。

```sh
ROUNDS=3 ./zip_claw_code_mbps_rss.sh ../../claw-code
```

## 建立端 `-C` 相容性（2026-07-18）

`swift_tar -c` 過去雖會解析 `-C`，卻只在解出流程使用，因此系統 tar 常見的
`swift_tar -c --zstd -f out.tar.zst -C <parent> <leaf>` 會錯誤地從原始呼叫
目錄尋找 `<leaf>`。修正後會先開啟封存輸出，再切換輸入工作目錄，結束時還原
原目錄；因此相對 `-f` 仍建立在呼叫目錄，entry name 也不會帶入 parent path
或 `..`。

Windows build `swift_tar 20260718-171714` 已完成以下驗證：

- `swift_tar -test -debug` 七項全數通過，涵蓋 plain／gzip 系統 tar 互通、
  native ZSTD 建立端 `-C`，以及兩種 Windows 解出寫入後端。
- 隔離的 `-C ../source leaf` native-ZSTD round-trip：archive 留在 invocation
  directory；entry 僅有 `leaf/` 與 `leaf/README.md`；外部 `zstd` 加 Windows
  系統 tar 列出相同項目；解出內容逐 byte 相同。
- 將 root Windows helper pipeline 複製到隔離目錄，以 `n=2` 跑 file／nul
  兩種模式；八種格式在兩種模式皆通過，ZSTD file 解出樹與 TGZ 相同，原始
  ZSTD log 也記錄 `native libzstd via swift_tar`。
- `release/swift_tar_win.zip` 內的執行檔回報 `20260718-171714`、self-test
  通過，並保留 static zlib 1.3.2 與 zstd 1.5.7 provenance。

## tgz_inflight_rss.sh

**問題**：swift_tar 的 `-n` 旗標（chunk-parallel gzip 的在途 chunk 並行數）
是否控制 TGZ encode／decode 的 peak RSS？`zshrc.sh` 的 `getar()` 沒有傳入
`-n`，因此 TGZ benchmark 使用預設值 `inflight = cores*2`（R45-Mac 測試機
為 10 核心，因此預設是 20）。提出此問題的背景是 TGZ 在
`OPTIMIZATION.md` 中曾是 peak RSS 最高的格式：1.3GB 語料約使用
2.5–3.3GB，其他 LZFSE 格式則只需要數百 MB。

**使用方式**：

```sh
swift_tar/verifications/tgz_inflight_rss.sh <path-to-corpus>
```

**原始輸出**：[`tgz_inflight_rss_output.txt`](tgz_inflight_rss_output.txt)。
腳本每次執行都會用最新 stdout 覆寫此檔案。測試使用 R45-Mac 機器上的真實
`claw-code` 語料（約 1.3GB）。

### 找到並修正第一個根因（2026-07-12）

修正前 encode（約 2.1–2.6GB）與 decode（約 2.5–3.0GB）的 peak RSS 都
接近語料大小，且不受 `-n` 影響。這是 Foundation `FileHandle.read` 在 CLI
緊密迴圈中累積 autorelease 物件的典型特徵。`lzfse-cli.swift` 的讀取迴圈
本來就包在 `autoreleasepool` 中，`swift_tar.swift` 當時則完全沒有使用。

修正方式是將熱讀寫迴圈包入 `autoreleasepool`，包括 `TarWriter.add` 讀檔
迴圈、`ParallelChunkSink.dispatch` worker、`gzipDecodeStream`、
`TarReader.readExactly`、解出寫檔迴圈與尾端 drain 迴圈。該階段以
`swift_tar -test -debug`（當時 4/4）、完整 `claw-code` round-trip
（`diff -rq` 無差異）及系統 tar 可讀性完成驗證。

### 找到並修正第二個根因（2026-07-12，phase 2）

完成 phase 1 後，RSS 仍接近整份語料大小（約 1.3GB）。在 encode 執行中以
`heap` 分析，發現單筆約 1.06GB 的 malloc 節點，來源是 `Data` 的 append +
`removeFirst` 模式：`removeFirst` 保留 backing store，而 `append` 持續延長
同一儲存區，最終讓單一 buffer 成長到整條 tar stream 的大小。共有兩處：

- `ParallelChunkSink.buffer`（encode）：改為將 staging `Data` 填滿至
  `chunkSize` 後，把完整物件交給 worker，下一個 chunk 使用全新 buffer。
- `TarReader.pending`（decode）：改用明確的已消耗 offset，並以 `subdata`
  壓實，使 backing store 維持有界。

### macOS 結果摘要

> **狀態**：僅在 R45-Mac 測試機完成驗證。Windows 的平台特定結果請參考
> 下一節。

| 方向 | 修正前 | Phase 1（`autoreleasepool`） | Phase 2（buffer 模式） |
| --- | --- | --- | --- |
| Encode | 約 2.1–2.6GB，打平 | 約 1.0–1.4GB，打平 | **90MB（`n=4`）→ 300MB（`n=40`）；預設 `n=20` = 219MB** |
| Decode | 約 2.5–3.0GB | 約 1.2–1.4GB，打平 | **約 50MB，不受 `-n` 影響** |

各階段均未產生時間退步：encode 維持 4.3–7.6 秒，decode 維持 2.8–3.9 秒。
encode RSS 現在才顯示真正的 `-n` 線性關係（在途 chunk 數 × 每個 chunk
約 8MiB）；先前此關係被記憶體累積問題掩蓋。

### Windows 驗證：已重現改善

**原始輸出**：
[`tgz_inflight_rss_win_output.txt`](tgz_inflight_rss_win_output.txt)

Windows RSS 修正最初是在 gzip 仍透過外部 CLI 程序執行時完成。每個 chunk
的 Foundation `Thread` writer 改為專用 `DispatchQueue` pipe pump，並改用
同步 `readData(ofLength:)`，限制每輪 `Data` 的生命週期。後續 native-zlib
修改讓 gzip 不再經過 process backend；pipe 修正則繼續供其他外部 codec
使用。

同一份 `claw-code` 語料的完整 `-n 4..40` 掃描，確認整個範圍都維持有界
記憶體：

| `-n` | Encode peak WS | Decode peak WS |
| --- | ---: | ---: |
| 4 | 55.6MB | 45.0MB |
| 8 | 75.5MB | 42.9MB |
| 12 | 93.1MB | 44.4MB |
| 16 | 113.9MB | 44.4MB |
| 20 | 139.8MB | 43.0MB |
| 24 | 150.7MB | 42.6MB |
| 28 | 161.0MB | 43.3MB |
| 32 | 176.7MB | 44.7MB |
| 36 | 195.8MB | 44.0MB |
| 40 | 208.0MB | 44.1MB |

Windows 特定修正前，encode 使用 2.5–2.7GB、decode 使用 2.50–2.55GB。
修正後 encode 呈現預期的線性 `-n` 關係，decode 則穩定維持約 43–45MB。

Native zlib 解決了另一條 encode 速度軸線。Windows build 現在靜態連結固定
版本的 zlib 1.3.2 submodule，不再為每個 chunk 啟動一次外部 `gzip.exe`。
完整掃描中 encode 從 27–47 秒降至 7.2–15.6 秒；正常平行平台區
（`-n 12..40`）為 7.2–7.8 秒，已接近 macOS 的 4.3–7.6 秒。Decode 從
17–19 秒改善至 9.7–11.0 秒，但仍慢於 macOS 的 2.8–3.9 秒，因此 Windows
解出與檔案 I/O 成本仍是另一個最佳化目標。

### 副檔名相容性

將 gzip 輸出改名為 `.zip` 不會轉換成 ZIP container。Windows 實測
`swift_tar -c -z -f archive.zip` 產生 gzip magic `1f 8b`；`unzip -t` 以
`short read` 失敗，但 Windows 系統 `tar -tf` 與 `swift_tar -x` 均成功。
此格式應使用 `.tgz` 或 `.tar.gz` 副檔名。

### 實務結論

- 在 macOS 上，TGZ 的記憶體用量已與 LZFSE 格式相當或更低。預設 `-n`
  不需調整；需要時仍可降低 `-n`，以 encode 速度換取更低記憶體
  （`n=4` = 90MB，時間增加 75%）。
- 在 Windows 上，native zlib 將 TGZ encode RSS 維持在 56–208MB
  （`-n 4–40`，線性），decode RSS 約 43–45MB，且不受 `-n` 影響。
- 靜態 zlib 消除每個 chunk 啟動 `gzip.exe` 的成本：平行 encode 現為
  7.2–7.8 秒；decode 改善至 9.7–11.0 秒，仍是 Windows 特定的最佳化目標。
- 目前的 `swift_tar -test -debug` 七項檢查全數通過，包含建立端 `-C`、
  native ZSTD、兩種 Windows 寫入後端與系統 tar 雙向互通。
