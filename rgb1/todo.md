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
- RGB1 itself is uncompressed. The storage/transport level is `-3` for streaming
  and `-19` for archiving; level 9 was recommended here until measurement retired
  it. See [rgb1-format.md](rgb1-format.md) — Zstd Usage.
- RGB1 本身不壓縮。儲存與傳輸壓縮等級為串流 `-3`、封存 `-19`；此處原本建議
  level 9，量測後已淘汰。詳見 [rgb1-format.md](rgb1-format.md) 的 Zstd Usage 一節。
- Full format spec:
  [rgb1-format.md](rgb1-format.md)
- 完整格式規格：
  [rgb1-format.md](rgb1-format.md)

## Review findings / review 項目（A、B、C、#2 皆已於 2026-08-14 處理）

Raised in review on 2026-08-14 and all closed the same day. Kept here with the
original diagnosis so the reasoning stays auditable; the fixes are in
swift_tar 25e1759 and the per-frame flags in the commit that follows it.
2026-08-14 review 提出，並於同日全數處理完畢。此處保留原始診斷以便日後追溯推理
過程；修正見 swift_tar 25e1759，逐格旗標見其後的提交。

- **A — ✅ fixed. `swift_tar_DOE.swift:848` flattened on every frame.**
  `decodedPrev = Array(out.joined())` runs unconditionally, so `--no-verify`
  can no longer avoid it. At 1080p that is a 6.2 MB allocation plus copy per
  frame, roughly 0.5–1 ms inside the timed region against a ~9–10 ms decode and
  a 16.67 ms budget — about 5–10% inflation on the very number that decides
  PASS/FAIL. `streaming_budget_benchmark.zsh`'s header comment still promises
  the opposite. Fix: `if opt.delta { decodedPrev = Array(out.joined()) }`.
- **A — ✅ 已修正。「`swift_tar_DOE.swift:848` 每格都攤平」。**
  `decodedPrev = Array(out.joined())` 無條件執行，`--no-verify` 已擋不掉。
  1080p 下每格為 6.2 MB 配置加複製，在計時區內約 0.5–1 ms；對照解碼約 9–10 ms
  與 16.67 ms 預算，約灌水 5–10%——而那正是拿來判 PASS/FAIL 的數字。
  `streaming_budget_benchmark.zsh` 的檔頭註解宣稱相反。現已改為僅在 `--delta`
  或 `--verify` 需要時才攤平；以掃描實際使用的組合實測，解碼由 16.27 降至
  9.51 ms/f（−41.5%），且壓縮輸出位元組完全相同。
- **B — ✅ fixed. The same expression was computed twice per frame** at
  `swift_tar_DOE.swift:848` and `:850`, under `--verify`. Store it in a local
  and reuse it.
- **B — ✅ 已修正。「同一運算式每格算兩次」**，位於 `swift_tar_DOE.swift:848` 與 `:850`，
  在 `--verify` 開啟時發生。存成區域變數重用即可。
- **C — ✅ fixed. The delta guards were asymmetric.** `encodeBand:620` requires
  `prev.count == payload.count`, `decodeBand:656` only checks `let prev =
  previous` and then indexes `prev[base + i]`. With a mixed-size corpus (the DOE
  accepts any file list) encode skips the delta while decode still applies it,
  giving a wrong reconstruction; a smaller previous frame indexes out of bounds
  and crashes. The mirroring guard now sits at the decode call site, which is
  the only place that knows the frame size. Verified with 64x48 and 32x24
  frames: smaller-first trapped with exit 133 before the fix and verifies
  cleanly after; `mixed_size_delta.zsh` locks all three cases in.
- **C — ✅ 已修正。「delta 守門條件兩端不對稱」。** `encodeBand:620` 要求
  `prev.count == payload.count`，`decodeBand:656` 僅檢查 `let prev = previous`
  便直接取用 `prev[base + i]`。語料尺寸混雜時（DOE 接受任意檔案清單），編碼端
  跳過差分而解碼端照做，導致重建錯誤；若前一格較小則會越界崩潰。目前僅因
  sampler 產出的影格尺寸一致而未爆發。鏡像守門現置於解碼呼叫端——唯一知道整格
  大小之處。以 64×48 與 32×24 實測：修正前「小→大」以 exit 133 崩潰，修正後通過
  驗證；`mixed_size_delta.zsh` 已固化三種情境。
