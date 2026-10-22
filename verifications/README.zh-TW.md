# 驗證工具與結果

- **English: [README.md](README.md)**

本目錄收錄 swift_tar 的臨時量測腳本，涵蓋主 benchmark pipeline
（`../../benchmark.zsh`／`../../benchmark2.zsh`）未測試的行為。這些結果屬於
探索性質；採信結論前，請先閱讀各節的「狀態」。

## 加密吞吐量、RSS 與大小開銷

`encrypt_mbps_rss.zsh` 量測 ChaCha20-Poly1305 加密層的成本：同一封存在有無
`--encrypt` 下的對比、以 `--encrypt-only`／`--decrypt-only` 單獨作用的情形，
以及大小開銷。結果寫入
[`encrypt_mbps_rss_output.txt`](encrypt_mbps_rss_output.txt)。

```sh
ROUNDS=3 ./encrypt_mbps_rss.zsh ../../claw-code
```

全程使用 keyfile 以維持非互動；`--keyfile` 不走 scrypt KDF，因此數字量的是
AEAD 本身，而非金鑰衍生。

Windows/MSYS 吞吐量使用 `encrypt_mbps_win.zsh`，輸出寫入
[`encrypt_mbps_win_output.txt`](encrypt_mbps_win_output.txt)。此腳本只回報
MB/s；peak working set 仍由既有 Windows RSS 腳本負責。

```sh
ROUNDS=1 ./encrypt_mbps_win.zsh ../../claw-code
```

已記錄的 Windows 執行日期為 2026-08-18，使用 MINGW64_NT-10.0-26200 上的
`release/swift_tar.exe` 版本 `20260818-074043`，語料為 logical input 1.40 GB
的 `claw-code`。結果為 `--crypto-selftest` **44 PASS / 0 FAIL**，throughput
腳本的正確性檢查亦全數通過。完整 tree `diff -r` 可用 `VERIFY_TREE=1` 開啟，
但預設關閉，因為它會主導 Windows wall time——另注意此處 `rounds` 為 **1**，
不像 macOS 是 3 次中位數。

下表每一格皆取自 [`encrypt_mbps_win_output.txt`](encrypt_mbps_win_output.txt)
的 A、B 兩節。**請勿手動編輯**；每次執行後以該檔比對。

| Codec | 建立 | 建立 + 加密 | 解出 | 解出 + 解密 |
| --- | ---: | ---: | ---: | ---: |
| 純 tar | 457 MB/s | 249 MB/s | 75 MB/s | 61 MB/s |
| gzip | 217 MB/s | 184 MB/s | 64 MB/s | 50 MB/s |
| zstd | 235 MB/s | 213 MB/s | 71 MB/s | 56 MB/s |

`--encrypt-only` 為 **263 MB/s**，`--decrypt-only` 為 **289 MB/s**。解密輸出
已驗證與原封存位元組一致；錯誤金鑰與竄改密文皆被拒絕。

### Windows 正確性 smoke test

`encrypt_windows_correctness.zsh` 保留一個可重用的 Windows/MSYS 正確性測試，
針對 release 執行檔執行，輸出寫入
[`encrypt_windows_correctness_output.txt`](encrypt_windows_correctness_output.txt)。

```sh
./encrypt_windows_correctness.zsh
```

已記錄的執行使用 MINGW64_NT-10.0-26200 上的 `release/swift_tar.exe`
版本 `20260816-045456`。結果為 `--crypto-selftest` **44 PASS / 0 FAIL**，
CLI 子集 **6 PASS / 0 FAIL**：plain tar、gzip、zstd 的加密建立／解出往返、
`--encrypt-only`／`--decrypt-only` 位元組一致、錯誤金鑰拒絕與竄改拒絕。

### 加密層的記憶體上限

`decryptStream` 每次只讀取所需的位元組，僅保留已嗅探的前綴；加密與解密迴圈都以
`autoreleasepool` 包住每個 chunk 的工作，因此兩者都不會隨串流成長（與下方 TGZ 一節
是同樣兩個模式）。

平行管線依設計最多保留 `-n` 個 4 MiB chunk。每個 semaphore 額度只在結果按序
寫出後歸還，因此記憶體由設定的在途數量限制，而不會隨 1.4 GB 串流大小成長。

