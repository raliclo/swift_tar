# RGB1 Raw Image Format / RGB1 原始影像格式

## Purpose / 目的

RGB1 is a minimal custom binary image container for one uncompressed RGB frame
with fixed geospatial and creator metadata. It is intended as the source frame
format for the 4K60 storybook/zstd stream work before adding delta stepping.

RGB1 是單張未壓縮 RGB frame 加固定地理與建立者 metadata 的極簡自訂二進位
容器。它用於 4K60 storybook/zstd stream 的來源 frame 格式，之後再在其上加
入 delta stepping。

## Binary Layout / 二進位配置

The whole header is binary. There is no JSON, XML, CSV, key/value text block,
or delimiter-separated metadata. All integer fields are big-endian values.
`lat_e7` and `lng_e7` are signed fixed-point values: decimal degrees multiplied
by 10,000,000. `height_mm` is a signed height in millimeters. The initial datum
code is `1`, meaning WGS84 latitude/longitude with ellipsoid height. Fixed text
fields are stored as raw ASCII byte arrays, NUL-padded, and contain no NUL bytes
inside the stored text. `right` is a compact rights code of 1 to 4 English
letters. `created_unix_ms` is a signed UTC Unix timestamp in milliseconds.
`timezone_offset_minutes` is a signed offset from UTC in minutes and defaults
to `480` for Taiwan time (UTC+08:00).

整個 header 都是二進位格式。沒有 JSON、XML、CSV、key/value 文字區塊，也沒
有 delimiter-separated metadata。所有整數欄位皆為 big-endian。`lat_e7` 與
`lng_e7` 是 signed fixed-point：十進位角度乘以 10,000,000。`height_mm` 是
signed millimeters。初始 datum code 為 `1`，代表 WGS84 latitude/longitude 加
ellipsoid height。固定文字欄位以 raw ASCII byte array 儲存，使用 NUL padding，
文字本體不可含 NUL。`right` 是 1 到 4 個英文字母的緊湊權利代碼。
`created_unix_ms` 是 signed UTC Unix timestamp，單位 milliseconds。
`timezone_offset_minutes` 是 signed UTC offset，單位分鐘，預設為台灣時區
`480`（UTC+08:00）。

> **Before proposing a payload change, read this.** Four payload redesigns have
> been implemented, measured against real 1080p frames, and rejected. Because
> each was reverted, none of them appears in the git history — only this table
> records that the experiment happened. Re-proposing one of these needs new
> evidence, not new intuition. Full measurements and reasoning are in `FAQ.md`.
>
> **提出 payload 變更前請先閱讀。** 已有四項 payload 重新設計經過實作、以真實
> 1080p 影格量測後遭否決。由於每一項都已回退，git 歷史中不會留下任何痕跡——
> 只有本表記錄這些實驗曾經發生。要重提其中任一項，需要新的證據而非新的直覺。
> 完整量測與推論見 `FAQ.md`。
>
> | proposal / 提案 | measured result / 量測結果 |
> |---|---|
> | store payload as ffmpeg `gbrp` (planar) | +13.8% to +31.4% larger compressed, worse at higher zstd levels / 壓縮後大 13.8%–31.4%，等級越高越差 |
> | colour map + bit-packed pointers | +23.5% larger compressed, though 25.8% smaller uncompressed / 壓縮後大 23.5%，儘管未壓縮小 25.8% |
> | directional similarity (zero RGB on a neighbour match) | 53.50% of raw vs 49.82% for doing nothing / 53.50% 對「什麼都不做」的 49.82% |
> | in-band scan-line delimiter | `0x0A` is a legal pixel value; breaks O(1) row addressing / `0x0A` 是合法像素值，且破壞 O(1) 列定址 |
>
> The recurring reason for the first three: **they duplicate work the compressor
> already does, and pay a per-pixel overhead for it.** What pays instead is
> feeding the compressor something more compressible — spatial prediction (MED)
> turns pixels into near-zero residuals and wins by 40.8%.
> 前三項反覆出現的原因：**它們重複了壓縮器已經在做的事，還為此付出每像素的
> 額外成本。** 真正有回報的是餵給壓縮器更好壓的東西——空間預測（MED）把像素
> 轉為接近零的殘差，勝出 40.8%。