- **#2 — resolved 2026-08-14; the concern did not survive measurement.**
  The worry was that compressing 8 frames as one stream lets the codec dedup
  across frames, inflating a per-frame bitrate. It does not, at 1080p: one frame
  is 3.1 MB (NV12) or 6.2 MB (RGB24), larger than zstd, gzip or lz4 can look
  back across, so they never reference the previous frame. `batch_vs_per_frame.zsh`
  (added in 0e528ec, 40 min after the commit that review was written against —
  `git ls-tree fd48496` shows it absent, so it was not overlooked) measured
  −0.1% to 0.0% for
  zstd -3 across two frame sources. **The "all five codecs" half of this was
  wrong, and was corrected on 2026-08-14 — see #10 below.** It rested on
  `nv12_vs_rgb1_streaming.zsh`, which had no `-ss` and so measured the clip's
  fade-from-black opening; re-run from mid-video, xz on NV12 costs **+21.27%**,
  not the +0.34% recorded here. The window argument still holds for zstd, gzip
  and lz4, whose look-back is smaller than one frame, and the 689 Mbps
  conclusion is unaffected because it comes from zstd.
- **#2 — 2026-08-14 解決；該疑慮經量測不成立。**
  原本擔心把 8 格壓成單一串流會讓 codec 跨格去重，因而灌大每格位元率。1080p 下
  並非如此：單格為 3.1 MB（NV12）或 6.2 MB（RGB24），超出 zstd、gzip、lz4 的回看
  範圍，它們根本不曾參照前一格。`batch_vs_per_frame.zsh`（由 0e528ec 加入，時間
  在該則 review 所依據的提交之後 40 分鐘——`git ls-tree fd48496` 顯示當時該檔尚
  不存在，故並非未察覺）以 zstd -3 對兩種影格來源量得 −0.1% 至 0.0%；
  **其中「延伸至全部五種 codec」那半是錯的，已於 2026-08-14 更正——見下方 #10。**
  該半段依據的是 `nv12_vs_rgb1_streaming.zsh`，而它沒有 `-ss`，量到的是片頭的自黑
  畫面淡入；改自中段重跑後，xz 對 NV12 為 **+21.27%**，而非此處所記的 +0.34%。
  視窗論證對 zstd、gzip、lz4 仍然成立（其回看範圍小於單格），而 689 Mbps 的結論
  不受影響，因為它出自 zstd。

`comparison.csv` was never regenerated while A was live, so A itself never
reached a committed number. That sentence was too comforting: the reason
`comparison.csv` was safe from A is that it had not been regenerated *at all*
since before the benchmark was fixed, so every timing in it was stale by 2.3x.
See round 2 item 5 below.
`comparison.csv` 在 A 存在期間始終未重跑，故 A 本身從未進入任何入版數字。但該句過於
樂觀：`comparison.csv` 之所以不受 A 影響，是因為它自 benchmark 修正之前就*完全*沒有
重跑過，故其中每一個計時數字都過期了 2.3 倍。詳見下方第二輪第 5 項。

## Round 2 review, 2026-08-14 (`fd48496..45bb565`) / 第二輪 review

- **3.1 — ✅ fixed, but not the way it was proposed. The equal-size delta check
  was a tautology.** `mixed_size_delta.zsh` asserted `round-trip verified`, which
  `report()` prints from `opt.verify` alone; skipping the delta is a *correct*
  transform, so the check passed either way. The suggested fix — compare
  compressed bytes for two `/dev/urandom` frames — does not work: zstd stores
  incompressible input verbatim, so both arms come out at exactly 20,212 B. The
  second frame is now a *copy* of the first, making the all-zero residual
  unmistakable (11,004 vs 20,212 B). Negative control: a DOE rebuilt with the
  guard forced false still passes the old string check and fails the new one.
