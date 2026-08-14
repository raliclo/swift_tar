# FAQ

Notes from ad-hoc design questions about the RGB1 format and downstream
display pipeline (P6). Not exhaustive — see `rgb1-format.md` and
`../rgba_vs_rgb1.md` for the primary format docs.

關於 RGB1 格式與下游顯示 pipeline(P6)的臨時設計問答筆記。非完整文件——
主要格式文件請見 `rgb1-format.md` 與 `../rgba_vs_rgb1.md`。

## NV12 vs RGB1

**Q: How does NV12 compare to RGB1?**
**Q: NV12 與 RGB1 相比如何？**

| | NV12 | RGB1 |
|---|---|---|
| Color model / 色彩模型 | YUV 4:2:0, Y plane + interleaved half-res UV plane | RGB, 8-bit R/G/B per pixel |
| Bytes/pixel | ~1.5 (12 bits) | 3 (24 bits) |
| 4K (3840x2160) frame size | ~12.44 MB | ~24.88 MB (+876 byte header) |
| Metadata | none (pixel format only) | fixed header: lat/lng/height, title, country, creator email, timezone |
| Typical source | hardware video decoders (VideoToolbox/Media Foundation), video encoders | this project's custom single-frame storage container |
| Needs conversion to display | yes, YUV->RGB (shader or CPU) | yes, RGB->RGBA (see `../rgba_vs_rgb1.md`) |
| Compression friendliness | good for video codecs (chroma subsampling already exploits eye insensitivity to chroma) | general-purpose compressors (zstd) don't get the same win from raw RGB |

NV12 is roughly half the size of RGB1 per pixel (4:2:0 chroma subsampling)
and is the native output format of hardware video decoders, so it fits a
continuous video-stream pipeline. RGB1 is a general single-frame snapshot
container with fixed geo/creator metadata; it has no chroma subsampling and
no hardware-native producer/consumer. Which one is the right "long-term
display path" (per the open follow-up in `rgb1-format.md`) depends on
whether the target is single snapshots (RGB1 is sufficient and simpler) or
a continuous 4K60 video stream (NV12 is the closer fit).

NV12 每像素體積約為 RGB1 的一半（4:2:0 色度取樣），且是硬體視訊解碼器的
原生輸出格式，適合連續視訊串流的 pipeline。RGB1 是通用的單張快照容器，
帶固定地理／建立者 metadata，沒有色度取樣，也沒有硬體原生的產生／消費端。
究竟哪個才是「長期顯示路徑」（`rgb1-format.md` 的待決 follow-up）
取決於目標是單張快照（RGB1 已足夠且較簡單）還是連續 4K60 視訊串流
（NV12 更貼合）。

## Would NV12 support in Metal speed up rendering?

## Metal 支援 NV12 會加速渲染嗎？

**Q: Does NV12 support on Metal help speed up Metal rendering?**
**Q: Metal 支援 NV12 格式是否有助於加速 Metal 渲染？**

Yes, generally — provided the upstream pipeline is also changed to stop
converting to RGBA before handing frames to Metal. The gain comes from
three places:

一般來說會，前提是上游 pipeline 也要跟著改，不要在交給 Metal 前先轉成
RGBA。加速主要來自三個地方：

1. **Skips a full-frame YUV->RGB conversion pass.** Hardware decoders
   (VideoToolbox) natively output NV12 (BiPlanar 420v/420f) `CVPixelBuffer`s.
   The current pipeline (`ffmpeg -> RGBA frame -> Metal/WinUI`, per
   `../rgba_vs_rgb1.md`) already pays for a YUV->RGB conversion inside ffmpeg.
   If Metal consumes NV12 directly and does the YUV->RGB matrix multiply in
   a fragment shader, that conversion pass (and its extra full-frame
   read+write) disappears from the CPU/pre-GPU path entirely.
   跳過一次整張影格的 YUV→RGB 轉換。硬體解碼器（VideoToolbox）原生輸出就是
   NV12（BiPlanar 420v/420f）的 `CVPixelBuffer`。目前的 pipeline
   （`ffmpeg -> RGBA frame -> Metal/WinUI`，見 `../rgba_vs_rgb1.md`）已經在
   ffmpeg 內部付出一次 YUV→RGB 轉換的成本。若 Metal 直接吃 NV12，把
   YUV→RGB 矩陣運算搬到 fragment shader 做，這段轉換（含額外一次整張影格
   的讀寫）就從 CPU/GPU 前處理路徑上完全消失。

2. **~2.7x less data to move.** NV12 is ~1.5 bytes/pixel vs RGBA's 4
   bytes/pixel (and the alpha channel is always wasted for video content
   with no transparency). Less data uploaded to the GPU and sampled by the
   shader means less memory-bandwidth pressure, which matters more at 4K/60.
   要搬移的資料量少約 2.7 倍。NV12 約每像素 1.5 bytes，RGBA 是 4
   bytes（且視訊內容沒有透明度，alpha 通道永遠是浪費）。上傳到 GPU 與
   shader 取樣的資料量都變少，記憶體頻寬壓力隨之下降，在 4K/60 這種情境下
   影響更明顯。

3. **Possible zero-copy texture creation.** With `CVMetalTextureCache`, a
   decoder's NV12 `CVPixelBuffer` (IOSurface-backed) can be wrapped directly
   as two Metal textures (Y as `r8Unorm`, UV as `rg8Unorm`) with no CPU
   memcpy at all — the GPU reads the decoder's own output buffer. This path
   does not exist once ffmpeg has already flattened the frame to RGBA.
   有機會做到零拷貝紋理建立。透過 `CVMetalTextureCache`，解碼器輸出的
   NV12 `CVPixelBuffer`（IOSurface-backed）可以直接包成兩張 Metal 紋理
   （Y 用 `r8Unorm`、UV 用 `rg8Unorm`），完全不需要 CPU memcpy——GPU
   直接讀解碼器自己的輸出 buffer。一旦 ffmpeg 已經把影格攤平成 RGBA，這條
   路徑就不存在了。

**Caveats / 注意事項:**
- The shader must apply the correct YUV->RGB matrix (BT.601/BT.709/BT.2020)
  and range (video vs full) or colors will be off — cheap on the GPU, but
  easy to get wrong.
  shader 必須套用正確的 YUV→RGB 矩陣（BT.601/BT.709/BT.2020）與範圍
  （video range 或 full range），否則顏色會偏——GPU 運算成本低，但容易寫錯。
- The actual win requires changing ffmpeg's output format to NV12 (stop its
  internal RGBA conversion); "Metal supports NV12" alone does nothing if the
  frame arriving at Metal is already RGBA.
  真正的效益需要把 ffmpeg 的輸出格式改成 NV12（停用它內部的 RGBA
  轉換）；如果送到 Metal 的影格已經是 RGBA，「Metal 支援 NV12」本身不會
  帶來任何好處。
- If other layers (UI overlays) are composited on top and need alpha, those
  stay as separate RGBA textures — this only changes how the video layer
  itself is read.
  如果還有其他圖層（UI 疊加）需要 alpha 合成，那些仍維持獨立的 RGBA
  紋理——這項改動只影響視訊圖層本身的讀取方式。

## Which transfers less over the wire, NV12 or RGB1?

## 傳輸時 NV12 與 RGB1 誰比較小？

**Q: RGB1 compresses well with zstd — does that close the 2x size gap?**
**Q: RGB1 用 zstd 壓得不錯——這能弭平 2 倍的大小差距嗎？**

No. Measured on real video frames (1920x1080, 8 frames from the P6 test app's
real-programme sample, VP9 + Opus) with
`../verifications/rgb1/nv12_vs_rgb1_streaming.zsh`:

不能。以真實視訊影格實測（1920x1080，取自 P6 測試程式的真實節目樣本，
VP9 + Opus 的 8 格），腳本為 `../verifications/rgb1/nv12_vs_rgb1_streaming.zsh`：

| codec | NV12 | RGB1 payload | RGB1 ratio | NV12 ratio |
|---|---:|---:|---:|---:|
| zstd | 2,040,441 | 3,521,027 | **7.08%** | 8.20% |
| gzip | 1,974,514 | 3,351,184 | **6.73%** | 7.94% |
| lz4 | 3,511,405 | 6,002,134 | **12.06%** | 14.11% |
| xz | 1,409,388 | 2,351,780 | **4.73%** | 5.66% |

> **This table is still t=0, and both conclusions below fail on real content.
> Flagged 2026-08-14.** The 7% ratios are the tell — the same fade-from-black
> opening that put 122 Mbps in the bitrate table. `nv12_vs_rgb1_streaming.zsh`
> has not yet been re-run with mid-video sampling, so these rows were missed when
> the bitrate table was corrected. Recomputed from `batch_vs_per_frame_output.txt`
> (t=121.2 s) and the raw frame sizes 1920x1080x1.5 and x3:
>
> | source | NV12 ratio | RGB1 ratio | RGB1 / NV12 |
> |---|---:|---:|---:|
> | t=0 (this table) | 8.20% | **7.08%** | 1.73x |
> | consecutive, mid-video | **46.16%** | 49.21% | **2.13x** |
> | sampled, 10 s apart | **41.40%** | 43.71% | **2.11x** |
>
> **The ordering reverses.** On real content NV12 compresses *better* than RGB1
> (46.16% vs 49.21%), so "RGB1 wins under every codec" is an artifact of the
> fade, and the statement it was cited as refuting — that a general-purpose
> compressor gets less out of raw RGB — was right after all. The wire gap is
> **2.13x, not 1.73x**: the ratio does not narrow the 2.00x starting gap, it
> widens it.
>
> Only zstd -3 has mid-video data. **The gzip, lz4 and xz rows should not be
> quoted** until the script is re-run. Raised in review by the Windows-side
> reader.
>
> **本表仍為 t=0，其下兩項結論在真實內容上皆不成立。2026-08-14 標記。**
> 7% 的壓縮率就是線索——正是那段把 122 Mbps 送進位元率表的自黑畫面淡入。
> `nv12_vs_rgb1_streaming.zsh` 尚未以中段取樣重跑，故位元率表更正時漏掉了這幾列。
> 以 `batch_vs_per_frame_output.txt`（t=121.2 秒）與原始影格大小
> 1920x1080x1.5、x3 重算，結果如上表。
>
> **高下順序反轉。** 在真實內容上 NV12 壓得*比* RGB1 好（46.16% 對 49.21%），
> 故「RGB1 在每個 codec 下都較好」是淡入造成的假象；而它所推翻的那句話——通用
> 壓縮器對 raw RGB 得不到同樣效益——反而才是對的。線路上的差距是 **2.13 倍而非
> 1.73 倍**：較佳的壓縮率並未縮小 2.00 倍的起點差距，而是把它拉大。
>
> 目前僅 zstd -3 有中段數據。**gzip、lz4、xz 三列在腳本重跑之前不應引用。**
> 此問題由 Windows 端讀者於 review 中提出。

