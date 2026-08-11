# 驗證工具與結果

- **English: [README.md](README.md)**

本目錄收錄 swift_tar 的臨時量測腳本，涵蓋主 benchmark pipeline
（`../../benchmark.sh`／`../../benchmark2.sh`）未測試的行為。這些結果屬於
探索性質；採信結論前，請先閱讀各節的「狀態」。

## 加密吞吐量、RSS 與大小開銷

`encrypt_mbps_rss.sh` 量測 ChaCha20-Poly1305 加密層的成本：同一封存在有無
`--encrypt` 下的對比、以 `--encrypt-only`／`--decrypt-only` 單獨作用的情形，
以及大小開銷。結果寫入
[`encrypt_mbps_rss_output.txt`](encrypt_mbps_rss_output.txt)。

```sh
ROUNDS=3 ./encrypt_mbps_rss.sh ../../claw-code
```

全程使用 keyfile 以維持非互動；`--keyfile` 不走 scrypt KDF，因此數字量的是
AEAD 本身，而非金鑰衍生。

Windows/MSYS 吞吐量使用 `encrypt_mbps_win.sh`，輸出寫入
[`encrypt_mbps_win_output.txt`](encrypt_mbps_win_output.txt)。此腳本只回報
MB/s；peak working set 仍由既有 Windows RSS 腳本負責。

```sh
ROUNDS=1 ./encrypt_mbps_win.sh ../../claw-code
```

2026-08-06 的 Windows 執行使用 MSYS_NT-10.0-26200 上的
`release/swift_tar.exe` 版本 `20260805-193735`，語料為 logical input 1.40 GB
的 `claw-code`。結果為 `--crypto-selftest` **44 PASS / 0 FAIL**，throughput
腳本的正確性檢查 **6 PASS / 0 FAIL**。完整 tree `diff -r` 可用
`VERIFY_TREE=1` 開啟，但預設關閉，因為它會主導 Windows wall time。

| Codec | 建立 | 建立 + 加密 | 解出 | 解出 + 解密 |
| --- | ---: | ---: | ---: | ---: |
| 純 tar | 178 MB/s | 147 MB/s | 99 MB/s | 81 MB/s |
| gzip | 166 MB/s | 146 MB/s | 94 MB/s | 94 MB/s |
| zstd | 198 MB/s | 181 MB/s | 106 MB/s | 97 MB/s |

`--encrypt-only` 為 **253 MB/s**，`--decrypt-only` 為 **269 MB/s**。解密輸出
已驗證與原封存位元組一致；錯誤金鑰與竄改密文皆被拒絕。

### Windows 正確性 smoke test

`encrypt_windows_correctness.sh` 保留一個可重用的 Windows/MSYS 正確性測試，
針對 release 執行檔執行，輸出寫入
[`encrypt_windows_correctness_output.txt`](encrypt_windows_correctness_output.txt)。

```sh
./encrypt_windows_correctness.sh
```

2026-08-06 的執行使用 MSYS_NT-10.0-26200 上的 `release/swift_tar.exe`
版本 `20260805-193735`。結果為 `--crypto-selftest` **44 PASS / 0 FAIL**，
CLI 子集 **6 PASS / 0 FAIL**：plain tar、gzip、zstd 的加密建立／解出往返、
`--encrypt-only`／`--decrypt-only` 位元組一致、錯誤金鑰拒絕與竄改拒絕。

### 發現並修正的 RSS 缺陷（2026-08-03）

首次執行暴露的是新加密層的真實缺陷，而非量測誤差：加密 1.3 GB 語料時
peak RSS 達 **1454 MB**，未加密的建立僅 20 MB。下方 TGZ 調查中的兩個典型成因
在 `crypto.swift` 裡都出現了：

- `decryptStream` 使用「累積後 `removeFirst`」的緩衝區模式，其底層儲存會被保留
  並長成整個串流的大小。現已改為每次只讀取所需的位元組，僅保留已嗅探的前綴。
- 加密與解密迴圈都未以 `autoreleasepool` 包住每個 chunk 的工作，導致
  Foundation `FileHandle` 讀取不斷堆積。

| 階段 | 無界 | 有界單執行緒 | 有界平行 |
| --- | ---: | ---: | ---: |
| 純 tar 建立 + 加密 | 1454 MB | 42 MB | **198 MB** |
| 解出 + 解密 | 1475 MB | 39 MB | **184 MB** |
| `--encrypt-only` | 1438 MB | 24 MB | **228 MB** |
| `--decrypt-only` | 1460 MB | 20 MB | **190 MB** |

平行管線依設計最多保留 `-n` 個 4 MiB chunk。每個 semaphore 額度只在結果按序
寫出後歸還，因此記憶體由設定的在途數量限制，而不會隨 1.4 GB 串流大小成長。

### 結果摘要（Apple M4、claw-code 1.40 GB、3 次中位數）