- **3.1 — ✅ 已修正，但作法與建議不同。等尺寸差分檢查是套套邏輯。**
  `mixed_size_delta.zsh` 斷言 `round-trip verified`，而 `report()` 僅依 `opt.verify`
  印出該字串；跳過差分本身是*正確*的變換，故兩種情況都會通過。所建議的修法——比對兩張
  `/dev/urandom` 影格的壓縮位元組——行不通：zstd 對不可壓縮輸入是原樣儲存，兩組皆為
  20,212 B。現改為第二格取第一格的複本，使全零殘差無可爭辯（11,004 對 20,212 B）。
  負向對照：將守門強制為假重新編譯 DOE，舊字串檢查仍通過，新檢查失敗。
- **3.2 — ✅ addressed, with the reasoning corrected.** `rgb1-format.md:141`
  (the review cited 135) now states which path its figures came from.
- **3.2 — ✅ 已處理，但推理已更正。** `rgb1-format.md:141`（review 引為 135）現已載明
  其數字出自哪一條路徑。
- **2.2 — ⚠️ partly right; my first reply said "rejected" and that was too
  absolute.** The review argued that cross-frame matching is structurally
  impossible because swift_tar emits one zstd frame per 4 MiB chunk, and
  concluded the negative result therefore also holds at `zstd-19`.

  Three scripts are in play, not two, and they do not share a pipeline. Two do
  not go through swift_tar at all: `batch_vs_per_frame.zsh:84,91` calls the
  `zstd` CLI directly, and `swift_tar_DOE` compresses per row band
  (`encodeBand:630`). But `nv12_vs_rgb1_streaming.zsh:168` archives the whole
  batch with `swift_tar -c --zstd`, which does chunk at `TAR_CHUNK_SIZE`
  (`swift_tar.swift:180`) and does emit one reset-window zstd frame per chunk.
  For that script the mechanism the review named is the operative one, and my
  "not involved" was wrong.

  It still does not give "structurally impossible", for a reason neither side
  raised: 4 MiB chunks are not aligned to frame boundaries and an NV12 frame is
  **smaller** than a chunk (3,110,400 B vs 4,194,304 B), so one chunk holds a
  whole frame plus a quarter of the next and can match across them. RGB24 at
  1.48 chunks per frame straddles boundaries too. Per-chunk framing *bounds*
  cross-frame reuse to what co-occurs inside one chunk; it does not remove it.

  The extrapolation is the one part that is simply wrong, and only on the CLI
  path: `zstd-19`'s 8 MiB window is *larger* than a 6.2 MB RGB24 frame, so there
  cross-frame matching becomes more available at -19, not less. On the swift_tar
  path the bound holds at any level, since the window resets per chunk.

  Net: the window-size argument in `0e528ec` is the one that covers the measured
  -0.0%, because that number came from `batch_vs_per_frame.zsh`. The framing
  argument is real but applies to a different script and bounds rather than
  forbids.
- **2.2 — ⚠️ 部分成立；我第一次回覆寫「不採納」，下得太絕對。** 該 review 主張跨影格
  匹配在結構上不可能，理由是 swift_tar 每 4 MiB 分塊產生一個 zstd frame，並據此推論
  該否定結果在 `zstd-19` 同樣成立。

  牽涉的是三支腳本而非兩支，且它們並不共用同一條管線。其中兩支完全不經過 swift_tar：
  `batch_vs_per_frame.zsh:84,91` 直接呼叫 `zstd` CLI，`swift_tar_DOE` 則是逐列帶壓縮
  （`encodeBand:630`）。但 `nv12_vs_rgb1_streaming.zsh:168` 是以
  `swift_tar -c --zstd` 封存整批，它確實會依 `TAR_CHUNK_SIZE`（`swift_tar.swift:180`）
  分塊，也確實每塊產生一個視窗重置的 zstd frame。對該腳本而言，review 所指出的機制正是
  作用中的那個，我寫的「與此無關」是錯的。

  但這仍然不足以得出「結構上不可能」，理由是雙方都沒提到的一點：4 MiB 分塊並未對齊影格
  邊界，而 NV12 影格**小於**一個分塊（3,110,400 B 對 4,194,304 B），故單一分塊內含一整格
  再加下一格的四分之一，跨影格匹配得以發生。RGB24 每格 1.48 個分塊，同樣會跨越邊界。
  逐塊分幀只是把跨影格重用**限縮**在單一分塊內共同出現的範圍，並未消除它。

  真正單純錯誤的只有外推那一段，且僅限 CLI 路徑：`zstd-19` 的 8 MiB 視窗*大於* 6.2 MB 的
  RGB24 影格，故在該路徑上，-19 反而讓跨影格匹配更容易而非更難。在 swift_tar 路徑上，
  由於視窗逐塊重置，該限縮在任何等級都成立。

  結論：涵蓋實測 -0.0% 的是 `0e528ec` 的視窗論證，因為那個數字出自
  `batch_vs_per_frame.zsh`。分幀論證確有其事，但適用於另一支腳本，且作用是限縮而非禁止。