### 結果摘要（Apple M4、claw-code 1.41 GB、3 次中位數）

下表每一格皆取自 [`encrypt_mbps_rss_output.txt`](encrypt_mbps_rss_output.txt)
的 A、B 兩節——日期 2026-10-22、build
`swift_tar 0.1.2 (v0.1.1-17-gd493560e-dirty) 20261022-191859`。**請勿手動編輯**；
每次執行後以該檔比對。

| Codec | 建立 | 建立 + 加密 | 解出 | 解出 + 解密 |
| --- | ---: | ---: | ---: | ---: |
| 純 tar | 686 MB/s | 415 MB/s | 703 MB/s | 370 MB/s |
| gzip | 331 MB/s | 277 MB/s | 427 MB/s | 372 MB/s |
| zstd | 537 MB/s | 473 MB/s | 879 MB/s | 636 MB/s |

`--encrypt-only` 為 **401 MB/s**、peak RSS 181 MB；`--decrypt-only` 為
**347 MB/s**、peak RSS 109 MB。解密輸出已驗證與原檔位元組一致。

**A、B 兩節受限於磁碟寫入，而非程式碼。** 它們把每個封存與解出的目錄樹都寫到內建
磁碟上的暫存目錄，而這台機器的內建磁碟已用 91%（剩 18 GiB）。兩個建置（0.1.1 與
0.1.2）寫到同一目錄時同樣不穩定，同一步驟介於 0.86–2.11 秒；下方各設定取最佳一輪的
`-n` sweep 則不受影響。純 tar 與 `--encrypt-only`／`--decrypt-only` 的數字應讀作
這顆磁碟的寫入速率。

大小開銷為 **48 bytes 標頭加上每 4 MiB chunk 21 bytes**——1.4 GB 封存為 7167
bytes（0.0005%）。

密語衍生直接使用同一份 `crypto.swift` 實測：每次 scrypt **0.180 秒**，
peak RSS 51.31 MB；keyfile baseline 則為 6.03 MB。

### 加密層的 `-n` 擴展

每個 chunk 各自獨立封裝——其 nonce 與 AAD 僅由 chunk 索引決定——因此本層使用
與 codec 相同的保序併發管線與同一組 `-n` 預算。**容器格式與 `-n` 無關**，以某個
`-n` 加密的封存可用任何其他 `-n` 解密。

下表取自 [`encrypt_mbps_rss_output.txt`](encrypt_mbps_rss_output.txt) 的 B2 節，
與上方各表同一次執行。**請勿手動編輯。**

| `-n` | 加密 | RSS | 解密 | RSS |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 134 MB/s | 28 MB | 134 MB/s | 28 MB |
| 2 | 257 MB/s | 45 MB | 257 MB/s | 41 MB |
| 4 | 470 MB/s | 79 MB | 467 MB/s | 62 MB |
| 8 | 660 MB/s | 147 MB | 657 MB/s | 92 MB |
| 16 | 764 MB/s | 206 MB | 736 MB/s | 156 MB |
| 20（預設） | **768 MB/s** | 244 MB | **756 MB/s** | 164 MB |

在這台 10 核機器上，吞吐量可順利擴展至約 `-n 16`——相較 `-n 1` 為 **5.7 倍**
——而預設值（`2 × 核心數` = 20）正位於平原區，無需另行調整。RSS 隨在途 chunk
數（每個約 4 MiB）線性成長，與 codec 的取捨相同。

上文引用的 `--encrypt-only` 速率（**401 MB/s**）是 B 節的中位數，低於此處 `-n 4`
以上的每一列。B 節回報中位數那一輪、此 sweep 回報最佳一輪，在途數量也不同，故任一者
單獨都不是「該」加密速率；在這顆磁碟上，B 節量到的是寫入。

> **方法論**：此 sweep 採交錯執行——每一輪跑完整個 sweep，並回報各設定的最佳
> 時間。若把某個 `-n` 的所有輪次跑完才換下一個，CPU 會單調升溫，在高 `-n` 呈現
> 純粹由溫度造成的崩跌。
> 各階段一完成即刪除自己的封存，且空間不足時腳本會拒絕開始。

