// =====================================================================
//  rgb1_sampler.swift — sample a video into RGB1 containers
//  rgb1_sampler.swift — 將影片取樣為 RGB1 容器
//
//  Builds the DOE corpus for verifications/rgb1: pulls one frame every N
//  seconds and wraps each in an RGB1 container, named by its timestamp so the
//  sequence is self-describing on disk.
//  產生 verifications/rgb1 的 DOE 語料：每 N 秒取一格並包成 RGB1 容器，檔名
//  以時間戳命名，使序列在磁碟上即可自我說明。
//
//  Frames come from ffmpeg, the same way swift_tar already shells out to the
//  external codecs. RGB1 packing is done here rather than by invoking
//  swift_tar, so the sampler stays a single self-contained file.
//  影格由 ffmpeg 取得，與 swift_tar 既有呼叫外部 codec 的方式一致。RGB1 封裝
//  在此直接完成，而非再呼叫 swift_tar，讓 sampler 維持單一自足檔案。
//
//  Build / 建置:
//    swiftc -O rgb1_sampler.swift ../../rgb1.swift -o rgb1_sampler
//
//  Usage / 用法:
//    ./rgb1_sampler <video> [interval-seconds] [output-dir]
//    defaults / 預設: interval 10 s, output ./sample
// =====================================================================

import Foundation

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

/// Run a tool and return its stdout, or nil when it is unavailable or fails.
/// 執行工具並回傳其 stdout；若工具不存在或失敗則回傳 nil。
private func capture(_ launchPath: String, _ args: [String]) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: launchPath)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { return nil }
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

private func which(_ tool: String) -> String? {
    for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] {
        let path = dir + "/" + tool
        if FileManager.default.isExecutableFile(atPath: path) { return path }
    }
    return nil
}