- **3.3, 4 — ✅ confirmed, no action.** The nonce bound and the `(( ++pass ))`
  observation were both re-derived and are correct. One addition: the new `throw`
  skips `pipeline.finish()`, leaving in-flight workers holding `output`. Same
  shape as the pre-existing `try input.read` path, and unreachable at 16 PiB, so
  recorded rather than changed.
- **3.3、4 — ✅ 覆核正確，無須動作。** nonce 上限與 `(( ++pass ))` 之觀察皆重新推導
  無誤。補一點：新增的 `throw` 會略過 `pipeline.finish()`，使在途 worker 仍持有
  `output`。此模式與既有的 `try input.read` 路徑相同，且 16 PiB 不可達，故僅記錄不改。

Found while acting on the above, not raised by the review / 處理上述問題時發現，
review 未提出:

- **5. Every published timing was 2.3x too high.** `comparison.csv` dated
  08-13 14:06 predates `413cd82` (in-process libzstd, `-n`), `3e67760` and
  `4dc9510` (QoS), and `25e1759` (flatten out of the timed region). Re-run on the
  current binary, the same three frames give 6.5 enc / 4.7 dec against the
  published 15.07 / 9.77. `comparison.csv`, `streaming_budget.csv`, the FAQ table
  and `rgb1-format.md`'s stream row are all regenerated or corrected.
- **5. 所有已發表的計時數字都高了 2.3 倍。** `comparison.csv` 的日期 08-13 14:06 早於
  `413cd82`（行程內 libzstd、`-n`）、`3e67760` 與 `4dc9510`（QoS）、`25e1759`（攤平移出
  計時區）。以現行二進位對同樣三格重跑得 6.5 enc／4.7 dec，對照已發表的 15.07／9.77。
  `comparison.csv`、`streaming_budget.csv`、FAQ 表與 `rgb1-format.md` 的串流列皆已重生成
  或更正。
- **6. The FAQ's "1 GbE at 86% / 101%" were MB/s, not percentages.** 689 ÷ 8 =
  86.1 and 809 ÷ 8 = 101.1, copied across as a utilisation ratio. Against the
  118 MB/s `build_streaming_budget.py` uses, NV12 is 74% and the predictive stack
  86% — the old table both overstated NV12's pressure and wrongly showed the
  predictive stack overflowing the link.
- **6. FAQ 的「1 GbE at 86%／101%」是 MB/s 而非百分比。** 689 ÷ 8 = 86.1、809 ÷ 8 =
  101.1，被當成佔用率抄了過來。以 `build_streaming_budget.py` 採用的 118 MB/s 為分母，
  NV12 為 74%、預測式堆疊為 86%——舊表既誇大 NV12 對線路的壓力，也錯誤地顯示預測式
  堆疊塞不進去。
- **7. `build_streaming_budget.py` had been silently unrunnable.** It matched
  P6-DOE's output on the exact label `3 plane textures (planar)`, which is now
  `3 planes, RGB order (ours)`, so it exited 1 on every invocation. Its own
  docstring claims the table "cannot drift away from the measurements it claims
  to summarise" — it had. Now matched on the row prefix and the trailing numbers.
- **7. `build_streaming_budget.py`早已靜默地無法執行。** 它以完全相符的標籤
  `3 plane textures (planar)` 比對 P6-DOE 輸出，而該標籤現為
  `3 planes, RGB order (ours)`，故每次執行皆 exit 1。其自身的 docstring 宣稱該表
  「不會與其所摘要的量測結果脫節」——事實上早已脫節。現改以列前綴與末尾數字比對。