> **狀態**：macOS 吞吐量／RSS 數字已於 Apple M4 驗證。Windows throughput
> MB/s 另由 `encrypt_mbps_win.zsh` 驗證；Windows peak working set 則由既有
> Windows RSS 腳本覆蓋。正確性是強制檢查而非假設——macOS sweep 在任一 `-n`
> 設定無法還原為相同位元組時即中止，且 `--crypto-selftest` 會對四種 payload
> 形狀檢查全部 16 種加密／解密 `-n` 組合。

## RGB1 容器各 codec 吞吐量

`../test/test_swift_tar_rgb1.zsh` 將 RGB1 容器經由 swift_tar 各 codec 封存，回報封存
大小、壓縮比、建立／解出耗時與 MB/s，並附上執行日期與建置版本。加上 `--record`
才會將表格寫入該平台對應的檔案：
[`-mac.txt`](rgb1_container_mbps_output-mac.txt) ·
[`-win.txt`](rgb1_container_mbps_output-win.txt)。

語料為真實取樣的 1080p 視訊影格（`sample_consecutive/f000.rgb1`，6,221,676 B）。

> **寫入紀錄採選擇性加入。** 未加 `--record` 時這純粹是一支正確性測試，不會動到
> 入版的表格。在機器負載下取得的執行，時間會一致變慢而體積不變，故請在機器閒置時，
> 有意識地寫入紀錄。

```sh
../test/test_swift_tar_rgb1.zsh              # 僅驗證 / verify only
../test/test_swift_tar_rgb1.zsh --record     # 驗證並更新本平台的表格
```

## claw-code ZIP 吞吐量與 RSS

`zip_claw_code_mbps_rss.zsh` 以完整 `claw-code` 語料執行真實 ZIP encode 與
decode，逐輪回報十進位 logical-input MB/s 與程序 peak RSS，並比較第一輪解壓目錄和
來源。預設執行三輪，結果寫入 `zip_claw_code_mbps_rss_output.txt`。

```sh
ROUNDS=3 ./zip_claw_code_mbps_rss.zsh ../../claw-code
```

Apple M4（claw-code，5448 個檔案、1406 MB；build
`swift_tar 0.1.2 (v0.1.1-16-g72b2bbca-dirty) 20261022-184744`），3 次中位數：
encode **6.86 秒／205 MB/s**、peak RSS 295 MB，因為成員預設以平行方式 deflate
（見文末 `-n` 一節）；decode **3.52 秒／400 MB/s**、peak RSS 10 MB。decode 經由
macOS 建置靜態連結的固定版本 zlib；macOS 的系統 libz 解同樣的 deflate 資料約快 2 倍
（[`chunk_size_tradeoff.txt`](chunk_size_tradeoff.txt) 中 TGZ 解壓約 930 對約
482 MB/s）。

## 建立端 `-C` 相容性

`swift_tar -c` 與系統 tar 一樣遵循 `-C`：執行
`swift_tar -c --zstd -f out.tar.zst -C <parent> <leaf>` 時，會先開啟封存輸出，
再切換輸入工作目錄，結束時還原原目錄；因此相對 `-f` 建立在呼叫目錄，entry name
也不會帶入 parent path 或 `..`。`swift_tar -test` 會檢查此項
（`create-side -C: native ZSTD round-trip`）。

Windows build `swift_tar 20260718-171714` 已完成以下驗證：

- 隔離的 `-C ../source leaf` native-ZSTD round-trip：archive 留在 invocation
  directory；entry 僅有 `leaf/` 與 `leaf/README.md`；外部 `zstd` 加 Windows
  系統 tar 列出相同項目；解出內容逐 byte 相同。
- 將 root Windows helper pipeline 複製到隔離目錄，以 `n=2` 跑 file／nul
  兩種模式；八種格式在兩種模式皆通過，ZSTD file 解出樹與 TGZ 相同，原始
  ZSTD log 也記錄 `native libzstd via swift_tar`。
- `release/swift_tar_win.zip` 內的執行檔回報 `20260718-171714`、self-test
  通過，並保留 static zlib 1.3.2 與 zstd 1.5.7 provenance。

## tgz_inflight_rss.zsh

**問題**：swift_tar 的 `-n` 旗標（chunk-parallel gzip 的在途 chunk 並行數）
是否控制 TGZ encode／decode 的 peak RSS？`zshrc.zsh` 的 `getar()` 沒有傳入
`-n`，因此 TGZ benchmark 使用預設值 `inflight = cores*2`（R45-Mac 測試機
為 10 核心，因此預設是 20）。