// swiftc only allows top-level statements in main.swift, and this is compiled
// together with rgb1.swift, so the body lives in @main.
// swiftc 僅允許 main.swift 有頂層敘述，而本檔與 rgb1.swift 一起編譯，故主體
// 置於 @main 內。
@main
struct RGB1Sampler {
static func main() throws {
// ---- arguments / 參數 ----
// Flags are pulled out first so the positional arguments keep their order.
// 先取出旗標，使位置引數維持原有順序。
var argv = Array(CommandLine.arguments.dropFirst())
let wantsClean = argv.contains("--clean") || argv.contains("--clean-only")
let cleanOnly = argv.contains("--clean-only")

// --out names the directory explicitly. Relying on positional order for a
// destructive flag is how the corpus got deleted once already: `--clean-only x
// dir` parses `dir` as the interval and silently falls back to ./sample.
// --out 明確指定目錄。讓破壞性旗標依賴位置順序，正是語料曾被誤刪的原因：
// `--clean-only x dir` 會把 dir 當成間隔秒數，並靜默退回 ./sample。
var explicitOut: String? = nil
if let i = argv.firstIndex(of: "--out"), i + 1 < argv.count {
    explicitOut = argv[i + 1]
    argv.removeSubrange(i...(i + 1))
}
argv.removeAll { $0.hasPrefix("--") }

guard cleanOnly || !argv.isEmpty else {
    fail("""
    Usage: rgb1_sampler [--clean|--clean-only] <video> [interval-seconds] [output-dir]
    用法： rgb1_sampler [--clean|--clean-only] <影片> [間隔秒數] [輸出目錄]
      interval defaults to 10, output-dir defaults to ./sample
      間隔預設 10 秒，輸出目錄預設 ./sample
      --clean       remove existing *.rgb1 from the output dir first
                    先移除輸出目錄中既有的 *.rgb1
      --clean-only  remove them and exit, sampling nothing
                    只移除並結束，不進行取樣
    """)
}
let outDir = explicitOut ?? (argv.count > 2 ? argv[2] : "sample")

// A full sweep of a long video writes gigabytes of uncompressed frames, so the
// corpus is cleared explicitly rather than accumulating stale runs.
// 對長影片做完整取樣會寫出數 GB 的未壓縮影格，故明確清空語料，避免累積過期結果。
if wantsClean {
    // Name the target before removing anything: a destructive default that is
    // never printed is a defect, not a convenience.
    // 刪除前先報出目標：一個從不顯示的破壞性預設值是缺陷，不是便利。
    print("[Clean] target / 目標: \(outDir)/"
          + (explicitOut == nil ? "  (default — pass --out DIR to change / 預設值)" : ""))
    let stale = (try? FileManager.default.contentsOfDirectory(atPath: outDir))?
        .filter { $0.hasSuffix(".rgb1") } ?? []
    var freed = 0
    for name in stale {
        let path = outDir + "/" + name
        freed += (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int)
            .flatMap { $0 } ?? 0
        try? FileManager.default.removeItem(atPath: path)
    }
    print("[Clean] removed \(stale.count) file(s), freed "
          + String(format: "%.1f MB", Double(freed) / 1e6)
          + " / 已移除 \(stale.count) 個檔案")
    if cleanOnly { return }
}

guard !argv.isEmpty else { fail("no video given / 未指定影片") }
let videoPath = argv[0]
let interval = argv.count > 1 ? (Double(argv[1]) ?? 10) : 10

guard interval > 0 else { fail("interval must be positive / 間隔必須為正數") }
guard FileManager.default.fileExists(atPath: videoPath) else {
    fail("video not found: \(videoPath) / 找不到影片")
}
guard let ffmpeg = which("ffmpeg"), let ffprobe = which("ffprobe") else {
    fail("ffmpeg and ffprobe are required on PATH / 需要 ffmpeg 與 ffprobe")
}

// ---- probe the source / 探測來源 ----
func probe(_ field: String) -> String? {
    capture(ffprobe, ["-v", "error", "-select_streams", "v:0",
                      "-show_entries", "stream=\(field)", "-of", "csv=p=0", videoPath])
}
guard let wText = probe("width"), let width = Int(wText),
      let hText = probe("height"), let height = Int(hText) else {
    fail("cannot read video dimensions / 無法讀取影片尺寸")
}
let durationText = capture(ffprobe, ["-v", "error", "-show_entries", "format=duration",
                                     "-of", "csv=p=0", videoPath])
let duration = Double(durationText ?? "") ?? 0

try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

print("[Info] source / 來源: \(URL(fileURLWithPath: videoPath).lastPathComponent)")
print("[Info] \(width)x\(height), duration \(String(format: "%.1f", duration)) s, interval \(interval) s")
print("[Info] output / 輸出: \(outDir)/")

// ---- extract every frame at once, then split / 一次取出所有影格再切分 ----
// One ffmpeg pass with fps=1/interval is far cheaper than seeking per frame.
// 單次 ffmpeg 以 fps=1/interval 取出，遠比逐格 seek 便宜。
let rawPath = NSTemporaryDirectory() + "rgb1_sampler_\(UUID().uuidString).rgb24"
defer { try? FileManager.default.removeItem(atPath: rawPath) }

let extract = Process()
extract.executableURL = URL(fileURLWithPath: ffmpeg)
extract.arguments = ["-v", "error", "-i", videoPath,
                     "-vf", "fps=1/\(interval)",
                     "-pix_fmt", "rgb24", "-f", "rawvideo", rawPath, "-y"]
extract.standardError = FileHandle.standardError
try extract.run()
extract.waitUntilExit()
guard extract.terminationStatus == 0 else { fail("ffmpeg failed / ffmpeg 執行失敗") }

let frameBytes = width * height * 3
guard let raw = FileManager.default.contents(atPath: rawPath), raw.count >= frameBytes else {
    fail("no frames extracted / 未取得任何影格")
}
let frameCount = raw.count / frameBytes

// ---- wrap each frame in an RGB1 container / 將每格包成 RGB1 容器 ----
// Named by the timestamp it was sampled at, zero-padded so lexical order
// matches time order.
// 以取樣時間戳命名，補零使字典序與時間序一致。
var written = 0
for index in 0..<frameCount {
    let seconds = Int((Double(index) * interval).rounded())
    let name = String(format: "t%06ds.rgb1", seconds)
    let payload = raw.subdata(in: (index * frameBytes)..<((index + 1) * frameBytes))

    // The geo fields describe where the frame was captured; a sampler has no
    // real position, so record a fixed one and say so in the title.
    // geo 欄位描述影格的拍攝位置；sampler 無真實座標，故填固定值並於標題註明。
    do {
        let image = try RGB1Image(
            width: UInt32(width),
            height: UInt32(height),
            latitudeE7: 250_330_000,
            longitudeE7: 1_215_654_000,
            heightMillimeters: 10_000,
            title: "sample t+\(seconds)s",
            country: "TW",
            creatorEmail: "sampler@swift-tar.local",
            right: "CcBy",
            createdUnixMilliseconds: Int64(Date().timeIntervalSince1970 * 1000),
            payload: payload)
        try image.fileData.write(to: URL(fileURLWithPath: outDir + "/" + name))
        written += 1
    } catch {
        fail("frame \(index): \(error.localizedDescription)")
    }
}

print("[Done] wrote \(written) RGB1 containers / 已寫出 \(written) 個 RGB1 容器")
print("       \(frameBytes) B payload + 876 B header each / 每個 payload \(frameBytes) B 加 876 B 標頭")
}
}