| Offset | Size | Field | Description |
|---:|---:|---|---|
| 0 | 4 | magic | ASCII `RGB1` |
| 4 | 4 | width | UInt32 pixel width |
| 8 | 4 | height | UInt32 pixel height |
| 12 | 4 | flags | UInt32, bit 0 = geo metadata present |
| 16 | 4 | lat_e7 | Int32 latitude degrees * 10,000,000 |
| 20 | 4 | lng_e7 | Int32 longitude degrees * 10,000,000 |
| 24 | 4 | height_mm | Int32 height in millimeters |
| 28 | 4 | geo_datum_code | UInt32, `1` = WGS84 + ellipsoid height |
| 32 | 64 | title | ASCII title, length `< 64` bytes |
| 96 | 512 | country | ASCII country, length `< 512` bytes |
| 608 | 254 | creator_email | ASCII email, length `<= 254` bytes |
| 862 | 4 | right | ASCII rights code, 1 to 4 English letters |
| 866 | 8 | created_unix_ms | Int64 UTC Unix milliseconds |
| 874 | 2 | timezone_offset_minutes | Int16 UTC offset minutes; TW default = 480 |
| 876 | width * height * 3 | payload | Raw RGB bytes, row-major, 8-bit R,G,B |

The payload has no padding and no per-row stride field. For 4K:

payload 沒有 padding，也沒有 per-row stride 欄位。4K 大小如下：

```text
3840 * 2160 * 3 = 24,883,200 bytes
RGB1 file size = 24,884,076 bytes
```

## CLI / 命令列

Pack raw RGB bytes into RGB1:

將 raw RGB bytes 包成 RGB1：

```sh
swift_tar --rgb1-pack --width 3840 --height 2160 \
  --lat 25.033964 --lng 121.564468 --height-m 12.345 \
  --title "Taipei Dawn" --country "Taiwan" --creator-email "creator@example.com" \
  --right "CCBY" --created-ms 1784457600000 --tz-offset-min 480 \
  -f frame.rgb1 frame.rgb
```

Read metadata:

讀取 metadata：

```sh
swift_tar --rgb1-info -f frame.rgb1
```

Strip the header and write raw RGB payload to stdout:

移除標頭，將 raw RGB payload 輸出到 stdout：

```sh
swift_tar --rgb1-raw -f frame.rgb1 > frame.rgb
```

## Zstd Usage / Zstd 用法

RGB1 itself is uncompressed. The level depends on whether the frame is being
archived or streamed — they are not the same decision:

RGB1 本身不壓縮。等級取決於影格是要封存還是串流，兩者並非同一個決定：

| use / 用途 | level | measured cost / 實測成本 |
|---|---|---|
| archive / 封存 | `-19` | 6,040 ms/frame at 1080p — offline only / 僅適用離線 |
| **stream / 串流** | **`-3`** | **encode 15.4 ms, decode 9.8 ms per frame** |

Level 9 was recommended here previously; measurement retired it. At 1080p it
costs 168 ms/frame, which overruns even a 30 fps budget (33.3 ms), while giving
up only a few percent of size against `-3`. See
`../verifications/rgb1/streaming_budget_benchmark.sh`.

此處先前建議 level 9，量測後已淘汰該建議。1080p 下它要 168 ms/frame，連 30 fps
的預算（33.3 ms）都塞不下，而相對 `-3` 只換到數個百分點的體積。詳見
`../verifications/rgb1/streaming_budget_benchmark.sh`。