| Codec | 建立 | 建立 + 加密 | 解出 | 解出 + 解密 |
| --- | ---: | ---: | ---: | ---: |
| 純 tar | 550 MB/s | 299 MB/s | 570 MB/s | 426 MB/s |
| gzip | 322 MB/s | 277 MB/s | 474 MB/s | 411 MB/s |
| zstd | 1542 MB/s | 1231 MB/s | 396 MB/s | 460 MB/s |

`--encrypt-only` 為 **542 MB/s**、peak RSS 228 MB；`--decrypt-only` 為
**392 MB/s**、peak RSS 190 MB。解密輸出已驗證與原檔位元組一致。

大小開銷為 **48 bytes 標頭加上每 4 MiB chunk 21 bytes**——1.4 GB 封存為 7125
bytes（0.0005%）。

密語衍生直接使用同一份 `crypto.swift` 實測：每次 scrypt **0.180 秒**，
peak RSS 51.48 MB；keyfile baseline 則為 6.13 MB。

### 加密層的 `-n` 擴展

每個 chunk 各自獨立封裝——其 nonce 與 AAD 僅由 chunk 索引決定——因此本層使用
與 codec 相同的保序併發管線與同一組 `-n` 預算。**容器格式並未改變**，此變更
前後寫出的封存可互相讀取。

| `-n` | 加密 | RSS | 解密 | RSS |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 132 MB/s | 28 MB | 133 MB/s | 28 MB |
| 2 | 262 MB/s | 45 MB | 260 MB/s | 41 MB |
| 4 | 479 MB/s | 79 MB | 479 MB/s | 58 MB |
| 8 | 662 MB/s | 147 MB | 656 MB/s | 92 MB |
| 16 | **763 MB/s** | 206 MB | **742 MB/s** | 135 MB |
| 20（預設） | 754 MB/s | 232 MB | 738 MB/s | 152 MB |

在這台 10 核機器上，吞吐量可順利擴展至約 `-n 16`——相較 `-n 1` 為 **5.8 倍**
——而預設值（`2 × 核心數` = 20）正位於平原區，無需另行調整。RSS 隨在途 chunk
數（每個約 4 MiB）線性成長，與 codec 的取捨相同。

> **方法論**：此 sweep 採交錯執行——每一輪跑完整個 sweep，並回報各設定的最佳
> 時間。若把某個 `-n` 的所有輪次跑完才換下一個，CPU 會單調升溫；本腳本早期版本
> 正是如此，並回報高 `-n` 大幅崩跌（`-n 20` 僅 146 MB/s），而反序執行證明那
> 純粹是溫度造成的。各階段現在一完成即刪除自己的封存，且空間不足時腳本會拒絕
> 開始。

> **狀態**：macOS 吞吐量／RSS 數字已於 Apple M4 驗證。Windows throughput
> MB/s 另由 `encrypt_mbps_win.sh` 驗證；Windows peak working set 則由既有
> Windows RSS 腳本覆蓋。正確性是強制檢查而非假設——macOS sweep 在任一 `-n`
> 設定無法還原為相同位元組時即中止，且 `--crypto-selftest` 會對四種 payload
> 形狀檢查全部 16 種加密／解密 `-n` 組合。

## RGB1 容器各 codec 吞吐量

`../test_swift_tar_rgb1.sh` 將 RGB1 容器經由 swift_tar 各 codec 封存，記錄封存
大小、壓縮比、建立／解出耗時與 MB/s 至
[`rgb1_container_mbps_output.txt`](rgb1_container_mbps_output.txt)，並附上執行
日期與建置版本。

> **狀態**：語料為合成的 1024×1024 RGB1 影像（3 MiB payload），由重複的
> 4 KiB 區塊組成，因此本質上高度可壓縮。壓縮比**不能**代表真實照片的表現——
> 此表僅供判讀吞吐量與各 codec 的相對成本。

```sh
../test_swift_tar_rgb1.sh
```

## claw-code ZIP 吞吐量與 RSS

`zip_claw_code_mbps_rss.sh` 以完整 `claw-code` 語料執行真實 ZIP encode 與
decode，逐輪回報十進位 logical-input MB/s 與程序 peak RSS，並比較第一輪解壓目錄和
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

## 解壓：時間花在哪裡，以及 `-n` 到底有沒有作用（2026-08-11）

`verifications/extract_write_path.zsh` → `extract_write_path_output.txt`

macOS 27.0.0 arm64、10 核（4P+6E）、APFS，每組語料 256 MiB，
swift_tar 20260810-170353 對 bsdtar 3.5.3。三次獨立執行，下列比值分別重現為
1.7/1.9/1.7、1.1/0.9/1.1、0.6/0.6/0.6。

### 1. 解壓成本在「每個檔案」，而 swift_tar 在小檔上勝出

固定總位元組，只改變檔案數：

| 語料 | 檔案數 | 平均大小 | bsdtar -c | bsdtar -x | swift -c | swift -x | 比值 |
|---|---|---|---|---|---|---|---|
| few  | 8    | 32 MiB  | 2142ms | 121ms  | **404ms** | 234ms  | 慢 1.9 倍 |
| mid  | 512  | 512 KiB | 2308ms | 288ms  | **401ms** | 309ms  | 1.1 倍 |
| many | 8192 | 32 KiB  | 4540ms | 2456ms | **459ms** | **1545ms** | **0.6 倍——更快** |

