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

Follow-up / 後續:

- Compile and smoke-test the RGB1 CLI operations.
- 編譯並 smoke-test RGB1 CLI operations。
- Add stdin support for `--rgb1-info` and `--rgb1-raw`.
- 為 `--rgb1-info` 與 `--rgb1-raw` 加入 stdin 支援。
- Define the stream-level container for keyframe + diff stepping on top of
  RGB1 frames.
- 在 RGB1 frame 之上定義 keyframe + diff stepping 的 stream-level container。