RGB1 compresses *better than* NV12 under **every** codec tested (7.08% vs 8.20%
for zstd; the same holds for gzip, lz4 and xz), so the earlier claim above that
"general-purpose compressors don't get the same win from raw RGB" is not
accurate — the opposite is true. But RGB1 starts at 2x the size, so after
compression it still needs **1.73x the bytes on the wire**; the better ratio
narrows the gap from 2.00x but does not close it.
*(Superseded — holds only at t=0. 本段已被上方取代，僅在 t=0 成立。)*

在測試的**每一個** codec 下，RGB1 的壓縮率都**優於** NV12（zstd 為 7.08% 對
8.20%，gzip、lz4、xz 亦然），因此上文「通用壓縮器對 raw RGB 得不到同樣效益」
的說法並不準確——事實正好相反。但 RGB1 起點大 2 倍，壓縮後傳輸量仍是
**NV12 的 1.73 倍**；較佳的壓縮率把差距從 2.00 倍縮小，但無法弭平。

Render prep (converting to the `Image<RGBA>` that P6 hands to Metal) is close
enough to be noise: 0.068 s for RGB1 versus 0.061 s for NV12 over 8 frames on
this source, and the ordering reversed on a different clip. Both are ~1 GB/s,
so neither format has a meaningful CPU-side conversion advantage. This excludes
GPU shader time; if the YUV->RGB matrix moves into a fragment shader (see
above), NV12 gains.

Render prep（轉成 P6 交給 Metal 的 `Image<RGBA>`）兩者差距已在雜訊範圍：本素材
8 格為 RGB1 0.068 秒對 NV12 0.061 秒，而在另一支影片上順序相反。兩者皆約
1 GB/s，因此在 CPU 端的轉換成本上沒有任何一方具實質優勢。此量測不含 GPU
shader 時間；若 YUV→RGB 矩陣移進 fragment shader（見上文），NV12 更佔優。

> **Caveat**: measured on one 1080p programme clip (talking-head content, low
> motion). Game footage has much higher entropy and both ratios will be worse.
> Synthetic patterns (`ffmpeg testsrc2`) compress to ~3% and make the two
> formats look equally compressible — do not benchmark with them.
> **注意**：僅以一支 1080p 節目影片量測（人物講述、低動態）。遊戲畫面熵值高得
> 多，兩者壓縮率都會變差。合成圖案（`ffmpeg testsrc2`）會壓到約 3%，讓兩種格式
> 看起來同樣可壓縮——請勿用它做基準測試。

## Can we do VP9-style inter-frame compression ourselves?

## 我們能自己做 VP9 式的影格間壓縮嗎？

**Q: Could the converter compress across frames like VP9 does?**
**Q: converter 能像 VP9 那樣做影格間壓縮嗎？**

A simple frame delta is cheap and helps a little; matching VP9 is not realistic.
Measured on the same 8 RGB24 frames:

簡單的影格差分成本低、略有幫助；但要達到 VP9 的水準並不實際。以相同的 8 格
RGB24 實測：

| method | bytes | % of raw | kind |
|---|---:|---:|---|
| independent frames + zstd | 3,509,790 | 7.05% | lossless |
| **frame delta + zstd** | **3,260,525** | **6.55%** | lossless |
| frame XOR + zstd | 4,068,581 | 8.18% | lossless |
| x264 lossless (qp 0) | 3,026,945 | 6.08% | lossless |
| FFV1 level 3 | 1,922,856 | 3.86% | lossless |
| VP9 (same 8 frames, 2300k) | 31,519 | 0.06% | **lossy** |

> **"independent frames" really is independent, verified 2026-08-14.** These
> rows come from compressing the 8 frames as one stream, which in principle
> lets the codec dedup across frames — a bonus no real-time sender could claim,
> since it cannot wait for eight frames or reference one it has not sent yet.
> Two scripts measure this. `batch_vs_per_frame.zsh` covers zstd -3 across
> two frame sources (consecutive and 10 s-sampled) and reports a penalty of
> **−0.1% to 0.0%**; `nv12_vs_rgb1_streaming.zsh --both` extends the same
> comparison to all five codecs and finds **at most 0.34%** (rgb24/xz — the
> largest dictionary, hence the largest gap; zstd stays within ±0.18%). About
> 0.04% of even that is per-frame tar headers rather than compression. The reason is window size — one 1080p
> frame is 3.1 MB (NV12) or 6.2 MB (RGB24), more than zstd, gzip or lz4 can look
> back across, so they never reference the previous frame at all. The batch
> figures above and the bitrates below are therefore safe as per-frame numbers.
> This would need re-checking at a resolution low enough for a frame to fit
> inside a codec's window.
>
> **「independent frames」確實獨立，2026-08-14 實測確認。** 上表各列是把 8 格壓成
> 單一串流所得，原則上讓 codec 有機會跨格去重——而那是任何即時傳送端都無法主張的
> 紅利，因為它不可能等滿八格，也無法參照尚未送出的影格。
> 有兩支腳本量測此事：`batch_vs_per_frame.zsh` 以 zstd -3 涵蓋兩種影格來源
> （連續與相隔 10 秒取樣），回報 penalty 為 **−0.1% 至 0.0%**；
> `nv12_vs_rgb1_streaming.zsh --both` 則把同一比較延伸到全部五種 codec，
> 實測**最多 0.34%**（rgb24／xz——字典最大，差距因而最大；zstd 維持在 ±0.18%
> 內）。且其中約 0.04% 還只是每格的 tar header，與壓縮無關。原因在視窗大小——單張 1080p
> 影格為 3.1 MB（NV12）或 6.2 MB（RGB24），超出 zstd、gzip、lz4 的回看範圍，因此
> 它們根本不曾參照前一格。故上表的批次數字與下文的位元率，作為每格數值皆可安心
> 引用。若解析度低到單格能放進 codec 視窗，則須重新檢查。

A byte-wise delta against the previous frame costs a few dozen lines, but on this
source it only saves **7.1%** (3,509,790 -> 3,260,525). An earlier measurement on
a different clip showed 25%, so the benefit is highly content-dependent: it pays
off when consecutive frames are nearly identical and collapses when they are not.
XOR is worse than plain subtraction here (8.18% vs 6.55%), and FFV1 — a mature
lossless codec with context modelling and a range coder — still beats the delta
by 1.70x.

對前一格做逐位元組差分只需數十行程式碼，但在本素材上僅省下 **7.1%**
（3,509,790 → 3,260,525）。先前在另一支影片上量到 25%，可見其效益高度依賴內容：
相鄰影格幾乎相同時才有回報，否則效益立刻消失。此處 XOR 比單純相減更差
（8.18% 對 6.55%），而 FFV1（成熟的無損 codec，具 context modelling 與 range
coder）仍勝過差分 1.70 倍。

The remaining gap to VP9 is **103x** (3,260,525 vs 31,519), and it is not an
implementation-quality gap — it is the lossy/lossless boundary. VP9 additionally
does motion compensation (so a moving object produces near-zero residual instead
of a large delta), transform + quantisation (which *discards* high-frequency
detail), and context-adaptive entropy coding. Quantisation is where almost all of
the 103x comes from, and a lossless path cannot do it by definition. Even FFV1,
the best lossless result here, is still 61x larger than VP9.

與 VP9 之間剩下的 **103 倍**差距（3,260,525 對 31,519），並非實作品質問題，而是
有損／無損的分界。VP9 另外做了 motion compensation（使移動物體產生接近零的殘差，
而非大量差分值）、transform + 量化（**丟棄**高頻細節），以及 context-adaptive
entropy coding。這 103 倍幾乎全部來自量化這一步，而無損路徑在定義上無法做這件
事。即使是此處最佳的無損結果 FFV1，仍比 VP9 大 61 倍。

## What should a 60 fps game stream actually transfer?

## 60 fps 遊戲串流實際上該傳什麼？

**Q: Given the above, what is the right wire format for 1080p60 gaming?**
**Q: 綜合以上，1080p60 遊戲串流的正確傳輸格式是什麼？**

Two constraints apply at once: link bandwidth, and the **16.67 ms per-frame
budget**. Measured per-frame encode cost on the same clip:

有兩個約束同時成立：連線頻寬，以及**每格 16.67 ms 的預算**。以相同影片實測的
每格編碼耗時：

| method | Mbps @60fps | of 1 GbE | ms/frame | verdict |
|---|---:|---:|---:|---|
| RGB24 raw | 2986 | 316% | 0 | bandwidth fails |
| NV12 raw | 1493 | 158% | 0 | bandwidth fails |
| **NV12 + zstd-3** | **694** | **74%** | — | **fits both** |
| RGB24 + zstd-3 | 1482 | 157% | 3.2 enc / 0.8 dec | exceeds 1 GbE |
| RGB1 predictive + zstd-3 | 813 | 86% | 6.5 enc / 4.6 dec | fits both, no room for a second stream |
| FFV1 | 587 | 62% | 22.8 | over compute budget |
| x264 lossless | — | — | 64.2 | over compute budget |
| hardware lossy (VideoToolbox / VP9) | ~2-10 | <1% | see note | the only internet-capable option |

