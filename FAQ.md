# FAQ

Notes from ad-hoc design questions about the RGB1 format and downstream
display pipeline (P6). Not exhaustive — see `rgb1/rgb1-format.md` and
`rgba_vs_rgb1.md` for the primary format docs.

關於 RGB1 格式與下游顯示 pipeline(P6)的臨時設計問答筆記。非完整文件——
主要格式文件請見 `rgb1/rgb1-format.md` 與 `rgba_vs_rgb1.md`。

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
| Needs conversion to display | yes, YUV->RGB (shader or CPU) | yes, RGB->RGBA (see `rgba_vs_rgb1.md`) |
| Compression friendliness | good for video codecs (chroma subsampling already exploits eye insensitivity to chroma) | general-purpose compressors (zstd) don't get the same win from raw RGB |

NV12 is roughly half the size of RGB1 per pixel (4:2:0 chroma subsampling)
and is the native output format of hardware video decoders, so it fits a
continuous video-stream pipeline. RGB1 is a general single-frame snapshot
container with fixed geo/creator metadata; it has no chroma subsampling and
no hardware-native producer/consumer. Which one is the right "long-term
display path" (per the open follow-up in `rgb1/rgb1-format.md`) depends on
whether the target is single snapshots (RGB1 is sufficient and simpler) or
a continuous 4K60 video stream (NV12 is the closer fit).

NV12 每像素體積約為 RGB1 的一半（4:2:0 色度取樣），且是硬體視訊解碼器的
原生輸出格式，適合連續視訊串流的 pipeline。RGB1 是通用的單張快照容器，
帶固定地理／建立者 metadata，沒有色度取樣，也沒有硬體原生的產生／消費端。
究竟哪個才是「長期顯示路徑」（`rgb1/rgb1-format.md` 的待決 follow-up）
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
   `rgba_vs_rgb1.md`) already pays for a YUV->RGB conversion inside ffmpeg.
   If Metal consumes NV12 directly and does the YUV->RGB matrix multiply in
   a fragment shader, that conversion pass (and its extra full-frame
   read+write) disappears from the CPU/pre-GPU path entirely.
   跳過一次整張影格的 YUV→RGB 轉換。硬體解碼器（VideoToolbox）原生輸出就是
   NV12（BiPlanar 420v/420f）的 `CVPixelBuffer`。目前的 pipeline
   （`ffmpeg -> RGBA frame -> Metal/WinUI`，見 `rgba_vs_rgb1.md`）已經在
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