**使用方式**：

```sh
swift_tar/verifications/tgz_inflight_rss.zsh <path-to-corpus>
```

**原始輸出**：[`tgz_inflight_rss_output.txt`](tgz_inflight_rss_output.txt)。
腳本每次執行都會用最新 stdout 覆寫此檔案。測試使用 R45-Mac 機器上的真實
`claw-code` 語料（約 1.3GB）。

### 記憶體為何有界

以下兩種模式若存在，會讓 peak RSS 接近語料大小且不受 `-n` 影響：

- Foundation `FileHandle.read` 在 CLI 緊密迴圈中累積 autorelease 物件。熱讀寫
  迴圈皆在 `autoreleasepool` 之內：`TarWriter.add` 讀檔迴圈、
  `ParallelChunkSink.dispatch` worker、`gzipDecodeStream`、
  `TarReader.readExactly`、解出寫檔迴圈與尾端 drain 迴圈。
- `Data` 的 append + `removeFirst` 模式：`removeFirst` 保留 backing store，而
  `append` 持續延長同一儲存區，最終讓單一 buffer 成長到整條 tar stream 的大小。
  `ParallelChunkSink.buffer`（encode）將 staging `Data` 填滿至 `chunkSize` 後，
  把完整物件交給 worker，下一個 chunk 使用全新 buffer；`TarReader.pending`
  （decode）以明確的已消耗 offset 搭配 `subdata` 壓實。

### macOS 結果摘要

> **狀態**：僅在 R45-Mac 測試機完成驗證。Windows 的平台特定結果請參考
> 下一節。

| 方向 | Peak RSS |
| --- | --- |
| Encode | **115MB（`n=4`）→ 298MB（`n=40`）；預設 `n=20` = 222MB** |
| Decode | **約 70–76MB，不受 `-n` 影響** |

encode 為 4.6–8.2 秒，decode 為 3.3–4.5 秒。encode RSS 呈 `-n` 線性關係
（在途 chunk 數 × 每個 chunk 約 8MiB）。decode 經由 macOS 建置靜態連結的固定版本
zlib；macOS 的系統 libz 解壓約快 2 倍（見 chunk 大小一節）。

### Windows 驗證

**原始輸出**：
[`tgz_inflight_rss_win_output.txt`](tgz_inflight_rss_win_output.txt)

Windows 上 gzip 經由靜態連結的 zlib 1.3.2（固定版本的 submodule）執行。其他外部
codec 經由專用的 `DispatchQueue` pipe pump，並以同步 `readData(ofLength:)` 限制
每輪 `Data` 的生命週期。

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

encode 呈現預期的線性 `-n` 關係，decode 則穩定維持約 43–45MB。

完整掃描中 encode 為 7.2–15.6 秒；正常平行平台區（`-n 12..40`）為 7.2–7.8 秒，
接近 macOS 的 4.6–8.2 秒。Decode 為 9.7–11.0 秒，慢於 macOS 的 3.3–4.5 秒，
因此 Windows 解出與檔案 I/O 成本仍是另一個最佳化目標。

### 副檔名相容性

將 gzip 輸出改名為 `.zip` 不會轉換成 ZIP container。Windows 實測
`swift_tar -c -z -f archive.zip` 產生 gzip magic `1f 8b`；`unzip -t` 以
`short read` 失敗，但 Windows 系統 `tar -tf` 與 `swift_tar -x` 均成功。
此格式應使用 `.tgz` 或 `.tar.gz` 副檔名。

### 實務結論

- 在 macOS 上，TGZ 的記憶體用量與 LZFSE 格式相當或更低。預設 `-n`
  不需調整；需要時仍可降低 `-n`，以 encode 速度換取更低記憶體
  （`n=4` = 115MB，時間增加 75%）。
- 在 Windows 上，native zlib 將 TGZ encode RSS 維持在 56–208MB
  （`-n 4–40`，線性），decode RSS 約 43–45MB，且不受 `-n` 影響。
- 使用靜態 zlib 時，平行 encode 為 7.2–7.8 秒；decode 為 9.7–11.0 秒，仍是
  Windows 特定的最佳化目標。