Every row above is measured on the **same 48 consecutive frames from t=121.2 s**
of the source clip (`verifications/rgb1/sample_consecutive`, built by
`make_consecutive_corpus.zsh`). Provenance by column: bandwidth for the two zstd
rows from `consecutive_bitrate.zsh`, for the predictive row from
`comparison.csv`, for FFV1 from `ffv1_vp9_vs_predictive_output.txt`; timings from
`comparison.csv` at 20 slices and `-n 20`. "of 1 GbE" is against **118 MB/s**,
the practical-gigabit figure `build_streaming_budget.py` uses. NV12 has no RGB1
container so it has no timing row — it is the same codec on two-thirds the bytes
of the RGB24 row. FFV1's 22.8 ms and x264's 64.2 ms are older figures, not
re-measured on this corpus. The two zstd rows compress each frame whole; the
predictive row compresses 20 row bands separately, which costs ~3% more bytes and
buys the parallelism that puts it inside the budget at all.

上表每一列皆量測於來源影片 **t=121.2 秒起的同一批 48 格連續影格**
（`verifications/rgb1/sample_consecutive`，由 `make_consecutive_corpus.zsh` 產生）。
各欄出處：兩個 zstd 列的頻寬來自 `consecutive_bitrate.zsh`，predictive 列來自
`comparison.csv`，FFV1 來自 `ffv1_vp9_vs_predictive_output.txt`；計時皆取自
`comparison.csv` 的 20 slices、`-n 20`。「of 1 GbE」的分母為 **118 MB/s**，即
`build_streaming_budget.py` 所採用的實務 gigabit 值。NV12 沒有 RGB1 容器，故無計時
列——它是同一個編碼器作用在 RGB24 列三分之二的位元組上。FFV1 的 22.8 ms 與 x264 的
64.2 ms 為較早的數字，並未在本語料上重測。兩個 zstd 列為整格壓縮；predictive 列則
將 20 條列帶分別壓縮，多付約 3% 的體積，換得使其得以塞進預算的平行度。

> **This table has been corrected twice on 2026-08-14. Four things were wrong.**
>
> **1. t=0 sampling.** It first read NV12 + zstd at 122 Mbps and RGB24 at
> 211 Mbps, from 8 frames taken at t=0 — and the clip opens on a fade from black,
> a region the measuring script's own header warns about. Raised in review by the
> Windows-side reader. Re-measured from mid-video, those became 689 and
> 1469 Mbps.
>
> **2. Mixed corpora.** The corrected NV12/RGB24 figures came from 8 consecutive
> frames while the FFV1 and predictive rows still came from 24 frames sampled 10 s
> apart — a corpus that still contained the fade frame, and that compresses ~11%
> better than consecutive footage. Every row is now measured on one 48-frame
> consecutive corpus, which moved FFV1 from 565 to 587 Mbps.
>
> **3. A unit error in the verdict column.** "1 GbE at 86%" and "at 101%" were
> not percentages: they were 86.1 and 101.1 **MB/s**, the Mbps figures divided by
> 8, copied across as if they were a link-utilisation ratio. Against the 118 MB/s
> this project actually uses for a practical gigabit, NV12 is 74% and the
> predictive stack is 86% — so the old table overstated NV12's pressure on the
> link and wrongly showed the predictive stack overflowing it.
>
> **4. Stale timings.** The 15.1 enc / 9.8 dec figures predated three commits of
> measurement-infrastructure fixes (in-process libzstd, pinned QoS, the flatten
> removed from the timed region). Re-run on the current binary, the same three
> frames give 6.5 / 4.7 — the published numbers were 2.3x too high.
>
> One expected error turned out not to be one. The reviewer also predicted that
> compressing 8 frames as one zstd stream deduplicates across frames and
> understates a per-frame bitrate. Measured directly with
> `batch_vs_per_frame.zsh`: the penalty is **-0.0%**. zstd-3's window is smaller
> than a single 6.2 MB frame, so by the time the encoder reaches frame 2, frame 1
> has already left the window and cross-frame matching cannot happen at all.
>
> **本表於 2026-08-14 經兩輪更正，共有四處錯誤。**
>
> **一、t=0 取樣。** 原記 NV12 + zstd 為 122 Mbps、RGB24 為 211 Mbps，取自 t=0 的
> 8 格影格，而本片開頭是自黑畫面淡入——量測腳本自身的檔頭已對此提出警告。此問題由
> Windows 端讀者於 review 中提出。改自影片中段重測後為 689 與 1469 Mbps。
>
> **二、語料混用。** 更正後的 NV12／RGB24 取自 8 格連續影格，而 FFV1 與 predictive
> 兩列仍取自相隔 10 秒的 24 格——該語料不但仍含淡入那格，且較連續影格好壓約 11%。
> 現已全數改用同一份 48 格連續語料，FFV1 因此由 565 變為 587 Mbps。
>
> **三、判定欄的單位錯誤。**「1 GbE at 86%」與「at 101%」並非百分比，而是 86.1 與
> 101.1 **MB/s**——Mbps 值除以 8 之後，被當成連線佔用率抄了過來。以本專案實際採用的
> 實務 gigabit 值 118 MB/s 為分母，NV12 為 74%、預測式堆疊為 86%。舊表因此既誇大了
> NV12 對線路的壓力，也錯誤地顯示預測式堆疊塞不進去。
>
> **四、過期的計時。** 15.1 enc／9.8 dec 這組數字早於三次量測基礎設施的修正（改用
> 行程內 libzstd、釘死 QoS、將攤平移出計時區）。以現行二進位對同樣三格重跑，得到
> 6.5／4.7——已發表的數字高了 2.3 倍。
>
> 另有一項預期中的錯誤並不存在。該讀者亦預測「8 格壓成單一 zstd 串流會跨影格去重，
> 因而低估每格位元率」。以 `batch_vs_per_frame.zsh` 直接量測，懲罰為 **-0.0%**。
> zstd-3 的視窗小於單張 6.2 MB 影格，編碼器讀到第 2 格時第 1 格早已離開視窗，跨影格
> 匹配根本無從發生。

**On a LAN: NV12 + zstd-3 at 694 Mbps, which is 74% of a practical gigabit** —
one stream fits, two do not, and the earlier 122 Mbps figure implied a link could
carry five. RGB24 + zstd-3 at 1482 Mbps does not fit 1 GbE at all. RGB1's
predictive stack lands between them at 813 Mbps, 86% of the link: it fits, but it
leaves nothing behind it. Both zstd paths are inside the 16.67 ms budget with
room to spare — bandwidth is the binding constraint here, not compute.

**區域網路：NV12 + zstd-3 為 694 Mbps，佔實務 gigabit 的 74%** —— 一條串流塞得下，
兩條不行；而先前的 122 Mbps 會讓人以為一條線路可承載五條。RGB24 + zstd-3 的
1482 Mbps 則完全塞不進 1 GbE。RGB1 的預測式堆疊落在兩者之間的 813 Mbps，佔線路
86%：塞得下，但後面不留任何餘地。兩條 zstd 路徑都在 16.67 ms 預算內且尚有餘裕
——此處真正的約束是頻寬而非計算。

**Over the internet: a lossy encoder is mandatory.** The source clip's own VP9
track runs at 2 Mbps against zstd's 694 Mbps — a 347x difference; no lossless path
fits a typical connection. swift_tar's role there is container and transport, not
compression.

**跨網際網路：必須使用有損編碼器。** 來源影片自身的 VP9 軌為 2 Mbps，對比 zstd
的 694 Mbps 相差 347 倍；沒有任何無損路徑能塞進一般連線。此時 swift_tar 的角色是
容器與傳輸層，而非壓縮。

> **Note on the h264_videotoolbox row**: its 41 ms/frame measurement includes
> encoder start-up amortised over only 8 frames, so it understates steady-state
> hardware performance. The bandwidth figure is the meaningful one.
> **關於 h264_videotoolbox 那一列**：其 41 ms/frame 的量測把編碼器啟動成本
> 攤在僅 8 格上，因此低估了穩態下的硬體效能。該列有意義的是頻寬數字。

> **Note on measurement scope — read before using the ms/frame column
> for a latency budget.** Every timing here comes from a full `swift_tar`
> invocation, so it contains process start-up, tar header parsing, reading the
> source from disk and writing the archive back to disk. A streaming client does
> none of the disk work: it compresses from memory and decompresses straight into
> a buffer bound for the GPU. The absolute values are therefore **upper bounds,
> not codec speeds**, and the disk component scales with payload size, so it
> penalises RGB24 (3 B/px) roughly twice as hard as NV12 (1.5 B/px). What the
> column supports is the **ranking** — all rows pay the same overhead — not a
> claim that any given row does or does not fit inside 16.67 ms.
>
> **關於量測口徑 —— 在把 ms/frame 欄位當延遲預算使用前必讀。** 此處每個時間都
> 來自完整的 `swift_tar` 呼叫，因此包含行程啟動、tar 標頭解析、從磁碟讀取來源
> 以及把封存寫回磁碟。串流客戶端不做任何磁碟工作：它從記憶體壓縮，並直接解壓
> 到準備送往 GPU 的緩衝區。故這些絕對值是**上界，而非 codec 速度**；且磁碟部分
> 隨 payload 大小等比增加，對 RGB24（3 B/px）的懲罰約為 NV12（1.5 B/px）的兩倍。
> 此欄位能支持的是**排序**（各列付出相同的額外成本），而不是「某列是否塞得進
> 16.67 ms」這種論斷。

## Is the input channel a tty? Should keyboard and mouse be separate?

## input channel 是 tty 嗎？鍵盤與滑鼠該分開嗎？

**Q: How should the audio / video / input channels be split?**
**Q: audio／video／input 通道該如何切分？**

Bandwidth is not why you separate them — video is over 99% of the total
(10-136 Mbps, versus ~128-256 kbps for Opus audio and 11-128 kbps for input).
The reason is **latency isolation and differing reliability semantics**: a large
video packet must never delay a small input packet.

分離通道的理由不是頻寬——video 佔總量 99% 以上（10-136 Mbps，相對於 Opus
音訊約 128-256 kbps、輸入 11-128 kbps）。真正的理由是**延遲隔離與可靠性語意
不同**：大的視訊封包絕不該延誤小的輸入封包。

**The input channel is not a tty.** A tty is a byte-stream abstraction; game
input needs structured, timestamped events. Sending input over a tty loses the
timestamp, and the timestamp is what lets the server reconstruct player intent
(whether two mouse samples 1 ms apart should be merged or treated separately).

**input channel 不是 tty。** tty 是位元組串流抽象；遊戲輸入需要的是結構化、
帶時間戳的事件。以 tty 傳輸會遺失時間戳，而時間戳正是伺服器據以重建玩家意圖
的依據（相隔 1 ms 的兩次滑鼠取樣該合併還是分別處理）。