這張表帶出兩件事：

- **建立封存在每一組語料都比 bsdtar 快 4–10 倍。** 分塊平行 gzip 確實在做事。
- **檔案越小，swift_tar 的相對表現越好。** 它輸在少量巨檔，贏在數千個小檔。

第二點**推翻了寫這支腳本的原始假設**（Foundation 的每檔開銷）。此處反而是
bsdtar 的每檔成本佔主導：8192 個檔要 2456ms，swift_tar 只要 1545ms。

**實務結論：誰比較快完全取決於封存的形狀。** Swift toolchain 那種「少量大檔」
的封存，bsdtar 勝；原始碼樹或 rootfs 這種形狀，swift_tar 勝。

### 2. 小檔情境下，寫檔路徑佔解壓時間約九成

`-t` 解開整個封存但不寫檔；`-x` 解開並寫檔。

| 語料 | 檔案數 | swift -t | swift -x | 寫檔路徑 | bsdtar -t | bsdtar -x | 寫檔路徑 |
|---|---|---|---|---|---|---|---|
| few  | 8    | 120ms | 207ms  | 87ms   | 32ms  | 265ms  | 233ms  |
| many | 8192 | 214ms | 1644ms | 1430ms | 226ms | 2929ms | 2703ms |

解碼 256 MiB 約 200ms，兩個工具幾乎相同。其餘全部是檔案 I/O。

### 3. 解壓是單執行緒，`-n` 對它毫無作用

| 操作 | wall | user | sys | CPU/wall |
|---|---|---|---|---|
| swift -x（預設 -n） | 1650ms | 280ms | 1390ms | **1.01** |
| swift -x -n 1 | 1560ms | 270ms | 1310ms | **1.01** |
| swift -x -n 8 | 1540ms | 270ms | 1300ms | **1.02** |
| swift -t（僅解碼） | 210ms | 170ms | 40ms | 1.00 |
| bsdtar -x | 2450ms | 240ms | 2190ms | 0.99 |

CPU/wall 為 1.0 代表只用了一個核心，三次皆然。**`-n` 在解壓路徑上什麼都沒改變**
——1650 / 1560 / 1540ms 是執行間的雜訊，不是 scaling。

這與原始碼一致：把小檔寫入跨執行緒批次化的 `FileWriterPool` 位於
`#if os(Windows)` 之內（`swift_tar.swift:2432`）。macOS 與 Linux 走 `#else`
分支，是一條 `createFile` → `FileHandle` → `write` → `close` 的序列迴圈。

另外注意 `sys` 遠大於 `user`（1390 對 280ms）：解壓是 **syscall-bound 而非
CPU-bound**。對一個在等檔案系統的工作增加運算執行緒沒有幫助。

### 在 macOS/Linux 實作平行寫檔值得嗎？

依上述數字，誠實的答案是：**它會改善「已經在贏」的情境，而非「正在輸」的情境。**

- **大量小檔** —— 寫檔路徑佔 1644ms 中的 1430ms，且是 syscall-bound，跨核心
  重疊確實有空間。但 swift_tar 在此已經比 bsdtar 快 1.6 倍。這是擴大領先，
  不是修補缺陷。
- **少量大檔** —— 寫檔路徑只佔 207ms 中的 87ms，而且是少數幾次大型循序寫入，
  沒有東西可以平行化。而這正是 swift_tar 落後的情境（1.9 倍）。
  **平行寫檔補不上這個差距。**

所以大檔的差距在別的地方——在餵給寫入端的讀取／解碼管線，而非寫入本身。
`few` 語料的 `-t` 是 120ms 對 bsdtar 的 32ms，那 1.9 倍就是從這裡來的，
要修也得從這裡開始。

**壓縮**則不存在這個問題：建立封存在所有測試語料上都已比 bsdtar 快 4–10 倍。

### 4. `--gzip` 確實每 4 MiB 一個成員——而 `gzip -l` 看不到

| 封存 | 成員數 | 每成員解壓後大小 |
|---|---|---|
| bsdtar `-czf` | 1 | 268,520,960 |
| swift_tar `--gzip` | 65 | min 17,920 / **max 4,194,304** |

4,194,304 正好是 4 MiB，pigz 式分塊如文件所述正常運作。

**`gzip -l` 無法驗證這件事，也不該拿來驗證。** 它只讀第一個成員的 header
與檔案最後 4 bytes 的 ISIZE，因此無論幾個成員，輸出永遠是兩行——單成員與
65 成員的封存看起來完全一樣。必須逐成員走訪整個串流（本腳本以
`zlib.decompressobj` 搭配 `unused_data` 完成）。

順帶一提的推論：基於同樣的原因，`gzip -l` 對任何多成員封存回報的解壓後大小
都是錯的。