```sh
zstd -3 frame.rgb1 -o frame.rgb1.zst      # stream / 串流
zstd -19 frame.rgb1 -o frame.rgb1.zst     # archive / 封存
zstd -dc frame.rgb1.zst > frame.rgb1
swift_tar --rgb1-info -f frame.rgb1
```

Note: `--rgb1-info -f -` and `--rgb1-raw -f -` are not implemented yet; the
current info/raw commands require a file path. This is a follow-up item for
streaming integration.

注意：`--rgb1-info -f -` 與 `--rgb1-raw -f -` 尚未實作；目前 info/raw 命令需
要檔案路徑。這是後續 streaming integration 的待辦。

## Follow-up / 後續

- Add stdin support for `--rgb1-info` and `--rgb1-raw`.
- Add RGB1.ZST detection by stacking zstd decode before RGB1 parsing.
- Add `RGBD1` or `RGS1` stream format for keyframe + diff stepping.

- 為 `--rgb1-info` 與 `--rgb1-raw` 加入 stdin 支援。
- 加入 RGB1.ZST 偵測：先做 zstd decode，再解析 RGB1。
- 新增 `RGBD1` 或 `RGS1` stream 格式，用於 keyframe + diff stepping。

### Resolved: the display path stays RGB / 已決議：顯示路徑維持 RGB

The open question "does the long-term display path remain RGB or move to
YUV/NV12" is closed: **RGB1 stays RGB.** NV12 does transfer 1.73x smaller after
compression, but that advantage is only collectable by going through a hardware
video decoder, which means giving up RGB1 entirely. Measurements behind this:

「長期顯示路徑維持 RGB 或改走 YUV/NV12」此一未決問題已收斂：**RGB1 維持 RGB。**
NV12 壓縮後的傳輸量確實小 1.73 倍，但該優勢唯有走硬體視訊解碼器才拿得到，而那
等同完全放棄 RGB1。支持此決議的量測：

- Channel order is already correct for the GPU. P6 uploads to a `.rgba8Unorm`
  texture, so R-first needs **no swap**; the `.bgra8Unorm` seen in P6 is the
  framebuffer format, ordered by the GPU's fixed-function ROP at no cost.
  通道順序對 GPU 而言已經正確。P6 上傳至 `.rgba8Unorm` texture，R 在前**無需
  swap**；P6 中的 `.bgra8Unorm` 是 framebuffer 格式，由 GPU 固定功能 ROP 排序，
  不耗成本。
- Planar data can be uploaded as **three `r8Unorm` plane textures** and assembled
  in a fragment shader, the same technique NV12 uses for its Y and UV planes,
  removing the RGB->RGBA alpha expansion from the client path. Measured at
  1.31 ms/frame versus 3.40 ms for the interleaved-plus-alpha path, rendering
  identical pixels (`P6-DOE`). Note this applies to the **streaming** path,
  whose decoder already emits planar; the container itself stores interleaved
  R,G,B, and reading one straight from disk still needs a de-interleave first.
  planar 資料可以**三個 `r8Unorm` 平面 texture** 上傳，於 fragment shader 組合，
  與 NV12 處理 Y 與 UV 平面的手法相同，可將 RGB→RGBA 的 alpha 擴張移出客戶端
  路徑。實測為 1.31 ms/frame，對比交錯加補 alpha 的 3.40 ms，且渲染像素完全相同
  （`P6-DOE`）。注意此適用於**串流**路徑，其解碼器本就輸出 planar；容器本身儲存
  交錯 R,G,B，直接從磁碟讀取仍須先解交錯。
- Storing the payload as `gbrp` was implemented, measured and reverted: it costs
  13.8% to 31.4% on direct container compression depending on zstd level. See
  `FAQ.md`.
  將 payload 改存 `gbrp` 曾經實作、量測並回退：依 zstd 等級不同，直接壓縮容器會
  多付 13.8% 至 31.4%。詳見 `FAQ.md`。
- See `FAQ.md` for the full NV12 vs RGB1 comparison.
  完整的 NV12 與 RGB1 比較見 `FAQ.md`。