**Do not split by device — split by reliability semantics.** A mouse produces
both kinds of data at once, so a keyboard/mouse split puts mouse *buttons* into
the droppable channel, which is wrong:

**不要按裝置切分，要按可靠性語意切分。** 滑鼠同時產生兩種資料，因此
「鍵盤／滑鼠」的切法會把滑鼠**按鍵**放進可丟棄的通道，這是錯的：

| channel | contents | semantics |
|---|---|---|
| Video | frames | unreliable, drop whole frames |
| Audio | audio | unreliable, small jitter buffer |
| **Input-events** | key/button down and up | **reliable, ordered** — a lost key-down leaves the character walking forever |
| **Input-state** | mouse delta, analog axes | unreliable, latest-wins — idempotent, and retransmitting a stale coordinate only adds latency |

Splitting costs one thing: **cross-channel ordering is no longer guaranteed**,
and games rely on combinations (Shift held while the mouse moves = precision
aim). Fix this by timestamping every input event from a single clock source and
reordering by timestamp on the server, rather than by arrival order.

分離的代價是：**跨通道順序不再有保證**，而遊戲大量依賴組合操作（按住 Shift
同時移動滑鼠＝精確瞄準）。解法是所有輸入事件共用同一時鐘來源並帶上時間戳，
由伺服器依時間戳而非到達順序重排。

## Does per-frame geo metadata change the format choice?

## 每格帶 geo metadata 會改變格式選擇嗎？

**Q: The size comparisons above treat RGB1 as a pixel format. What if the
per-frame geo metadata is actually required?**
**Q: 上面的大小比較把 RGB1 當成像素格式看待。若真的需要每格的 geo metadata
呢？**

Then the comparison changes, because **no other option carries it per frame**.
RGB1's 876-byte header holds lat/lng (WGS84 E7), ellipsoid height, created
timestamp, timezone offset and creator fields — attached to the frame itself,
not to the file.

那麼比較的前提就變了，因為**沒有其他選項能逐格攜帶這些資訊**。RGB1 的
876-byte 標頭包含 lat/lng（WGS84 E7）、橢球高、建立時間戳、時區 offset 與
建立者欄位——附著在影格本身，而非檔案層。

The metadata itself is nearly free on a LAN:

在區域網路上，metadata 本身的成本幾乎可以忽略：

| stream | video rate | geo overhead (876 B/frame @60fps) | share |
|---|---:|---:|---:|
| NV12 + zstd | 694 Mbps | 0.42 Mbps | 0.06% |
| RGB1 + zstd | 1482 Mbps | 0.42 Mbps | 0.03% |
| VP9 lossy | 2 Mbps | 0.42 Mbps | **21.0%** |

| format | how it would carry per-frame geo |
|---|---|
| NV12 | no such field — needs a separate channel or a container metadata track |
| VP9 / WebM | container-level tags only, not per frame — needs a custom side-channel |
| **RGB1** | built in: 876 B of fixed fields on every frame |

So the decision is not "RGB1 vs NV12 by size" but **whether per-frame geo is a
requirement**:

因此決策並非「以大小比較 RGB1 與 NV12」，而是**是否必須逐格記錄 geo**：

- **Geo not needed** -> NV12 + zstd. RGB1 costs 113% more bandwidth for metadata
  that is never read.
  **不需要 geo** → NV12 + zstd。RGB1 多付 113% 頻寬，換到的 metadata 卻從未被
  讀取。
- **Geo needed, on a LAN** -> RGB1 is reasonable. The geo itself is 0.03% of the
  stream; the real cost is the 113% pixel-format premium, paid in exchange for
  not having to build and synchronise a separate metadata channel.
  **需要 geo，且在區網** → RGB1 合理。geo 本身僅佔串流 0.03%；真正的代價是像素
  格式貴 113%，換來的是不必自行建立並同步一條獨立的 metadata 通道。
- **Geo needed, over the internet** -> do not use RGB1 as the wire format. Send
  lossy video (VP9/H.264) and carry geo on a side-channel; at 2 Mbps the same
  876 B/frame would be 21% of the stream, and RGB1's raw pixels are impossible
  anyway.
  **需要 geo，但跨網際網路** → 不要用 RGB1 當傳輸格式。改送有損視訊
  （VP9/H.264）並以 side-channel 攜帶 geo；在 2 Mbps 下同樣的 876 B/frame 會
  佔串流的 21%，何況 RGB1 的原始像素本來就傳不動。

Note that the 876 B is a fixed header repeated per frame. If the position is
static or changes slowly, most of those bytes are redundant and compress away —
which is part of why RGB1's compression ratio measures slightly better than
NV12's above. A stream-level design that sends the header once and only sends
deltas when the position changes would remove the overhead entirely, at the cost
of no longer being a sequence of self-contained RGB1 frames.

注意這 876 B 是逐格重複的固定標頭。若位置靜止或變化緩慢，其中大部分位元組是
冗餘的、會被壓縮掉——這也是上文 RGB1 壓縮率略優於 NV12 的原因之一。若改為
串流層級的設計：標頭只送一次、位置變動時才送差異，即可完全消除此開銷，代價是
不再是一連串「自足的 RGB1 影格」。

> **Superseded percentages below.** This section and the YCoCg-R/MED section
> that follows were measured on 8 consecutive frames from t=0, which are a
> fade-in from black and compress ~5x better than real content. The techniques
> and their relative ranking still hold; the absolute percentages do not. See
> "How close does YCoCg-R + MED + planar get to FFV1 and VP9?" at the end of this
> file for the current numbers on the 24-frame sampled corpus.
>
> **以下百分比已被取代。** 本節與其後的 YCoCg-R/MED 一節，量測對象為 t=0 起的
> 8 格連續影格；那是自黑畫面淡入的片段，較真實內容易壓縮約 5 倍。技術本身與其
> 相對排序仍然成立，絕對百分比則否。當前數據請見本檔末的「YCoCg-R + MED +
> planar 與 FFV1、VP9 的差距有多少？」，該節以 24 格取樣語料量測。

## Can VP9's streaming techniques improve the RGB1 format?

## VP9 的串流技術能改進 RGB1 格式嗎？

**Q: VP9 is far smaller than our path. Which of its techniques can RGB1 borrow?**
**Q: VP9 比我們的路徑小得多，其中哪些技術可以用在 RGB1 上？**

Not VP9's — **FFV1's**. Measured on the same 8 frames, VP9's *lossless* mode is
no better than what we already do:

不是 VP9 的，而是 **FFV1 的**。以相同 8 格實測，VP9 的**無損**模式並不優於我們
現有的做法：

| method | bytes | % of raw |
|---|---:|---:|
| VP9 lossless | 3,509,041 | **7.05%** |
| raw RGB + zstd (RGB1 today) | 3,509,790 | 7.05% |
| FFV1 (spatial predictor + range coder) | 1,922,856 | **3.86%** |

VP9's advantage lives entirely in its lossy path (quantisation); switch it to
lossless and it lands exactly where a general-purpose compressor already is.
FFV1 is the codec worth learning from, and the technique that matters is
**spatial prediction** — RGB1's payload is currently raw, unprocessed bytes.

VP9 的優勢完全來自其有損路徑（量化）；切到無損後，它的結果與通用壓縮器完全相同。
值得學習的是 FFV1，而關鍵技術是**空間預測**——RGB1 的 payload 目前是完全未經
處理的原始位元組。

### Spatial predictors measured on the RGB1 payload

### 在 RGB1 payload 上實測各種空間預測

Each predictor replaces every byte with its difference from a prediction made
from already-decoded neighbours, then the residual goes through the existing
codec. All are lossless and exactly reversible.

每種預測器都把每個位元組換成「與由已解碼鄰居所做預測之差」，殘差再交給既有
codec。全部無損且可完全還原。

| predictor | bytes | % of raw | vs today |
|---|---:|---:|---:|
| none (today) | 3,509,790 | 7.05% | — |
| Sub (left pixel) | 3,513,164 | 7.06% | +0.1% |
| Up (pixel above) | 3,063,729 | 6.16% | -12.7% |
| Paeth (PNG) | 3,001,788 | 6.03% | -14.5% |
| **MED (FFV1 / JPEG-LS)** | **2,967,564** | **5.96%** | **-15.4%** |

Sub alone is useless here — horizontal neighbours in this content are no more
predictive than the raw bytes. MED (median edge detector: pick min/max/gradient
of left, above and upper-left) is the best of the four and is what FFV1 and
JPEG-LS both use.

單用 Sub 在此毫無效果——本內容中水平相鄰像素的預測力並不優於原始位元組。
MED（median edge detector：依左、上、左上三者取 min/max/梯度）是四者中最佳，
也正是 FFV1 與 JPEG-LS 共同採用的方法。

### Stacking the improvements

### 疊加各項改進

| variant | bytes | % of raw | vs today |
|---|---:|---:|---:|
| raw + zstd-3 (today) | 3,509,790 | 7.05% | — |
| MED + zstd-3 | 2,967,564 | 5.96% | -15.4% |
| MED + zstd-19 | 2,296,168 | 4.61% | -34.6% |
| MED + xz -9 | 2,232,176 | 4.49% | -36.4% |
| **MED + frame delta + zstd-19** | **2,111,112** | **4.24%** | **-39.9%** |
| FFV1 (reference) | 1,922,856 | 3.86% | -45.2% |

Stacking spatial prediction, inter-frame delta and a higher compression level
takes RGB1 from 7.05% to **4.24% of raw — a 40% reduction — reaching 91% of
FFV1's result** while staying inside the existing container and codec set.

疊加空間預測、影格間差分與較高壓縮等級，可讓 RGB1 從 7.05% 降到
**原始的 4.24%——減少 40%——達到 FFV1 成果的 91%**，且完全不脫離既有容器與
codec 組合。

The remaining 9% gap is entropy coding: FFV1 uses a context-adaptive range coder
while we hand the residual to a general-purpose compressor. Closing it means
writing a range coder, which is a large amount of work for the last few percent.

剩下的 9% 差距在於熵編碼：FFV1 使用 context-adaptive range coder，而我們是把
殘差交給通用壓縮器。要補上這段就得自行實作 range coder，為了最後幾個百分點
投入過大。

