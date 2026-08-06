# RGBA 與 RGB1 的差異

## 摘要

RGBA 與 RGB1 都可以表示一張 8-bit 影像，但設計目標不同：

- **RGBA** 適合即時顯示、GPU 紋理與視窗渲染。
- **RGB1** 適合儲存、傳輸與保留影像及地理 metadata。
- 對 P6 而言，建議檔案層使用 RGB1，解碼後轉成 RGBA，再交給 Metal 或 WinUI 顯示。

## 基本格式差異

| 項目 | RGBA | RGB1 |
|---|---|---|
| 每像素資料 | R、G、B、Alpha，共 4 bytes | R、G、B，共 3 bytes |
| Alpha 通道 | 有，可表示透明度 | 沒有，視為不透明影像 |
| 格式性質 | 通常是記憶體中的像素排列或影像格式 | 自訂的 RGB1 二進位容器 |
| Metadata | 依實際容器格式而定 | 固定包含寬、高、地理位置、標題、國家、建立者等欄位 |
| P6 顯示相容性 | 直接相容 | 必須先轉換成 RGBA |

RGB1 的標頭固定為 876 bytes，payload 是沒有 padding 的 row-major RGB 資料。格式定義位於 `rgb1/rgb1-format.md`。

## 記憶體與頻寬

RGB1 每像素使用 3 bytes，RGBA 每像素使用 4 bytes，因此 RGB1 的原始影像資料量比 RGBA 少 25%。

以 3840×2160 的 4K 單影格為例：

```text
RGB1 payload = 3840 × 2160 × 3 = 24,883,200 bytes
RGBA payload = 3840 × 2160 × 4 = 33,177,600 bytes
```

因此，RGB1 可以降低：

- 磁碟空間
- 網路傳輸量
- 從儲存裝置讀取的資料量
- 未壓縮影格的記憶體頻寬

若以 60 FPS 傳送未壓縮 4K 影格，RGB1 約需 1.49 GB/s，RGBA 約需 1.99 GB/s。這是原始資料估算，尚未計入壓縮、封包與轉換成本。

## 顯示效能

P6 目前的影像解碼流程由 `ffmpeg` 直接產生 RGBA frame：

```text
輸入影片 → ffmpeg → RGBA frame → Metal 或 WinUI → 螢幕
```

這條路徑不需要再做 RGB 到 RGBA 的轉換，因此對即時顯示最直接。

如果 P6 直接讀取 RGB1，流程會變成：

```text
RGB1 檔案 → 讀取 RGB payload → RGB 轉 RGBA → Metal 或 WinUI → 螢幕
```

轉換需要額外讀取一次 RGB 資料並寫出 RGBA 資料，會增加 CPU 工作、記憶體頻寬與延遲。因此 RGB1 雖然檔案較小，但不適合直接作為 GPU 顯示紋理。

## 壓縮效能

目前 `swift_tar` 的 RGB1 驗證使用 1024×1024、3 MiB payload 的高度可壓縮合成影像。zstd 結果如下：

| 項目 | 結果 |
|---|---:|
| 建立吞吐量 | 262.2 MB/s |
| 解出吞吐量 | 228.0 MB/s |
| 壓縮後大小 | 4,567 bytes |

這組資料不能代表真實照片或影片，因為測試內容由重複的 4 KiB 區塊組成。詳細結果見 `verifications/rgb1_container_mbps_output.txt`，測試限制見 `verifications/README.zh-TW.md`。

目前驗證資料沒有相同條件的正式 RGBA 基準，因此不能從現有報告宣稱 RGB1 一定比 RGBA 壓縮或解壓更快。

固定 Alpha 值在某些壓縮器中非常容易壓縮，所以 RGBA 的壓縮檔案大小可能接近 RGB1，甚至在特殊資料上略小；但未壓縮輸入、記憶體占用與顯示端轉換成本仍然較高。

## 選擇建議

### 選擇 RGB1 的情況

- 影像主要用於儲存或傳輸。
- 需要固定的地理與建立者 metadata。
- 希望降低原始影像大小與 I/O 頻寬。
- 可以接受在顯示前做一次 RGB 到 RGBA 的轉換。

### 選擇 RGBA 的情況

- 影像要直接交給 Metal、WinUI 或其他 GPU API。
- 需要透明度。
- 需要最低的顯示端延遲。
- 解碼器本身已經輸出 RGBA，沒有必要增加中間格式轉換。

## P6 建議架構

P6 目前應維持以下分工：

1. 儲存層可使用 RGB1 或 RGB1.ZST，以降低檔案與傳輸成本。
2. 解碼層讀取 RGB1 payload。
3. 解碼完成後一次建立 RGBA buffer。
4. Metal 與 WinUI 直接使用 RGBA buffer 渲染。

不建議每次繪製影格時重複進行 RGB 到 RGBA 轉換；應在影格解碼階段完成，並盡量重用輸出 buffer。

## 結論

若只看檔案大小、I/O 與原始記憶體頻寬，RGB1 較有效率；若只看 P6 的即時畫面渲染，RGBA 較有效率。整體最佳方案是「RGB1 儲存，RGBA 顯示」，而不是在兩者之間只選一種格式使用於所有階段。
