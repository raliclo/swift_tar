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

RGB1 itself is uncompressed. Use zstd level 9 for storage or transfer:

RGB1 本身不壓縮。儲存或傳輸時使用 zstd level 9：

```sh
zstd -9 frame.rgb1 -o frame.rgb1.zst
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
- Decide whether the long-term display path remains RGB or moves to YUV/NV12.

- 為 `--rgb1-info` 與 `--rgb1-raw` 加入 stdin 支援。
- 加入 RGB1.ZST 偵測：先做 zstd decode，再解析 RGB1。
- 新增 `RGBD1` 或 `RGS1` stream 格式，用於 keyframe + diff stepping。
- 決定長期顯示路徑維持 RGB，或改走 YUV/NV12。