### Where these bits would live in the header

### 這些旗標在標頭中的位置

RGB1 is a binary container: a fixed 876-byte header followed by raw RGB. The
header already has a `flags` field (offset 12, UInt32) with only bit 0 in use,
so both this and the streaming geo optimisation fit there without a format
break:

RGB1 是二進位容器：固定 876-byte 標頭後接原始 RGB。標頭已有 `flags` 欄位
（offset 12，UInt32）且僅使用 bit 0，因此本項與串流 geo 最佳化都能放進該欄位，
不需破壞既有格式：

| bit | meaning | 意義 |
|---|---|---|
| 0 | geo metadata present (existing) | 帶有 geo metadata（現有） |
| 1 | geo identical to previous frame; header fields omitted | geo 與前一格相同，本格省略該些欄位 |
| 2 | payload is MED-predicted | payload 已做 MED 空間預測 |
| 3 | payload is delta-coded against the previous frame | payload 已對前一格做差分 |

Bit 1 addresses the per-frame metadata overhead: at 60 fps a static position
repeats 876 B x 60 = 0.42 Mbps of identical bytes. Bits 2 and 3 are payload
transforms — a decoder that does not understand them must refuse the frame
rather than render it wrong, so they are a format version boundary in practice.

bit 1 針對逐格 metadata 開銷：在 60 fps 下，位置靜止時會重複送出
876 B x 60 = 0.42 Mbps 的相同位元組。bit 2 與 bit 3 屬於 payload 變換——不理解
這些旗標的解碼器必須拒絕該影格，而非錯誤地渲染，因此實務上它們構成格式版本的
分界。

> **Caveat**: measured on one 1080p talking-head clip. MED's benefit depends on
> spatial smoothness and the frame-delta benefit on temporal stillness; both will
> differ on other content, and the earlier frame-delta measurement on a different
> clip showed 25% rather than the 6.9% seen here.
> **注意**：僅以一支 1080p 人物講述影片量測。MED 的效益取決於空間平滑度，影格
> 差分的效益取決於時間上的靜止程度；兩者在其他內容上都會不同，先前在另一支影片
> 上量到的影格差分效益是 25%，而非此處的 6.9%。

## What is the status of webm2 (RGB1 frames plus audio)?

## webm2（RGB1 影格加音訊）的狀態為何？

**Q: Can we put an RGB1 frame sequence and an audio track in one container?**
**Q: 能把 RGB1 影格序列與音訊軌放進同一個容器嗎？**

Technically yes, but **on hold** until the RGB1 payload gets smaller. The
container question is already answered: WebM itself only permits VP8/VP9/AV1
video, but Matroska accepts raw RGB with `-allow_raw_vfw 1`, and a raw video
track plus the original Vorbis/Opus audio track was verified to mux and demux
correctly.

技術上可行，但**暫緩**，等 RGB1 payload 變小再說。容器問題已有答案：WebM 本身
只允許 VP8/VP9/AV1 視訊，但 Matroska 可用 `-allow_raw_vfw 1` 接受 raw RGB，且
已驗證「raw 視訊軌 + 原始 Vorbis/Opus 音訊軌」能正確封裝與解封裝。

The blocker is size, not plumbing. For a 2-second clip:

阻礙在於體積，而非接線。以 2 秒片段為例：

| payload treatment | webm2 size | vs source webm |
|---|---:|---:|
| raw + zstd (today) | 186.9 MB | 771x |
| MED prediction | 119.0 MB | 491x |
| YCoCg-R + MED + planar | 103.5 MB | 427x |
| the above + zstd-19 | 85.9 MB | **355x** |

Every payload improvement measured elsewhere in this FAQ flows straight through
to webm2 — the stack has already taken it from 771x to 355x. That is real
progress and the reason to keep the idea alive, but 355x is still far from
usable, because the gap is structural: a lossless still-image sequence cannot
exploit inter-frame redundancy the way a video codec does.

本 FAQ 中量測到的每一項 payload 改進都會直接反映到 webm2——目前已把 771 倍降到
355 倍。這是實質進展，也是保留此構想的理由；但 355 倍距離可用仍遠，因為差距是
結構性的：無損靜態影像序列無法像視訊 codec 那樣利用影格間冗餘。