- **9. The decode reference is now kept as bands, not a reassembled frame.**
  `Array(out.joined())` cost a 6.2 MB allocation and copy per 1080p frame inside
  the timed region, and after the first fix only `--delta` and `--verify` paid it
  — which left a `--delta` arm uncomparable against any other arm on decode time,
  the same class of contamination as finding A. The next frame's reference is now
  the band array the decoder just produced, so keeping it is a retain, not a copy;
  only `--verify` reassembles, and every arm pays that equally. Fixing it exposed
  a second defect: the delta guard compared byte counts, but 64x48 and 48x64 are
  both 9216 B and slice into different band layouts, so at `--slices 3` the two
  sides disagreed and trapped (exit 133). Both guards now compare width and
  height. `mixed_size_delta.zsh` covers it, and traps against a binary with the
  guard weakened back to a size comparison.
- **9. 解碼端的參考改以列帶保留，不再重組整格。**
  `Array(out.joined())` 使 1080p 每格在計時區內多付 6.2 MB 的配置與複製，而第一次修正
  後只剩 `--delta` 與 `--verify` 要付——這使 `--delta` 組的解碼時間無法與任何其他組別
  相比，與 finding A 屬同一類汙染。下一格的參考現在就是解碼端剛產出的列帶陣列，保留
  它只是 retain 而非複製；僅 `--verify` 會重組，且所有組別付出相同代價。修正過程中另
  發現一項缺陷：差分守門原本比對位元組數，但 64x48 與 48x64 皆為 9216 B 且切出不同的
  列帶佈局，故在 `--slices 3` 下兩端分歧並崩潰（exit 133）。兩端守門現皆比對寬與高。
  `mixed_size_delta.zsh` 已涵蓋此情境，且對「守門退回僅比對大小」的二進位會觸發崩潰。
- **8. The corpus itself was the wrong shape.** Every row of the FAQ bandwidth
  table now comes from one 48-frame consecutive corpus
  (`make_consecutive_corpus.zsh`, t=121.2 s), replacing a mix of 8 consecutive
  frames and 24 frames sampled 10 s apart — the latter still containing the fade
  frame, and compressing ~11% better than consecutive footage.
- **8. 語料本身的形狀就不對。** FAQ 頻寬表每一列現在都來自同一份 48 格連續語料
  （`make_consecutive_corpus.zsh`，t=121.2 秒），取代原本「8 格連續 + 相隔 10 秒的
  24 格」的混用——後者不但仍含淡入那格，且較連續影格好壓約 11%。

- **10. Batching does inflate the ratio for xz on NV12: +21.27%, not +0.34%.**
  `nv12_vs_rgb1_streaming.zsh` had no `-ss` and had been reading the clip's
  fade-from-black opening since it was written — the same defect as the 122 Mbps
  bitrate figure, missed when that one was fixed. Re-run from t=121.2 s over 48
  frames, the whole table moves and one conclusion inverts: NV12 compresses
  better than RGB1 under every codec, so the wire gap is 2.14x rather than the
  recorded 1.73x, and the claim it had been cited as refuting was right.

  The batching result is the sharper correction. xz's default dictionary is
  8 MiB against a 3.11 MB NV12 frame — 2.70 frames fit, so it reuses the
  previous frame outright. The window argument never covered that case: it was
  stated for zstd (1 MiB), gzip (32 KiB) and lz4 (64 KiB), all of which look
  back less than one frame, and xz was folded in on the strength of a t=0
  measurement where everything compressed to ~5% and the gap was invisible. The
  reviewer's original concern in #2 — that batching lets a codec dedup across
  frames and understates a per-frame bitrate — is correct for xz on NV12.

  The script now derives that verdict from the run instead of printing it as
  prose: it tabulates each codec's dictionary against one frame and says which
  rows can reuse a neighbour. The old text asserted "at most 0.34%" and "batch
  figures are safe to quote", and printed both verbatim in the run that measured
  +21.27%.