- `swift_tar -test -debug` 涵蓋建立端 `-C`、native ZSTD、兩種 Windows 寫入
  後端與系統 tar 雙向互通。

## 解壓：時間花在哪裡

`verifications/extract_write_path.zsh` → `extract_write_path_output.txt`

macOS 27.2.0 arm64、10 核（4P+6E）、APFS，每組語料 256 MiB，
swift_tar `0.1.2 (v0.1.1-16-g72b2bbca-dirty) 20261022-184744` 對 bsdtar 3.5.3。
本節的 `swift -x` 以預設 `-n` 執行，小檔因此走平行寫檔路徑（紀錄第 3 節的
CPU/wall 為 3.95，`-n 1` 時為 1.17）。

### 1. 解壓成本在「每個檔案」，而 swift_tar 在小檔上勝出

固定總位元組，只改變檔案數：

| 語料 | 檔案數 | 平均大小 | bsdtar -c | bsdtar -x | swift -c | swift -x | 比值 |
|---|---|---|---|---|---|---|---|
| few  | 8    | 32 MiB  | 2074ms | 85ms  | **319ms** | 126ms  | 慢 1.5 倍 |
| mid  | 512  | 512 KiB | 2098ms | 136ms  | **335ms** | 153ms  | 1.1 倍 |
| many | 8192 | 32 KiB  | 2306ms | 804ms | **384ms** | **428ms** | **0.5 倍——更快** |

這張表帶出兩件事：

- **建立封存在每一組語料都比 bsdtar 快約 6 倍。** 分塊平行 gzip 確實在做事。
- **檔案越小，swift_tar 的相對表現越好。** 它輸在少量巨檔，贏在數千個小檔。

此處是 bsdtar 的每檔成本佔主導：8192 個檔要 804ms，swift_tar 只要 428ms。

**實務結論：誰比較快完全取決於封存的形狀。** Swift toolchain 那種「少量大檔」
的封存，bsdtar 勝；原始碼樹或 rootfs 這種形狀，swift_tar 勝。

### 2. 寫檔路徑佔解壓時間多少

`-t` 解開整個封存但不寫檔；`-x` 解開並寫檔。

| 語料 | 檔案數 | swift -t | swift -x | 寫檔路徑 | bsdtar -t | bsdtar -x | 寫檔路徑 |
|---|---|---|---|---|---|---|---|
| few  | 8    | 75ms | 162ms  | 87ms   | 30ms  | 163ms  | 133ms  |
| many | 8192 | 285ms | 438ms | 153ms | 169ms | 765ms | 596ms |

8192 個小檔時，swift_tar 的寫檔路徑佔 438ms 中的 153ms，bsdtar 佔 765ms 中的
596ms。解碼 256 MiB，swift_tar 為 75–285ms、bsdtar 為 30–169ms。檔案 I/O 是
**syscall-bound 而非 CPU-bound**（`sys` 遠大於 `user`）。

少量大檔時，寫檔路徑只佔 162ms 中的 87ms——少數幾次大型循序寫入，沒有東西可以
平行化。該處與 bsdtar 的差距在餵給寫入端的讀取／解碼管線：`few` 語料的 `-t` 是
75ms 對 bsdtar 的 30ms。

### 3. `--gzip` 確實每 4 MiB 一個成員——而 `gzip -l` 看不到

| 封存 | 成員數 | 每成員解壓後大小 |
|---|---|---|
| bsdtar `-czf` | 1 | 268,453,376 |
| swift_tar `--gzip` | 65 | min 51,712 / **max 4,194,304** |

4,194,304 正好是 4 MiB，pigz 式分塊如文件所述正常運作。

**`gzip -l` 無法驗證這件事，也不該拿來驗證。** 它只讀第一個成員的 header
與檔案最後 4 bytes 的 ISIZE，因此無論幾個成員，輸出永遠是兩行——單成員與
65 成員的封存看起來完全一樣。必須逐成員走訪整個串流（本腳本以
`zlib.decompressobj` 搭配 `unused_data` 完成）。

順帶一提的推論：基於同樣的原因，`gzip -l` 對任何多成員封存回報的解壓後大小
都是錯的。

## macOS 與 Linux 的平行解壓

`verifications/parallel_extract_correctness.zsh` → `parallel_extract_correctness_output.txt`