**Revisit when**: the RGB1 payload reaches roughly an order of magnitude below
today's 50% of raw — that is where webm2 stops being a curiosity. Two things
would have to land first: an entropy coder better than a general-purpose
compressor (FFV1's range coder is 1.8x better than zstd on the same residual),
and some form of inter-frame coding, which is exactly what a still-image
container is not.

**何時重新評估**：當 RGB1 payload 從目前的「原始的 50%」再降約一個數量級時，
webm2 才會從實驗品變成有意義的選項。屆時需要先具備兩件事：優於通用壓縮器的
熵編碼器（在相同殘差上，FFV1 的 range coder 比 zstd 好 1.8 倍），以及某種形式的
影格間編碼——而後者正是靜態影像容器所欠缺的。

**Design note kept for that day**: the per-frame metadata bits discussed above
(geo unchanged, email unchanged, title unchanged) belong to the *stream* layer,
not to the RGB1 header. A standalone RGB1 file must stay self-describing; a
frame that omits its creator email because the previous frame had the same one
is a stream frame, not an image container. Those bits go in webm2's frame
header when it is built.

**為那一天保留的設計註記**：上文討論的逐格 metadata 旗標（geo 未變、email
未變、title 未變）屬於**串流**層，而非 RGB1 標頭。獨立的 RGB1 檔案必須保持
自我描述；若某格因為前一格相同而省略建立者 email，它就是串流影格而非影像容器。
這些旗標應在實作 webm2 時放進其影格標頭。

## What are YCoCg-R and MED?

## YCoCg-R 與 MED 是什麼？

**Q: Both keep appearing in the size results — what do they actually do?**
**Q: 這兩個名詞不斷出現在體積結果中——它們實際上在做什麼？**

Both are **lossless, exactly reversible** transforms applied to the payload
before it reaches the compressor. Neither discards anything; they rearrange the
data so that a general-purpose compressor has an easier job. A decoder inverts
them and gets the original bytes back bit-for-bit.

兩者都是在資料進入壓縮器之前，對 payload 施加的**無損、可完全還原**變換。它們
不丟棄任何資訊，只是重新安排資料，讓通用壓縮器更容易發揮。解碼器將其反轉即可
逐位元取回原始位元組。

### MED — median edge detector

MED predicts each pixel from three already-decoded neighbours and stores only
the **difference** between the prediction and the real value. Photographic
images are locally smooth, so the prediction is usually close and the residual
is a small number clustered near zero — far more compressible than the original
byte values, which are spread across the full 0-255 range.

MED 以三個**已解碼**的鄰居預測每個像素，只儲存預測值與真實值的**差**。照片類
影像在局部是平滑的，因此預測通常很接近，殘差是集中在零附近的小數值——遠比
原始位元組值（散布於 0-255 全域）更容易壓縮。

Given `a` = left, `b` = above, `c` = upper-left, the prediction is:

令 `a` = 左、`b` = 上、`c` = 左上，預測值為：

```
if    c >= max(a, b):  pred = min(a, b)
elif  c <= min(a, b):  pred = max(a, b)
else:                  pred = a + b - c      // gradient / 梯度
```

The first two branches detect an edge — when the upper-left corner is already
past both neighbours, the pixel is likely on the far side of an edge, so the
predictor picks the neighbour on the correct side instead of averaging across
it. This is why it beats a plain "subtract the left pixel" filter, which smears
the residual across every edge. The same predictor is used by **FFV1** and
**JPEG-LS** (where it is called LOCO-I).

前兩個分支用於偵測邊緣——當左上角已超出兩個鄰居的範圍時，該像素很可能位於邊緣
的另一側，因此預測器改取正確一側的鄰居，而非跨越邊緣做平均。這正是它勝過單純
「減去左邊像素」的原因，後者會讓殘差在每個邊緣處擴散。**FFV1** 與 **JPEG-LS**
（在該規格中稱為 LOCO-I）採用的都是同一個預測器。

Only neighbours **above and to the left** can be used: in raster scan order the
pixels to the right and below have not been decoded yet. This is why a
"compare with up/down/left/right" scheme can only ever use half of those four.

只能使用**上方與左方**的鄰居：在 raster scan 順序下，右方與下方的像素尚未解碼。
這也是為何「與上／下／左／右比較」的方案最多只能用到其中一半。

Measured on the RGB1 samples: **-36.4%** on its own.

在 RGB1 樣本上實測：單獨使用即 **-36.4%**。

### YCoCg-R — reversible colour decorrelation

### YCoCg-R — 可逆的色彩去相關

R, G and B are highly correlated: a bright pixel tends to be bright in all three
channels, so the same information is stored three times. YCoCg-R converts them
into one luma-like channel and two colour-difference channels, moving most of
the energy into `Y` and leaving `Co`/`Cg` small and near zero.

R、G、B 三個通道高度相關：明亮的像素在三個通道通常都亮，等於同一份資訊被存了
三次。YCoCg-R 將其轉換為一個類亮度通道與兩個色差通道，把大部分能量集中到 `Y`，
使 `Co`／`Cg` 維持在接近零的小數值。

```
forward / 正向:                     inverse / 反向:
  Co = R - B                          t  = Y - (Cg >> 1)
  t  = B + (Co >> 1)                  G  = Cg + t
  Cg = G - t                          B  = t - (Co >> 1)
  Y  = t + (Cg >> 1)                  R  = B + Co
```

The `-R` suffix means **reversible**: it uses only integer adds, subtracts and
shifts, so it round-trips exactly. The plain YCoCg (and the YUV used by video
codecs) involves rounding and is lossy. The cost is that `Co` and `Cg` need one
extra bit of range each — a detail the container has to account for. The same
transform is used by **FFV1** and **JPEG-XL**.

字尾 `-R` 代表**可逆**（reversible）：僅使用整數加、減與位移，因此往返完全一致。
一般的 YCoCg（以及視訊 codec 使用的 YUV）含有捨入，屬於有損。代價是 `Co` 與
`Cg` 各需多一個位元的範圍——這是容器必須處理的細節。**FFV1** 與 **JPEG-XL** 使用
的是同一個變換。

Measured on the RGB1 samples: **-10.1%** on its own, and it stacks with MED
because it removes a different kind of redundancy — MED removes redundancy
*between neighbouring pixels*, YCoCg-R removes it *between colour channels of
the same pixel*.

在 RGB1 樣本上實測：單獨使用為 **-10.1%**，且可與 MED 疊加，因為兩者消除的是
不同類型的冗餘——MED 消除**相鄰像素之間**的冗餘，YCoCg-R 消除**同一像素的色彩
通道之間**的冗餘。

### Why "planar" helps too

### 為何「planar」也有幫助

After both transforms the payload is still interleaved as `Y Co Cg Y Co Cg ...`.
Writing all `Y` values, then all `Co`, then all `Cg` puts statistically similar
bytes next to each other, which suits the compressor's match finder. Measured:
a further **-2.5%**.

經過兩項變換後，payload 仍是 `Y Co Cg Y Co Cg ...` 的交錯排列。改為先寫出所有
`Y`、再所有 `Co`、再所有 `Cg`，可讓統計特性相近的位元組相鄰，較符合壓縮器的
match finder。實測可再降 **-2.5%**。

### Combined result on the RGB1 sample set

### 在 RGB1 樣本集上的綜合結果

| stage | % of raw | cumulative |
|---|---:|---:|
| raw (today) | 50.11% | — |
| + MED | 31.88% | -36.4% |
| + YCoCg-R | 29.00% | -42.1% |
| + planar | 27.74% | -44.6% |
| + zstd-19 | 23.02% | **-54.1%** |

All four stages are lossless and verified by round-trip. None of them changes
the RGB1 header layout — they transform the payload only, which is why a flag
bit is enough to signal them.

四個階段全部無損並經往返驗證。它們都不改變 RGB1 的標頭佈局——僅變換 payload，
這也是為何用一個旗標位元即可標示。

## Should RGB1 be renamed BGR1, since Matroska uses `-allow_raw_vfw 1`?

## 既然 Matroska 用 `-allow_raw_vfw 1`，RGB1 該改名為 BGR1 嗎？

**Q: ffmpeg writes `bgr24` into Matroska in VFW mode. Does that mean our channel
order is wrong, or that we should adopt the standard naming?**
**Q: ffmpeg 在 VFW 模式下把 `bgr24` 寫進 Matroska。這是否代表我們的通道順序有誤，
或者該改用標準命名？**

**No. RGB1 stores R, G, B and must keep doing so.** Verified by writing a pure
red pixel through the packer and reading the payload back: bytes `(255, 0, 0)`,
matching the spec line "Raw RGB bytes, row-major, 8-bit R,G,B".

**不需要。RGB1 儲存的就是 R, G, B，且應維持如此。** 驗證方式為以 packer 寫入
一個純紅像素再讀回 payload：得到 `(255, 0, 0)`，與規格所載「Raw RGB bytes,
row-major, 8-bit R,G,B」一致。

The `bgr24` seen in Matroska comes from **VFW (Video for Windows)**, whose
`BITMAPINFOHEADER` convention is BGR — a 1990s Windows API detail arising from
reading a 24-bit colour as a little-endian integer. It is a property of that
packaging layer, not of RGB1.

Matroska 中看到的 `bgr24` 來自 **VFW（Video for Windows）**，其
`BITMAPINFOHEADER` 慣例為 BGR —— 這是 1990 年代 Windows API 的細節，源於把
24-bit 色值當作 little-endian 整數讀取。那是該封裝層的性質，不是 RGB1 的性質。

Renaming would actively create a CPU cost, because the hardware side wants R
first. Traced through the P6 test app:

改名反而會製造真實的 CPU 成本，因為硬體端要的就是 R 在前。P6 測試程式的實際路徑：

| stage | P6.swift | order | swap needed? |
|---|---|---|---|
| RGB1 payload | spec + measured | **R,G,B** | — |
| Metal texture | `pixelFormat: .rgba8Unorm` | **R,G,B,A** | **no** |
| upload | `texture.replace(withBytes:)` | direct memcpy | **no conversion** |
| CGImage fallback | `CGImageAlphaInfo.last` + `DeviceRGB` | **R,G,B,A** | **no** |

`colorPixelFormat = .bgra8Unorm` in the same file looks like a counter-example,
but that is the **drawable/framebuffer** format, not the texture format. The
fragment shader returns a `float4`; the GPU's fixed-function ROP orders the
channels on write-out. That is a hardware swizzle: no CPU work, no bandwidth.

同檔案中的 `colorPixelFormat = .bgra8Unorm` 看似反例，但那是
**drawable/framebuffer** 格式，而非 texture 格式。fragment shader 回傳 `float4`，
由 GPU 固定功能 ROP 於寫出時排序通道。那是硬體 swizzle：不耗 CPU、不佔頻寬。

The only CPU work on the path is **adding the alpha channel** (3 B/px to
4 B/px), which is unrelated to channel order and is inherent to any RGBA target.

路徑上唯一的 CPU 工作是**補 alpha**（3 B/px → 4 B/px），與通道順序無關，且是
任何 RGBA 目標都必須付出的成本。

Note also that `RGB1`'s `1` is a **format version, not a channel or depth
count**. It is not the same kind of name as ffmpeg's `rgb24`/`bgr24` pixel
formats: those describe a pixel layout, whereas `RGB1` names a container with an
876-byte header and geo metadata.

另需注意 `RGB1` 的 `1` 是**格式版本，而非通道數或位元深度**。它與 ffmpeg 的
`rgb24`/`bgr24` 並非同一層級的命名：後者描述像素排列，而 `RGB1` 命名的是帶有
876 位元組標頭與 geo metadata 的容器。

## Does stripping geo metadata make frames meaningfully smaller?

## 移除 geo metadata 能明顯縮小影格嗎？

**Q: Should webm2 offer a geo-less mode to reduce the streamed size?**
**Q: webm2 該提供無 geo 模式以降低串流體積嗎？**

**No — and the option already exists anyway.** `flags` bit 0 at offset 12 is
defined as "geo metadata present", so geo has been optional since the format was
designed. What the measurement adds is that turning it off buys nothing.

**不需要 —— 而且該選項本來就存在。** offset 12 的 `flags` bit 0 定義為
「geo metadata present」，故 geo 自格式設計之初即為可選。量測補充的結論是：
關掉它並無收益。

Measured over 24 sampled 1920x1080 frames at zstd-19:

以 24 張取樣的 1920x1080 影格、zstd-19 實測：

| variant | avg compressed (B) | delta |
|---|---:|---:|
| full (geo present) | 2,315,354.2 | — |
| geo zeroed, `flags` bit 0 clear | 2,315,338.2 | -16.1 |
| geo removed (header 860 B) | 2,315,341.8 | -12.4 |

**12.4 B per frame, or 0.00054% of the compressed frame; 0.006 Mbps at 60 fps.**

**每格 12.4 B，佔壓縮後影格的 0.00054%；60 fps 下為 0.006 Mbps。**

Two details are worth keeping. First, **zeroing the fields saves slightly more
than physically removing them** — sixteen zero bytes compress to almost nothing,
while deleting them perturbs the alignment of everything after. Removal is a net
negative. Second, the 0.42 Mbps figure quoted elsewhere in this FAQ is the cost
of the **entire 876-byte header**, of which geo is 16 bytes. The real header
weight is `country` (512 B) and `creator_email` (254 B), together 48x the geo
fields. Those are what a header-shrinking effort should target.

有兩點值得記住。其一，**清零欄位比實體移除還省** —— 十六個零位元組幾乎壓縮到
不存在，而刪除它們會擾動其後所有位元組的對齊；移除是淨負收益。其二，本 FAQ
他處引用的 0.42 Mbps 是**整個 876 位元組標頭**的成本，geo 僅佔其中 16 位元組。
標頭的真正重量在 `country`（512 B）與 `creator_email`（254 B），兩者合計為 geo
欄位的 48 倍；若要縮減標頭，該從那裡下手。

## What should a scan-line separator be? Is it an ASCII `\n`?

## 掃描線分隔符該是什麼？是 ASCII `\n` 嗎？

**Q: For multi-line parallel rendering, we want a few bits as a per-scan-line
separator. Should it be `\n`?**
**Q: 為了多行平行渲染，我們想為每條掃描線加上幾個位元的分隔符。該用 `\n` 嗎？**

**No in-band marker of any kind, `\n` least of all.** The RGB1 payload is raw
binary: `0x0A` is a perfectly legal pixel value and appears constantly. Any
in-band sentinel would be ambiguous with real data, requiring escaping — and
escaping makes the payload **variable-length**, destroying the property that
makes RGB1 worth having:

**不要任何 in-band 標記，`\n` 尤其不可。** RGB1 payload 是原始二進位：`0x0A` 是
完全合法的像素值且頻繁出現。任何 in-band 哨符都會與真實資料混淆，必須引入
escaping —— 而 escaping 會讓 payload 變成**可變長度**，摧毀 RGB1 最有價值的性質：

```
offset of row N = 876 + N * width * 3      # pure arithmetic, O(1) addressing
```

**A raw payload needs no separator at all.** Multi-line parallel rendering works
today: each thread computes its own span with the formula above, at zero extra
bytes and zero scanning cost.

**原始 payload 根本不需要分隔符。** 多行平行渲染現在就能做：每個執行緒以上述
公式算出自己負責的區段，零額外位元組、零掃描成本。

A separator is only needed once rows are **compressed independently**, and then
the correct mechanism is an **out-of-band offset table in the header**, not a
marker in the stream:

唯有當各行**獨立壓縮**時才需要分隔機制，而正確作法是**標頭中的 out-of-band
位移表**，而非資料流中的標記：

| approach | cost per 1080p frame | O(1) addressing | binary-safe |
|---|---:|---|---|
| in-band `\n` | escaping overhead, unbounded | no — must scan | **no** |
| per-row offset table (1080 x 4 B) | 4,320 B | yes | yes |
| FFV1-style slices (e.g. 16) | 64 B | yes | yes |

FFV1 uses the third. It also solves the compression side: compressing every row
independently was measured to cost **9.6% in size** (the compressor's state
resets each row, losing cross-row correlation), whereas 16 slices costs roughly
0.6% — and 16-way parallelism already saturates current CPUs.

FFV1 採用第三種。它同時解決壓縮面的問題：逐行獨立壓縮實測要付出**9.6% 的體積
代價**（壓縮器狀態每行重置，喪失跨行相關性），而切成 16 條 slice 僅約 0.6%
—— 且 16 路平行對現行 CPU 已足夠飽和。

Slices also serve latency, not just parallelism: a streaming encoder emits each
slice as it is produced rather than waiting for the whole frame, which matters
because game streaming operates at millisecond granularity (a 60 fps frame
interval is 16.67 ms end to end), never at second granularity.

Slice 同時服務於延遲而不僅是平行化：串流編碼器可在每條 slice 產出時即送出，
而非等待整格完成。這很重要，因為遊戲串流的時間粒度是毫秒級（60 fps 的影格
間隔為 16.67 ms），從來不是秒級。

## Would a colour map with pointers be smaller than storing RGB per pixel?

## 用色彩對照表加指標，會比逐像素存 RGB 更小嗎？

**Q: Build a map of every unique RGB in the frame, then store each pixel as a
pointer into it. At 4K the pointer is narrower than 24 bits, so this should
shrink the container.**
**Q: 建立影格中所有唯一 RGB 的對照表，每個像素改存指向表的指標。4K 下指標比
24 bits 窄，這應該能縮小容器。**

**The premise is right and the conclusion is wrong: it shrinks the uncompressed
payload but comes out 23.5% LARGER after compression.** Measured over 24 sampled
1920x1080 frames with `../verifications/rgb1/palette_vs_predictive.py`, every arm
round-trip verified:

**前提正確而結論不成立：它確實縮小了未壓縮的 payload，但壓縮後反而大 23.5%。**
以 `../verifications/rgb1/palette_vs_predictive.py` 對 24 張 1920x1080 取樣影格實測，
每組皆通過往返驗證：

| arm | stored (B) | +zstd-19 (B) | of raw |
|---|---:|---:|---:|
| raw payload (today) | 6,220,800 | 2,315,247 | 37.22% |
| **colour map + pointers** | **4,613,592** | 2,859,226 | 45.96% |
| YCoCg-R + MED + planar | 6,220,800 | **1,370,475** | **22.03%** |

The map does its job: unique colours average 112,263 out of 2.07 M pixels, so an
18-bit pointer replaces a 24-bit pixel and the stored payload drops 25.8%. But
**the pointers are arbitrary integers**. Two spatially adjacent, visually
near-identical colours get unrelated indices, and that spatial correlation is
exactly what a general-purpose compressor feeds on. Raw RGB compresses to 37%;
the pointer stream only reaches 62%.

對照表確實奏效：唯一色數平均為 112,263（總像素 2.07 M），故 18-bit 指標可取代
24-bit 像素，未壓縮 payload 下降 25.8%。但**指標是任意整數**。空間相鄰、視覺上
幾乎相同的兩個顏色會拿到毫無關聯的索引，而那正是通用壓縮器賴以運作的空間相關性。
raw RGB 壓到 37%，指標串流只到 62%。

**The general lesson: a fixed-width saving that destroys structure loses to
leaving the structure intact.** Predictive coding wins because it does the
opposite — it *increases* structure by turning pixels into mostly-zero
residuals, which is why it beats the palette by 52.1%.

**通則：以摧毀結構換取固定寬度的節省，輸給保留結構。** 預測式編碼之所以勝出，
正因為它做的是相反的事 —— 它把像素轉成大多為零的殘差，從而**增加**結構，這也是
它勝過調色盤 52.1% 的原因。

This is reproducible from either implementation. `swift_tar_DOE` reaches the
same -40.8% for the predictive stack as the Python DOE, from independent code:

兩份實作皆可重現此結果。`swift_tar_DOE` 以獨立程式碼得到與 Python DOE 相同的
預測式堆疊 -40.8%：

```
./swift_tar_DOE --all --codec zstd --level 19 sample/*.rgb1
```

## How close does YCoCg-R + MED + planar get to FFV1 and VP9?

## YCoCg-R + MED + planar 與 FFV1、VP9 的差距有多少？

**Q: Having settled on the predictive stack, how does it actually compare with
the lossless codecs it borrows from?**
**Q: 既然確定採用預測式堆疊，它與所借鏡的無損編碼器實際比較如何？**

Measured with `../verifications/rgb1/ffv1_vp9_vs_predictive.zsh` over **24 frames
sampled 10 s apart** from the VP9 programme clip. All arms are intra-only and
single-frame — the samples are 10 s apart, so an inter-frame mode would be
measuring scene cuts, not codec quality. Every FFV1 and VP9 frame was decoded
back and byte-compared before its size was counted.

以 `../verifications/rgb1/ffv1_vp9_vs_predictive.zsh` 對 VP9 節目影片**每隔 10 秒
取樣的 24 格**實測。所有組別皆為 intra、單影格 —— 樣本相隔 10 秒，影格間模式量到
的會是場景切換而非編碼器品質。每個 FFV1 與 VP9 影格在計入大小前，都先解碼回來做
位元組比對。

| arm | avg bytes/frame | of raw | vs FFV1 |
|---|---:|---:|---:|
| raw payload + zstd-19 (today) | 2,316,123 | 37.23% | 1.97x |
| **YCoCg-R + MED + planar + zstd-19** | **1,371,351** | **22.04%** | **1.16x** |
| VP9 `-lossless 1` (intra) | 2,226,585 | 35.79% | 1.89x |
| FFV1 level 3 (intra) | 1,177,152 | 18.92% | 1.00x |

**Three results, one of them unexpected:**

**三項結果，其中一項出乎意料：**

1. **The stack reaches 86% of FFV1's efficiency** (+16.5% larger). The remaining
   gap is entropy coding: FFV1 uses a context-adaptive range coder, we hand the
   residuals to zstd. We match FFV1's modelling; we do not match its coder.
   **此堆疊達到 FFV1 效率的 86%**（體積多 16.5%）。剩餘差距在熵編碼：FFV1 使用
   context-adaptive range coder，我們則把殘差交給 zstd。我們在建模上追平 FFV1，
   在編碼器上沒有。

2. **It beats VP9 lossless by 38.4%.** This is the unexpected one — a
   general-purpose compressor plus two cheap integer transforms comfortably
   outperforms a modern video codec's lossless mode.
   **它勝過 VP9 lossless 達 38.4%。** 這是意外的一項 —— 通用壓縮器加上兩個廉價的
   整數變換，明顯勝過現代視訊編碼器的無損模式。

3. **VP9 lossless is barely better than raw + zstd** (35.79% vs 37.23%, a 3.9%
   edge). VP9's machinery is built for rate-distortion optimisation; switch off
   the distortion and almost all of its advantage disappears. This confirms, with
   numbers, the earlier conclusion that VP9's lossless mode offers nothing worth
   borrowing — FFV1 is the right model to learn from.
   **VP9 lossless 僅略優於 raw + zstd**（35.79% 對 37.23%，差 3.9%）。VP9 的機制
   是為率失真最佳化而建；關掉失真，它的優勢幾乎全數消失。這以數據證實了先前的
   結論：VP9 的無損模式沒有值得借鏡之處 —— FFV1 才是該學習的對象。

> **Corpus note — these figures supersede the earlier percentages in this FAQ.**
> Sections written before the sampler existed used 8 *consecutive* frames from
> t=0, and the first eight frames of this clip are a fade-in from black. Those
> frames compress far better than real content, so the absolute percentages
> quoted there (FFV1 3.86%, our stack 4.24%, "91% of FFV1") are optimistic by
> roughly 5x and are **not comparable** with the table above. The relative
> ordering held — FFV1 best, our stack close behind, raw worst — but the gap to
> FFV1 is 86%, not 91%. Use this section's numbers.
>
> **語料註記 —— 本節數字取代本 FAQ 先前的百分比。** 取樣器出現前所寫的章節使用
> 從 t=0 起的 8 格**連續**影格，而本影片的前八格是自黑畫面淡入。那些影格遠比真實
> 內容易壓縮，故該處引用的絕對百分比（FFV1 3.86%、我方 4.24%、「達 FFV1 的 91%」）
> 樂觀約 5 倍，與上表**不可比較**。相對排序不變 —— FFV1 最佳、我方緊隨、raw 最差
> —— 但與 FFV1 的差距是 86% 而非 91%。請以本節數字為準。

**What this settles.** The stack is worth implementing: it cuts the payload by
40.8% versus today's format, in exchange for two integer transforms and a
different byte order. Closing the last 16.5% means writing a range coder, which
is a much larger undertaking than the transforms and can be decided separately.

**這確立了什麼。** 此堆疊值得實作：相較現行格式可縮減 payload 40.8%，代價僅是兩個
整數變換與不同的位元組排列。要補上最後的 16.5% 則需自行實作 range coder，其工程量
遠大於這些變換，可另行決定。

## Does directional similarity (zero the RGB when a neighbour matches) help?

## 方向相似性（與鄰居相同時 RGB 寫零）有幫助嗎？

**Q: Test each pixel against its directional neighbours. On a match, write RGB as
zero and record the direction in a flag. Zeros compress to almost nothing, and
keeping the payload full-length preserves O(1) row addressing.**
**Q: 逐像素與方向鄰居比對。相同時 RGB 寫零，方向記於旗標。零幾乎壓縮到不存在，
且 payload 維持完整長度可保住 O(1) 列定址。**

**The addressing argument is right — writing zeros rather than omitting bytes is
the correct choice. The compression argument does not survive measurement.**
Measured with `../verifications/rgb1/swift_tar_DOE --dirsim`, round-trip
verified, 3-bit flags over four directions (left, above, upper-left,
upper-right):

**定址論點正確 —— 寫零而非省略位元組確實是對的選擇。壓縮論點則通不過量測。**
以 `../verifications/rgb1/swift_tar_DOE --dirsim` 實測，通過往返驗證，四個方向
（左、上、左上、右上）以 3-bit 旗標編碼：

| arm | of raw |
|---|---:|
| **dirsim** | **53.50%** |
| dirsim + YCoCg-R + planar | 54.35% |
| raw + zstd-3 (do nothing) | 49.82% |
| YCoCg-R + MED + planar | **27.10%** |

**It is worse than doing nothing.** zstd's LZ match-finder already locates exact
byte repeats — telling it "this pixel equals its left neighbour" restates
information it extracts anyway, while the flag stream is new cost: 3 bits per
pixel is 0.375 B/px, or 12.5% on top of a 3 B/px payload.

**它比什麼都不做更差。** zstd 的 LZ match-finder 本來就在尋找完全重複的位元組
——告訴它「這個像素等於左鄰」是在重述它本就會提取的資訊，而旗標串流是新增成本：
每像素 3 bits 即 0.375 B/px，相當於在 3 B/px 的 payload 上再加 12.5%。

MED wins for the same reason the colour map lost: **it stores differences, not a
binary same/different.** On a gradient every pixel differs slightly, so exact
matching finds nothing while MED turns the whole region into near-zero
residuals. The recurring lesson across all three rejected proposals — palette,
flag byte, directional similarity — is that **duplicating what the compressor
already does costs more than it saves; feeding it something more compressible is
what pays.**

MED 勝出的理由與調色盤落敗的理由相同：**它儲存的是差值，而非「相同／不同」的
二元判斷。** 漸層上每個像素都略有差異，完全比對一無所獲，MED 卻能把整個區域轉為
接近零的殘差。三個被否決的提案——調色盤、旗標位元組、方向相似性——反覆指向同一
個教訓：**重複壓縮器已在做的事，代價高於收益；餵給它更好壓的東西才有回報。**

## Can RGB1 get NV12's zero-copy upload advantage?

## RGB1 能拿到 NV12 的零拷貝上傳優勢嗎？

**Q: NV12 can be wrapped as Metal textures with no CPU copy. RGB1 has to be
padded to RGBA first, since Metal has no 24-bit texture format. Is that gap
unavoidable?**
**Q: NV12 可以零拷貝包成 Metal texture。RGB1 則必須先補成 RGBA，因為 Metal 沒有
24-bit 的 texture 格式。這個差距無法避免嗎？**

**No — the planar layout adopted for compression turns out to remove it.** The
predictive stack already stores the payload as RRR...GGG...BBB..., which is
exactly what a three-plane upload wants: three `r8Unorm` textures assembled in a
fragment shader, the same technique NV12 uses for its Y and UV planes.

**可以避免——為壓縮而採用的 planar 排列恰好消除了此差距。** 預測式堆疊已將
payload 儲存為 RRR…GGG…BBB…，這正是三平面上傳所需：三個 `r8Unorm` texture，於
fragment shader 組合，與 NV12 處理其 Y 與 UV 平面的手法相同。

Measured with `P6-DOE.swift` on an Apple M4, 1920x1080, best of 60, both paths
read back and compared pixel for pixel:

以 `P6-DOE.swift` 在 Apple M4 上實測，1920x1080，取 60 次最佳，兩條路徑皆讀回並
逐像素比對：

| path | cpu ms | upload+gpu ms | total |
|---|---:|---:|---:|
| A  RGBA interleave + 1 texture (P6 today) | 1.08 | ~1.04 | **2.12** |
| **B  3 plane textures, RGB order** | **0.00** | **~1.01** | **1.01** |
| **C  3 plane textures, ffmpeg `gbrp` order** | **0.00** | **~1.01** | **1.01** |

Median of five runs at 200 iterations each; the GPU column varied by up to 60%
between runs at lower iteration counts and is quoted approximately for that
reason.

五次執行、每次 200 次迭代的中位數；GPU 欄位在較低迭代數時各次之間相差可達 60%，
故以近似值標示。

**All three render identical pixels; the plane paths save 1.11 ms/frame (52%).**
Two results were not expected. First, **three samples are not more expensive on
the GPU** — the upload drops from 4 B/px to 3 B/px and that bandwidth saving
covers the extra sampling. B and C are indistinguishable, so ffmpeg's `gbrp`
plane order costs nothing. Second, **the alpha expansion costs 1.08 ms, not the
~8 ms estimated earlier** in this FAQ from an old single-threaded ffmpeg figure
that included unrelated conversion work.

**三條路徑渲染結果完全相同；平面路徑省下 1.11 ms/frame（52%）。** 其中兩項結果
出乎意料。其一，**三次取樣在 GPU 上並不更貴**——上傳量從 4 B/px 降為 3 B/px，該
頻寬節省足以覆蓋額外取樣的成本。B 與 C 無從區分，故 ffmpeg 的 `gbrp` 平面順序
不需付出任何代價。其二，**補 alpha 的成本是 1.08 ms，而非本 FAQ 先前估計的約
8 ms**，那個數字源自一份含有無關轉換工作的舊單執行緒 ffmpeg 量測。

> **Corrected 2026-08-14.** This table first read A 3.40 ms / B 1.45 ms, saving
> 1.76 ms (56.9%). Path A was reallocating an 8 MB staging buffer every frame,
> which `rgba_vs_rgb1.md` explicitly advises against — so the arm being measured
> was not the one that document tells you to write, and A was overstated by 60%.
> Reusing the buffer through a local pointer (indexing it as a global was slower
> still, because Swift checks exclusive access on every global subscript) brings
> A to 1.08 ms. The conclusion holds; the margin was inflated. Raised in review
> by the Windows-side reader.
>
> **2026-08-14 更正。** 本表最初為 A 3.40 ms / B 1.45 ms、節省 1.76 ms（56.9%）。
> 路徑 A 每格都重新配置 8 MB 暫存緩衝區，而 `rgba_vs_rgb1.md` 明確建議不要如此
> ——即所量測的組別並非該文件所教的寫法，A 因而高估六成。改以區域指標重用緩衝區
> （直接以全域索引更慢，因 Swift 對每次全域下標都會檢查獨佔存取）後，A 降至
> 1.08 ms。結論不變，但差距被誇大了。此問題由 Windows 端讀者於 review 中提出。

With that, the client-side budget closes:

據此，客戶端預算得以收斂：

| client work / 客戶端工作 | ms/frame |
|---|---:|
| zstd decode + inverse transform (slices=20, -n 20) | 9.8 |
| three-plane upload + GPU render | 1.3 |
| **total** | **11.1** |

**60 fps budget is 16.67 ms — it fits, with 33% to spare.** Note this changes
only the consumer side; the RGB1 container itself is untouched.

**60 fps 預算為 16.67 ms——通過，尚餘 33%。** 注意這僅改變消費端；RGB1 容器本身
未受任何變動。

## Should the RGB1 payload be stored as ffmpeg's `gbrp` instead of interleaved?

## RGB1 payload 該改存 ffmpeg 的 `gbrp` 而非交錯排列嗎？

**Q: The predictive stack already produces planar data, and a three-plane GPU
upload wants planar. Storing the payload as `gbrp` would make both free.**
**Q: 預測式堆疊本來就產出 planar 資料，三平面 GPU 上傳也需要 planar。把 payload
存成 `gbrp` 可讓兩者都免費。**

**Implemented, measured, and reverted: the original interleaved definition
stands.** Direct compression of the container is materially worse in planar, and
the cost grows with the level:

**實作、量測後回退：維持原本的交錯定義。** 直接壓縮容器時 planar 明顯較差，且
代價隨等級上升：

| zstd | rgb24 interleaved | gbrp planar | planar cost |
|---|---:|---:|---:|
| -1 | 3,459,994 (55.61%) | 3,938,416 (63.30%) | +13.8% |
| -3 | 2,984,389 (47.97%) | 3,686,531 (59.25%) | +23.5% |
| -9 | 2,644,767 (42.51%) | 3,337,981 (53.65%) | +26.2% |
| **-19** | **2,315,357 (37.21%)** | 3,042,759 (48.91%) | **+31.4%** |

Measured on 48 containers — 24 frames emitted in both layouts from one decode,
so the two arms are pixel-identical by construction.

以 48 個容器實測 —— 24 格由同一次解碼產出兩種版面，故兩組從構造上即完全相同。

**Why interleaving wins here.** Within one pixel, R, G and B are strongly
correlated: a grey pixel has R≈G≈B, and interleaved those three bytes are
adjacent, so an LZ matcher finds them within a few bytes. Planar separates them
by `width * height` — 2.07 MB at 1080p, far beyond any practical match window.
Longer windows at higher levels exploit that adjacency more, which is exactly why
the planar penalty grows from 13.8% to 31.4% rather than shrinking.

**交錯排列為何在此勝出。** 單一像素內的 R、G、B 高度相關：灰色像素 R≈G≈B，交錯
排列下這三個位元組相鄰，LZ 匹配器在數個位元組內即可找到。planar 則將它們拉開
`width * height`——1080p 為 2.07 MB，遠超任何實用的匹配視窗。高等級的較長視窗更能
利用這份相鄰性，這正是 planar 的懲罰從 13.8% 增至 31.4%（而非縮小）的原因。

**This does not contradict the earlier `+planar -2.5%` result.** That was
measured *after* MED, where every byte is a near-zero residual; grouping by
channel then puts similar-magnitude runs together and the entropy stage benefits.
**Planar helps after prediction and hurts before it** — the two measurements
describe different inputs and both hold.

**這與先前 `+planar -2.5%` 的結果並不矛盾。** 該結果量測於 MED **之後**，當時每個
位元組都是接近零的殘差；按通道分組會把相似量級的長串聚在一起，熵編碼階段因而
獲益。**planar 在預測之後有幫助，在預測之前有害** —— 兩份量測描述的是不同的輸入，
且皆成立。

**What survives the revert.** The streaming path is unaffected: it applies
`YCoCg-R -> MED -> planar` regardless of what the container stores, so the
813 Mbps figure does not move. `P6-DOE` path C still demonstrates that ffmpeg's
`gbrp` byte order feeds a three-plane upload with no byte movement — that
interop holds at the GPU layer whatever the container does.

**回退後仍然成立的部分。** 串流路徑不受影響：無論容器儲存什麼，它都會套用
`YCoCg-R → MED → planar`，故 813 Mbps 這個數字不變。`P6-DOE` 的路徑 C 仍然證明
ffmpeg 的 `gbrp` 位元組順序可零搬移地餵入三平面上傳 —— 該互通性在 GPU 層成立，
與容器如何儲存無關。