- **10. 批次確實會灌大 xz 對 NV12 的比率：+21.27%，而非 +0.34%。**
  `nv12_vs_rgb1_streaming.zsh` 自撰寫以來就沒有 `-ss`，一直讀著片頭的自黑畫面淡入
  ——與 122 Mbps 那個位元率數字是同一個缺陷，且在修正該數字時被漏掉。改自 t=121.2 秒
  取 48 格重跑後，整張表都變了，其中一項結論翻轉：四種 codec 下 NV12 都比 RGB1 更
  好壓，故線路差距為 2.14x 而非原記的 1.73x，而它原本被引用來反駁的說法其實是對的。

  批次那項更正更為關鍵。xz 的預設字典為 8 MiB，對上 3.11 MB 的 NV12 影格——可容納
  2.70 格，因而直接重用前一格。視窗論證從來就沒有涵蓋該情形：它是針對
  zstd（1 MiB）、gzip（32 KiB）、lz4（64 KiB）而言，三者回看範圍皆小於單格，而 xz 是
  憑一次 t=0 量測（當時所有東西都壓到約 5%，差距根本看不出來）被一併歸入。該 review
  在 #2 提出的原始疑慮——批次讓 codec 跨格去重，因而低估每格位元率——對 xz/NV12 成立。

  腳本現已改為由執行結果推導該判定，而非以文字印出：它會列出各 codec 字典相對單格
  的大小，並指出哪幾列能重用鄰格。舊文字斷言「最大 0.34%」與「批次數字可安心引用」，
  而在量到 +21.27% 的那次執行中，兩句依然被原樣印出。

Defensive hygiene, 2026-08-14 / 防禦性衛生:

- **`log()` shadowed a zsh builtin in `compile_tar-linux.sh`; renamed to
  `log_msg()`.** `log` is a zsh builtin, and a function shadows it only from the
  point of definition — a call placed above the definition resolves to the
  builtin, which rejects any argument with `zsh:log:1: too many arguments` and
  returns 1. Under that script's `set -euo pipefail` this aborts the build with
  a message pointing at zsh rather than at the missing definition. All eleven
  call sites were already below the definition, so nothing was broken; the
  rename removes the trap rather than documenting it. Verified by rebuilding in
  the VM: `BUILD_RC=0`, no `too many arguments`. No other script in the tree
  defines `log()`, and `die()` is not a builtin.
- **`compile_tar-linux.sh` 的 `log()` 遮蔽了 zsh builtin，已改名為 `log_msg()`。**
  `log` 是 zsh 的 builtin，而函式只從定義處起遮蔽它——位於定義之上的呼叫會解析到
  builtin，後者收到任何參數都會以 `zsh:log:1: too many arguments` 拒絕並回傳 1。在該
  腳本的 `set -euo pipefail` 下，這會讓建置中止，且訊息指向 zsh 而非「函式尚未定義」。
  11 個呼叫點原本都在定義之下，故並未實際出錯；改名是為了移除陷阱，而非替它寫註解。
  已於 VM 重新建置驗證：`BUILD_RC=0`，無 `too many arguments`。程式庫中沒有其他腳本
  定義 `log()`，而 `die` 並非 builtin。
- **`nv12_vs_rgb1_streaming.zsh` truncated its committed record before knowing
  the run was viable.** `exec > >(tee "$OUTPUT")` sat near the top, so the output
  file was emptied at startup and any early failure destroyed the previous
  measurement. Found while testing the new frame-count guard: one deliberately
  bad `START` replaced a 77-line record with a 12-line error log. The redirect
  now happens after the frame-count check, so the record is only opened for a run
  that has the frames it asked for. Verified both paths: a bad `START` errors and
  leaves the committed file byte-identical.
- **`nv12_vs_rgb1_streaming.zsh` 會在確認執行可行之前就截斷入版紀錄。**
  `exec > >(tee "$OUTPUT")` 原本位於檔案上方，故輸出檔在啟動時即被清空，任何早期失敗
  都會毀掉上一份量測。此問題於測試新增的影格數守門時發現：一次刻意設錯的 `START` 就把
  77 行的紀錄換成 12 行的錯誤訊息。重導現已改至影格數檢查之後，故只有取得所要求影格數的
  執行才會開啟該紀錄。兩條路徑皆已驗證：錯誤的 `START` 會報錯，且入版檔案位元組完全未變。