把小檔寫入跨執行緒批次化的 `FileWriterPool` 在所有平台上執行，並在 `winWriteFile`
之外有 POSIX 寫入器（`posixWriteFile`）。

### POSIX 寫入器如何運作

- **每個檔案只開一次。** `posixWriteFile` 只做一次 `open`，然後對同一個
  descriptor 呼叫 `fchmod`／`futimens`。
- **用 `fchmod` 而非事後以路徑呼叫 `chmod`。** 較便宜，而且正確：事後的路徑呼叫
  會與「此後把該名稱下的檔案換掉的其他 worker」形成競態。mode 也不能交給 `open`
  的 mode 參數——那會被 umask 遮罩且僅在建立時生效，於是 0755 會落成
  `0755 & ~umask`。
- **保序屏障與平台無關**，因為危害不在檔案系統，而在佇列本身：對某名稱的
  排隊寫入必須在 symlink 取代它之前落地、`link(2)` 需要其目標已存在，而重複路徑
  必須由**最後**一個項目勝出。

### 結果：解出 8192 個小檔（合計 256 MiB）

| | swift_tar |
|---|---|
| wall | **631ms** |
| 寫入路徑（`-x` 減去 `-t`） | **397ms** |
| CPU/wall | **6.40** |
| 對比 bsdtar（2405ms） | **快 3.8 倍** |

512 個 512 KiB 的檔案：133ms。

**大型檔案依設計走內聯串流。** 超過 `smallFileMax`（4 MiB）者不進 pool，因為該 pool
會整檔緩衝，其記憶體上限為 inflight × smallFileMax。8 × 32 MiB 跑五輪：169–174ms。

因此 pool **不影響**「少量大檔」封存——該情形下 swift_tar 落後 bsdtar。那個差距在
讀取／解碼的管路，不在寫入：單看 `-t` 是 75ms，對比 bsdtar 的 30ms。

### 正確性

兩個平台皆 12/12，涵蓋 `-n` 1／2／8／16 並重複執行——保序類的臭蟲不會每次都失敗，
單跑一輪什麼也證明不了。

| | macOS 27.0.0 arm64 | Linux aarch64（Buildroot guest） |
|---|---|---|
| 檔案樹與參考一致 | PASS | PASS |
| mode 0755 / 0600 / 0644 | PASS | PASS |
| symlink 未被排隊的寫入覆蓋 | PASS | PASS |
| hardlink 與其目標共用 inode | PASS | PASS |
| mtime 由 worker 還原 | PASS | PASS |
| 6 MiB 內聯檔案位元組一致 | PASS | PASS |
| 重複路徑：最後一個項目勝出 | PASS | PASS |
| 不可寫的目的地會大聲失敗 | PASS | PASS |

### 測試框架的限制

以下每一項都會讓測試框架偽造出產品失敗：

1. **guest 上 busybox 的 `tar` 沒有 append**，`tar -rf` 會靜默產生只有一個成員的封存。
   重複路徑的輸入以 swift_tar 自己的 `-r` 建立，且在該案執行前先斷言成員數。
2. **guest 上沒有 `stat`。** 腳本使用 zsh 的 `zsh/stat`。
3. **`07777` 在 zsh 中是十進位的 7777。** zsh 不把前導零視為八進位；權限遮罩寫成
   `8#7777`。
4. **guest 上沒有 `diff`**，而 `diff | while read` 會把迴圈放進子 shell，於是對報告的
   附加內容全部消失。檔案樹以 zsh 比對。

本腳本與 `extract_write_path.zsh` 都使用 `mktemp -d`，故並行執行不會共用 scratch 目錄。

## QoS class 與 `Thread.qualityOfService` 做不到的事

`qos-DOE.swift` —— 不帶旗標執行即印出用法；`--skip-timing` 僅執行精確部分。
原始輸出見 `qos-DOE_output.txt`。

各 API 的實際行為：

| api | 是否改變 `qos_class_self()` |
| --- | --- |
| 對**執行中**執行緒設 `Thread.current.qualityOfService = X` | **否** |
| 於 `start()` **之前**設 `thread.qualityOfService = X` | 是 |
| `pthread_set_qos_class_self_np(X, 0)` | 是 |

