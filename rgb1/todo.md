# RGB1 image container TODO / RGB1 影像容器 TODO

## RGB1 image container / RGB1 影像容器

- Added source-level support for a minimal raw RGB frame container with fixed
  geo and creator metadata:
  `magic("RGB1") + width(UInt32BE) + height(UInt32BE) + flags(UInt32BE) + lat_e7(Int32BE) + lng_e7(Int32BE) + height_mm(Int32BE) + geo_datum_code(UInt32BE) + title[64] + country[512] + creator_email[254] + right[4] + created_unix_ms(Int64BE) + timezone_offset_minutes(Int16BE) + RGB payload`.
- 已加入含固定地理與建立者 metadata 的極簡 raw RGB frame 容器 source-level
  支援：
  `magic("RGB1") + width(UInt32BE) + height(UInt32BE) + flags(UInt32BE) + lat_e7(Int32BE) + lng_e7(Int32BE) + height_mm(Int32BE) + geo_datum_code(UInt32BE) + title[64] + country[512] + creator_email[254] + right[4] + created_unix_ms(Int64BE) + timezone_offset_minutes(Int16BE) + RGB payload`。
- Text limits: title `< 64` ASCII bytes, country `< 512` ASCII bytes,
  creator_email `<= 254` ASCII bytes, right `<= 4` English letters.
- 文字限制：title `< 64` ASCII bytes、country `< 512` ASCII bytes、
  creator_email `<= 254` ASCII bytes、right `<= 4` 個英文字母。
- Current CLI operations:
  `--rgb1-pack`, `--rgb1-info`, and `--rgb1-raw`.
- 目前 CLI operation：
  `--rgb1-pack`、`--rgb1-info`、`--rgb1-raw`。
- RGB1 itself is uncompressed; storage/transport compression remains zstd
  level 9 by default.
- RGB1 本身不壓縮；儲存與傳輸壓縮層預設仍為 zstd level 9。
- Full format spec:
  [rgb1-format.md](rgb1-format.md)
- 完整格式規格：
  [rgb1-format.md](rgb1-format.md)

## Known issues, not yet fixed / 已知但尚未修正

Raised in review on 2026-08-14. Listed so a later reader can tell these are
open, not deliberate. / 2026-08-14 review 提出。在此列出，讓後續閱讀者能分辨
這些是待處理項目，而非刻意保留的設計。

- **A — `swift_tar_DOE.swift:848` flattens on every frame.**
  `decodedPrev = Array(out.joined())` runs unconditionally, so `--no-verify`
  can no longer avoid it. At 1080p that is a 6.2 MB allocation plus copy per
  frame, roughly 0.5–1 ms inside the timed region against a ~9–10 ms decode and
  a 16.67 ms budget — about 5–10% inflation on the very number that decides
  PASS/FAIL. `streaming_budget_benchmark.zsh`'s header comment still promises
  the opposite. Fix: `if opt.delta { decodedPrev = Array(out.joined()) }`.
- **A —「`swift_tar_DOE.swift:848` 每格都攤平」。**
  `decodedPrev = Array(out.joined())` 無條件執行，`--no-verify` 已擋不掉。
  1080p 下每格為 6.2 MB 配置加複製，在計時區內約 0.5–1 ms；對照解碼約 9–10 ms
  與 16.67 ms 預算，約灌水 5–10%——而那正是拿來判 PASS/FAIL 的數字。
  `streaming_budget_benchmark.zsh` 的檔頭註解仍宣稱相反。修法：改為
  `if opt.delta { decodedPrev = Array(out.joined()) }`。
- **B — the same expression is computed twice per frame** at
  `swift_tar_DOE.swift:848` and `:850`, under `--verify`. Store it in a local
  and reuse it.
- **B —「同一運算式每格算兩次」**，位於 `swift_tar_DOE.swift:848` 與 `:850`，
  在 `--verify` 開啟時發生。存成區域變數重用即可。
- **C — the delta guards are asymmetric.** `encodeBand:620` requires
  `prev.count == payload.count`, `decodeBand:656` only checks `let prev =
  previous` and then indexes `prev[base + i]`. With a mixed-size corpus (the DOE
  accepts any file list) encode skips the delta while decode still applies it,
  giving a wrong reconstruction; a smaller previous frame indexes out of bounds
  and crashes. Latent today only because the sampler emits equal-sized frames.
- **C —「delta 守門條件兩端不對稱」。** `encodeBand:620` 要求
  `prev.count == payload.count`，`decodeBand:656` 僅檢查 `let prev = previous`
  便直接取用 `prev[base + i]`。語料尺寸混雜時（DOE 接受任意檔案清單），編碼端
  跳過差分而解碼端照做，導致重建錯誤；若前一格較小則會越界崩潰。目前僅因
  sampler 產出的影格尺寸一致而未爆發。
- **#2 — the 8-frame batch is still extrapolated to a per-frame bitrate.**
  `verifications/rgb1/nv12_vs_rgb1_streaming.zsh:81-82` still passes
  `-frames:v "$FRAMES"` with `FRAMES` defaulting to 8, compressed as one zstd
  stream, so the ratio benefits from cross-frame dedup. `FAQ.md:175` still
  labels that row `independent frames + zstd`, which it is not. The
  2026-08-14 correction (122 → 689 Mbps) changed *where* the frames are sampled
  (mid-video instead of the static opening), not *whether* they are compressed
  as a batch, so the per-frame figures still rest on batch ratio = per-frame
  ratio.
- **#2 —「8 格批次壓縮仍被外推成每格位元率」。**
  `verifications/rgb1/nv12_vs_rgb1_streaming.zsh:81-82` 仍以
  `-frames:v "$FRAMES"`（`FRAMES` 預設 8）取格，並壓成單一 zstd 串流，因此
  壓縮比含跨格去重的紅利。`FAQ.md:175` 仍將該列標為
  `independent frames + zstd`，名實不符。2026-08-14 的更正（122 → 689 Mbps）
  改的是**取樣位置**（改自影片中段，而非靜態開頭），不是**批次或逐格**，
  故每格數字仍建立在「批次壓縮比等於逐格壓縮比」之上。

`comparison.csv` has not been regenerated since A appeared, so the numbers
committed today are still clean — the inflation lands on the next run.
`comparison.csv` 自 A 出現後尚未重跑，因此今日入版的數字仍未受影響——灌水會在
下次執行時才發生。

Follow-up / 後續:

- Compile and smoke-test the RGB1 CLI operations.
- 編譯並 smoke-test RGB1 CLI operations。
- Add stdin support for `--rgb1-info` and `--rgb1-raw`.
- 為 `--rgb1-info` 與 `--rgb1-raw` 加入 stdin 支援。
- Define the stream-level container for keyframe + diff stepping on top of
  RGB1 frames.
- 在 RGB1 frame 之上定義 keyframe + diff stepping 的 stream-level container。