- **The streaming DOE inherited swift_tar's zstd default, which moved from 3 to
  9 on 2026-08-14 (`a5ac4a8`).** `nv12_vs_rgb1_streaming.zsh` invoked bare
  `--zstd`, so every zstd figure in its output and in `rgb1/FAQ.md` would have
  silently re-based onto a different level while the rows still read "zstd". Both
  call sites now pass `--zstd-level 3`, matching `batch_vs_per_frame.zsh` and
  `consecutive_bitrate.zsh`, and the level is printed in the output header.
  Re-run against the new binary, all ten ratios reproduce exactly — which is also
  the payoff for having moved the FAQ table off byte counts and onto ratios.

  The first attempt at pinning was worse than not pinning: it probed
  `swift_tar --help` for the flag and omitted it when absent. swift_tar's
  `--help` exits with "specify exactly one of -c, -x, ..." and never lists
  options, so the probe always failed and the fallback would have measured the
  new default of 9 while labelling it 3. The flag is now passed unconditionally.

  Still unpinned elsewhere: `encrypt_mbps_rss.sh`, `encrypt_mbps_win.sh`,
  `bsdtar_compat.sh`, `test_no_lzfse.sh`, `test_encrypt.sh`. The correctness
  tests are unaffected by the level; `encrypt_mbps_rss.sh` reports MB/s and will
  move. Not addressed here.
- **串流 DOE 沿用了 swift_tar 的 zstd 預設值，而該預設已於 2026-08-14（`a5ac4a8`）
  由 3 改為 9。** `nv12_vs_rgb1_streaming.zsh` 呼叫的是裸 `--zstd`，故其輸出與
  `rgb1/FAQ.md` 中的每個 zstd 數字都會靜默地換基準到另一個等級，而各列仍只寫著
  「zstd」。兩個呼叫點現皆傳入 `--zstd-level 3`，與 `batch_vs_per_frame.zsh`、
  `consecutive_bitrate.zsh` 一致，並將等級印入輸出檔頭。以新二進位重跑後，十個比率
  全數完全重現——這也正是先前把 FAQ 表格由位元組改為比率所換得的回報。

  第一版的釘法比不釘更糟：它探測 `swift_tar --help` 是否列出該旗標，找不到就不傳。
  但 swift_tar 的 `--help` 會以「specify exactly one of -c, -x, ...」結束，從不列出
  選項，故該探測必然失敗，而退回路徑會以新預設值 9 量測卻標示為 3。現已改為無條件傳入。

  其他仍未釘住的腳本：`encrypt_mbps_rss.sh`、`encrypt_mbps_win.sh`、
  `bsdtar_compat.sh`、`test_no_lzfse.sh`、`test_encrypt.sh`。正確性測試不受等級影響；
  `encrypt_mbps_rss.sh` 回報的是 MB/s，會隨之變動。本次未處理。

- **Test scripts aligned with zstd -9 (2026-08-15).** With the default at 9, a
  bare `--zstd` already produces level 9 — the problem was that nothing said so,
  and the committed numbers had been recorded at 3. `test_swift_tar_rgb1.sh`,
  `encrypt_mbps_rss.sh` and `encrypt_mbps_win.sh` now pass `--zstd-level 9`
  explicitly. All three took the codec flag as a single quoted argument, so each
  helper was changed to split it into an array first (`read -r -a` in bash,
  `${=2}` in zsh); a level cannot be pinned otherwise.

  Re-measured. `test_swift_tar_rgb1.sh`: the zstd row goes 4,567 -> 4,555 B.
  `encrypt_mbps_rss.sh` on the 1.4 GB corpus: **433,753,307 -> 401,152,357 B, a
  7.52% reduction**.

  Throughput is *not* attributable to the level: zstd create reads 1541.76 ->
  531.44 MB/s across the two runs, but plain-tar create also moved 550.20 ->
  1389.11 MB/s in the same pair, and plain tar has no zstd in it at all. The
  previous record is from 2026-08-05 on a binary ten days older; only the archive
  sizes isolate the level cleanly.

  One near-miss worth recording. `bench()` in `test_swift_tar_rgb1.sh` uses
  `flag` twice, and the first pass only fixed the creation call. The timing loop
  is `... && "$ST" -c "$flag" ... || "$ST" -c -f ...`, so a malformed argument
  would have fallen through to plain tar and reported plain-tar timings under the
  zstd label. Caught because 4,555 B is not 3,148,288 B.

  Left alone deliberately: `test_encrypt.sh`, `test_no_lzfse.sh`,
  `bsdtar_compat.sh` and `encrypt_windows_correctness.sh` assert round-trip
  equality, which no level changes. `nv12_vs_rgb1_streaming.zsh` stays pinned at
  **3**, because its two companion scripts call the zstd CLI at -3 and the FAQ
  section it feeds concludes "-3 for streaming, -19 for archiving"; moving that
  one study to 9 would contradict its own argument and needs all three scripts
  plus the FAQ moved together.

  `encrypt_mbps_win_output.txt` still holds level-3 numbers. The script is pinned
  but only the Windows side can re-run it, so the gap is now explicit rather than
  silent.