`Thread.qualityOfService` 的行為與文件一致 —— 它是建立時的屬性，不是即時控制。
陷阱在於：對已在執行的執行緒賦值是**靜默的無操作**，既不報錯也不警告，
`qos_class_self()` 完全不變。**主執行緒永遠處於執行中**，故無法透過該屬性設定；
該處唯一的選項是 `pthread_set_qos_class_self_np`。

該類別並非僅具裝飾性。相同迴圈交錯執行 5 輪：

| class | 中位數 | 相對 userInitiated |
| --- | ---: | ---: |
| userInitiated | 4.7 ms | 1.0x |
| utility | 7.9 ms | 1.7x |
| background | 539.5 ms | **113.9x** |

對本專案有兩項後果。其一，在主執行緒上設定該屬性並假設已生效的量測程式，是在比較
它以為相同、實則不同的執行緒 —— 這正是 `swift_tar_DOE` 使用 pthread 呼叫的原因。
其二，`taskpolicy -c background` 不是溫和的提示，而是兩個數量級的懲罰，絕不可套用
在計時的執行上。

> **計時一節為何採交錯執行。** 各類別依序跑完的話，同一個呼叫的時間會隨其位置而
> 改變，因為跑了十秒的 `background` 組會讓機器停在與開始時不同的狀態。任何對排程或熱敏感的項目，
> 循序掃描皆不可信；故各組交錯執行並回報中位數。

---

## 各平台效能資料 → `profile/`

[`verifications/profile/`](profile/README.md) 存放各平台的計時資料與產生它們的腳本。
解壓相對於 bsdtar 的速度**取決於平台**。

同一支腳本、同樣三種形狀、兩個平台，交錯執行取最小值（swift_tar / bsdtar）：

| 形狀 | macOS | Linux（QEMU aarch64） |
|---|---|---|
| 20 × 8 MB | 34 / 73 毫秒 = **0.47×** | 24 / 27 毫秒 = **0.89×** |
| 200 × 800 KB | 53 / 89 毫秒 = **0.60×** | 47 / 28 毫秒 = **1.68×** |
| 2000 × 80 KB | 84 / 194 毫秒 = **0.43×** | 51 / 38 毫秒 = **1.34×** |

解壓差距**只在 Linux 出現**，且落在碎檔形狀：該處 swift_tar 在 200 × 800 KB 與
2000 × 80 KB 慢 1.34–1.68 倍，在 20 × 8 MB 則較快。macOS 上 swift_tar 在三種形狀都
比 bsdtar 快。

在此處量任何東西之前，該資料夾 README 裡有兩件事值得先知道：取樣式 profiler 對一個
0.17 秒的目標無效（最多只取到 52 個樣本）；以及參照 tar 必須以「問它是
什麼」來挑選——Linux VM 的 `/usr/bin/tar` **就是 swift_tar**，依檔名挑選會讓它與自己
比較，並回報一個完美的 1.00×。

## chunk 大小：4／8／16 MiB 各付出什麼

`chunk_size_tradeoff.zsh` → `chunk_size_tradeoff.txt`

`TAR_CHUNK_SIZE`（`swift_tar.swift`，`1 << 22` = 4 MiB）是編譯期常數：`ParallelChunkSink`
雖然收 `chunkSize:`，但兩個呼叫端都不傳值、建置腳本也不覆寫，沒有任何旗標碰得到它。
所以腳本**重建**：把原始碼複製到暫存目錄，只替換那一行常數（逐支確認替換成功），以
`compile_tar.zsh` 的 swiftc 參數與既有的 `build/` 產物建出每一支變體。不動工作樹、不呼叫
`generate_version.zsh`（它會寫 `version-mac.txt`）、不覆蓋已安裝的執行檔。`--source REV`
從 git 版本建置，工作樹中未提交的改動因此不會混進變體。

與現值相同的那一支用與其他變體完全相同的方式建置，三者之間唯一的差異就是那個常數；另外也
量已安裝的執行檔，檢查這個建置方式等同正式建置。

| chunk | ZSTD 大小 | ZSTD 解壓 | TGZ |
| --- | ---: | ---: | --- |
| **4 MiB** | 385.7 MiB | 1431 MB/s | 速度和大小都跟 chunk 無關 |
| 8 MiB | **−2.8%** | −2.6% | |
| 16 MiB | **−4.0%** | −2.9% | |