- **測試腳本對齊 zstd -9（2026-08-15）。** 預設已是 9，故裸 `--zstd` 本來就會產生等級
  9——問題在於沒有任何地方載明，而入版數字是在等級 3 下錄的。`test_swift_tar_rgb1.sh`、
  `encrypt_mbps_rss.sh` 與 `encrypt_mbps_win.sh` 現皆明確傳入 `--zstd-level 9`。三者
  原本都把 codec 旗標當作單一引號參數，故各自的 helper 都改為先拆成陣列（bash 用
  `read -r -a`，zsh 用 `${=2}`）；否則根本無法釘住等級。

  已重新量測。`test_swift_tar_rgb1.sh`：zstd 列由 4,567 變為 4,555 B。
  `encrypt_mbps_rss.sh` 於 1.4 GB 語料：**433,753,307 → 401,152,357 B，減少 7.52%**。

  吞吐量*不可*歸因於等級：兩次執行間 zstd create 由 1541.76 變為 531.44 MB/s，但同一
  組對照中 plain-tar create 也由 550.20 變為 1389.11 MB/s，而純 tar 根本不含 zstd。
  前一份紀錄錄於 2026-08-05、二進位早了十天；能乾淨隔離出等級影響的只有封存大小。

  一個值得記下的險些出錯。`test_swift_tar_rgb1.sh` 的 `bench()` 用到 `flag` 兩次，而
  第一次只改了建立那處。計時迴圈寫作 `... && "$ST" -c "$flag" ... || "$ST" -c -f ...`，
  參數格式錯誤會落到 `||` 而以純 tar 執行，並把純 tar 的計時掛在 zstd 標籤下回報。
  之所以發現，是因為 4,555 B 不是 3,148,288 B。

  刻意未動：`test_encrypt.sh`、`test_no_lzfse.sh`、`bsdtar_compat.sh` 與
  `encrypt_windows_correctness.sh` 斷言的是往返一致，任何等級都不影響。
  `nv12_vs_rgb1_streaming.zsh` 維持釘在 **3**，因為其兩支姊妹腳本以 `-3` 呼叫 zstd CLI，
  且它所支撐的 FAQ 一節結論正是「串流用 -3、封存用 -19」；單獨把該研究改成 9 會與其
  自身論證矛盾，需三支腳本連同 FAQ 一併調整。

  `encrypt_mbps_win_output.txt` 仍是等級 3 的數字。腳本已釘住，但只有 Windows 端能重跑，
  故該落差現在是明確可見而非靜默存在。

Follow-up / 後續:

- Compile and smoke-test the RGB1 CLI operations.
- 編譯並 smoke-test RGB1 CLI operations。
- Add stdin support for `--rgb1-info` and `--rgb1-raw`.
- 為 `--rgb1-info` 與 `--rgb1-raw` 加入 stdin 支援。
- Define the stream-level container for keyframe + diff stepping on top of
  RGB1 frames.
- 在 RGB1 frame 之上定義 keyframe + diff stepping 的 stream-level container。