claw-code，swift_tar 工作樹 @ `d493560`，5 輪交錯取最小值，輸出在 RAM disk，解壓以 `--cat` 量。

**大小的差異是確定的，速度的差異不是。** 壓縮後大小與負載無關：另行建置、常數同值的對照組
在輸出的精度（0.1 MiB）內與 4 MiB 相同。速度則沒有那麼精確地重現：除了 TGZ 解壓，對照組
每項速度偏離 4 MiB 最多 3.0%。唯一一致的速度訊號是方向：chunk 越大，ZSTD 解壓與無壓縮
tar 越慢。

**TGZ 解壓是對照組唯一不同之處，而原因是 zlib，不是 chunk。** 對照組（已安裝的
`swift_tar 0.1.1`，正式建置）TGZ 解壓為 482 MB/s，4 MiB 變體為 930 MB/s，−48.2%。
正式建置靜態連結固定版本的 zlib submodule；變體以 `-lz` 連結系統 libz，而它在 macOS
上解壓約快 2 倍。

**維持 4 MiB。** 放大 chunk 只換到 ≤4% 的 ZSTD 大小，速度沒有變好。TGZ 完全不受影響——gzip
的視窗只有 32 KiB，chunk 碰不到它。

`zstd_decode_gap.zsh --mode chunk` 問的是另一件事（固定 chunk 大小、以 `--zstd-level` 改變
frame 內容），兩者不可互相引用。

## ZIP：以 `-n` 個執行緒壓縮成員換到什麼

`zip_parallel_speed.zsh` → `zip_parallel_speed.csv2`、`zip_parallel_speed_output.txt`

ZIP 的每個成員各自由一個執行緒壓成 deflate 串流，再依序寫出；`-n` 是同時
壓縮的成員數，預設每個核心一個。腳本以每個 `-n` 各壓同一棵樹，三輪交錯、每個項目取最快的
一輪，並計算輸出的雜湊：任何兩個排序的 swift_tar 項目 sha256 不同時，`record` 以 1 結束——
速度若是靠改變位元組換來的，那就是另一個結果。

claw-code（1.4 GB，5,448 個檔案）：

| | `-n 1` | `-n 2` | `-n 4` | `-n 8` | 預設 | 最大記憶體，`-n 1` → 預設 |
|---|---|---|---|---|---|---|
| Apple M4（10 核） | 28.6 秒 | 14.4 秒 | 8.7 秒 | 7.1 秒 | 6.8 秒（4.2 倍） | 9 MB → 283 MB |
| Linux guest（4 vCPU、HVF） | 28.0 秒 | 14.3 秒 | 8.6 秒 | 8.9 秒 | 8.6 秒（3.3 倍） | 21 MB → 121 MB |

* **位元組不變。** 同一平台上每個 `-n` 的 sha256 相同，M4 的那個就是
  `cross_platform_bytes.csv2` 裡 `zip` 記的值。guest 的封存大小相同（497,122,541
  bytes），sha256 卻不同：每個 ZIP 項目都帶有 Unix UID/GID 額外欄位（0x7875），而
  guest 在這裡的語料擁有者不同。兩邊擁有者都設為 501:20 時，`cross_platform_bytes.csv2`
  顯示兩個平台的 ZIP 逐位元組相同。
* **2 與 4 個執行緒幾乎線性，之後趨於平坦。** M4 只有 4 個效能核心，效率核心加入後使用者
  CPU 時間從 28.1 秒升到 36 秒。同一個檔案之內也沒有平行，所以最大的幾個成員決定了下限。
* **`-n` 超過核心數反而較慢**（`-n 16`：M4 7.1 秒、guest 9.3 秒），記憶體也更多。
* **同一台機器上的其他工具都是單一執行緒：** M4 上 Info-ZIP `zip -r -6` 31.2 秒、
  `bsdtar --format zip` 30.5 秒；guest 內 `bsdtar` 27.9 秒。
* **排序不花時間。** `--zip-unsorted` 並不比預設快：M4 上 7.6 秒對預設 6.8 秒，guest 內
  8.8 秒對 8.6 秒（各取最快一輪）。

這次量測的限制：Windows 沒有量，它的建置也沒有多執行緒路徑。
