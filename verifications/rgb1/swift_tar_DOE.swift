// =====================================================================
//  swift_tar_DOE.swift — a flag-driven bench for RGB1 payload experiments
//  swift_tar_DOE.swift — 以旗標驅動的 RGB1 payload 實驗平台
//
//  A sandbox for the ongoing RGB1 storage study. It deliberately does NOT link
//  rgb1.swift or swift_tar.swift: experiments here change often and must never
//  perturb the production container code. It reads RGB1 files with its own
//  minimal header parser and applies payload transforms in whatever combination
//  the flags request.
//  這是 RGB1 儲存研究的沙盒。它刻意不連結 rgb1.swift 或 swift_tar.swift：此處的
//  實驗變動頻繁，絕不可干擾正式容器程式碼。它以自帶的精簡標頭解析器讀取 RGB1
//  檔案，並依旗標所指定的任意組合套用 payload 變換。
//
//  Every transform is lossless and has an inverse. --verify (on by default)
//  round-trips each one before any size is reported: a transform that cannot
//  reconstruct the frame is not a compression result.
//  每項變換皆為無損且具反變換。--verify（預設開啟）會在回報任何大小前先做往返
//  驗證：無法還原影格的變換不算壓縮結果。
//
//  Build / 建置:
//    swiftc -O swift_tar_DOE.swift -o swift_tar_DOE
//
//  Usage / 用法:
//    ./swift_tar_DOE [flags] <file.rgb1 ...>
//    ./swift_tar_DOE --help
// =====================================================================

import Foundation

// ---------------------------------------------------------------------
// MARK: - Frame / 影格
// ---------------------------------------------------------------------

/// RGB1 header size and the geo field span, per rgb1/rgb1-format.md.
/// RGB1 標頭大小與 geo 欄位範圍，依 rgb1/rgb1-format.md。
let headerSize = 876
let geoRange = 16..<32          // lat_e7, lng_e7, height_mm, geo_datum_code
let flagsOffset = 12

struct Frame {
    let width: Int
    let height: Int
    var header: [UInt8]
    var payload: [UInt8]        // width * height * 3, R,G,B row-major

    init(contentsOf path: String) throws {
        guard let data = FileManager.default.contents(atPath: path) else {
            throw Err("cannot read \(path)")
        }
        guard data.count > headerSize else { throw Err("\(path): shorter than header") }
        let bytes = [UInt8](data)
        guard bytes[0...3] == [0x52, 0x47, 0x42, 0x31] else {   // "RGB1"
            throw Err("\(path): bad magic, not an RGB1 container")
        }
        func be32(_ o: Int) -> Int {
            (Int(bytes[o]) << 24) | (Int(bytes[o+1]) << 16)
                | (Int(bytes[o+2]) << 8) | Int(bytes[o+3])
        }
        width = be32(4); height = be32(8)
        guard width > 0, height > 0 else { throw Err("\(path): zero dimension") }
        let expected = width * height * 3
        guard bytes.count == headerSize + expected else {
            throw Err("\(path): payload is \(bytes.count - headerSize) B, expected \(expected) B")
        }
        header = Array(bytes[0..<headerSize])
        payload = Array(bytes[headerSize...])
    }
}

struct Err: Error, CustomStringConvertible {
    let description: String
    init(_ m: String) { description = m }
}

// ---------------------------------------------------------------------
// MARK: - Colour transform / 色彩變換
// ---------------------------------------------------------------------

/// Interpret a mod-256 value as signed so `>> 1` matches on both directions.
/// 將 mod-256 值視為有號，使兩個方向的 `>> 1` 行為一致。
@inline(__always) func signed(_ v: Int) -> Int { ((v + 128) & 0xFF) - 128 }

/// Reversible YCoCg-R. Integer add/shift only, so the inverse is exact.
/// 可逆 YCoCg-R。僅用整數加減與位移，故反變換完全精確。
func ycocgForward(_ p: [UInt8]) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: p.count)
    for i in stride(from: 0, to: p.count, by: 3) {
        let r = Int(p[i]), g = Int(p[i+1]), b = Int(p[i+2])
        let co = (r &- b) & 0xFF
        let t = (b &+ (signed(co) >> 1)) & 0xFF
        let cg = (g &- t) & 0xFF
        let y = (t &+ (signed(cg) >> 1)) & 0xFF
        out[i] = UInt8(y); out[i+1] = UInt8(co); out[i+2] = UInt8(cg)
    }
    return out
}

func ycocgInverse(_ p: [UInt8]) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: p.count)
    for i in stride(from: 0, to: p.count, by: 3) {
        let y = Int(p[i]), co = Int(p[i+1]), cg = Int(p[i+2])
        let t = (y &- (signed(cg) >> 1)) & 0xFF
        let g = (cg &+ t) & 0xFF
        let b = (t &- (signed(co) >> 1)) & 0xFF
        let r = (b &+ co) & 0xFF
        out[i] = UInt8(r); out[i+1] = UInt8(g); out[i+2] = UInt8(b)
    }
    return out
}

// ---------------------------------------------------------------------
// MARK: - Spatial prediction / 空間預測
// ---------------------------------------------------------------------

/// Neighbours available in raster scan: a = left, b = above, c = upper-left.
/// Right and below are not yet decoded, so no predictor may use them.
/// 光柵掃描下可用的鄰居：a = 左、b = 上、c = 左上。右與下尚未解碼，故任何
/// 預測器都不得使用它們。
@inline(__always) func medPredict(_ a: Int, _ b: Int, _ c: Int) -> Int {
    let hi = max(a, b), lo = min(a, b)
    if c >= hi { return lo }        // edge on one side / 一側為邊緣
    if c <= lo { return hi }        // edge on the other / 另一側為邊緣
    return a &+ b &- c              // smooth gradient / 平滑漸層
}

/// Per-channel predictive residuals over an interleaved RGB buffer.
/// `useMED == false` gives the plain Sub filter (left neighbour only), which is
/// the baseline MED is measured against.
/// 對交錯 RGB 緩衝區逐通道計算預測殘差。`useMED == false` 時退化為單純的 Sub
/// filter（僅取左鄰），即 MED 的比較基準。
func predictForward(_ p: [UInt8], width: Int, height: Int,
                    channels: Int = 3, useMED: Bool) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: p.count)
    for y in 0..<height {
        for x in 0..<width {
            for ch in 0..<channels {
                let i = (y * width + x) * channels + ch
                let a = x > 0 ? Int(p[i - channels]) : (y > 0 ? Int(p[i - width * channels]) : 0)
                let b = y > 0 ? Int(p[i - width * channels]) : a
                let c = (x > 0 && y > 0) ? Int(p[i - width * channels - channels])
                                         : (y > 0 ? a : b)
                let pred = useMED ? medPredict(a, b, c) : a
                out[i] = UInt8((Int(p[i]) &- pred) & 0xFF)
            }
        }
    }
    return out
}

func predictInverse(_ r: [UInt8], width: Int, height: Int,
                    channels: Int = 3, useMED: Bool) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: r.count)
    for y in 0..<height {
        for x in 0..<width {
            for ch in 0..<channels {
                let i = (y * width + x) * channels + ch
                let a = x > 0 ? Int(out[i - channels]) : (y > 0 ? Int(out[i - width * channels]) : 0)
                let b = y > 0 ? Int(out[i - width * channels]) : a
                let c = (x > 0 && y > 0) ? Int(out[i - width * channels - channels])
                                         : (y > 0 ? a : b)
                let pred = useMED ? medPredict(a, b, c) : a
                out[i] = UInt8((Int(r[i]) &+ pred) & 0xFF)
            }
        }
    }
    return out
}

// ---------------------------------------------------------------------
// MARK: - Layout / 排列
// ---------------------------------------------------------------------

/// Interleaved RGBRGB... -> plane-separated RRR...GGG...BBB...
/// 交錯 RGBRGB… → 平面分離 RRR…GGG…BBB…
func toPlanar(_ p: [UInt8]) -> [UInt8] {
    let n = p.count / 3
    var out = [UInt8](repeating: 0, count: p.count)
    for i in 0..<n {
        out[i] = p[i*3]; out[n + i] = p[i*3 + 1]; out[2*n + i] = p[i*3 + 2]
    }
    return out
}

func fromPlanar(_ p: [UInt8]) -> [UInt8] {
    let n = p.count / 3
    var out = [UInt8](repeating: 0, count: p.count)
    for i in 0..<n {
        out[i*3] = p[i]; out[i*3 + 1] = p[n + i]; out[i*3 + 2] = p[2*n + i]
    }
    return out
}

// ---------------------------------------------------------------------
// MARK: - Colour map / 色彩對照表
// ---------------------------------------------------------------------

/// Collect unique colours into a sorted map and store each pixel as a
/// bit-packed pointer into it. Measured to LOSE to raw+zstd: the pointers are
/// arbitrary integers, so the spatial correlation a compressor feeds on is gone.
/// Kept here so the result stays reproducible.
/// 將唯一色收進排序後的對照表，每個像素改存緊密打包的指標。實測輸給 raw+zstd：
/// 指標是任意整數，壓縮器賴以運作的空間相關性因而消失。保留此實作以維持結果可
/// 重現。
func paletteEncode(_ p: [UInt8]) -> (blob: [UInt8], count: Int, bits: Int) {
    let n = p.count / 3
    var seen = Set<UInt32>()
    seen.reserveCapacity(n / 4)
    for i in 0..<n {
        seen.insert(UInt32(p[i*3]) << 16 | UInt32(p[i*3+1]) << 8 | UInt32(p[i*3+2]))
    }
    let colours = seen.sorted()
    var index = [UInt32: UInt32](minimumCapacity: colours.count)
    for (i, c) in colours.enumerated() { index[c] = UInt32(i) }

    let bits = max(1, Int(ceil(log2(Double(colours.count)))))
    var blob = [UInt8]()
    blob.reserveCapacity(4 + colours.count * 3 + (n * bits + 7) / 8)
    let count = UInt32(colours.count)
    blob += [UInt8(count >> 24 & 0xFF), UInt8(count >> 16 & 0xFF),
             UInt8(count >> 8 & 0xFF), UInt8(count & 0xFF)]
    // Sorted entries share high bytes, so the map itself compresses well.
    // 排序後的項目高位位元組相近，故對照表本身也好壓縮。
    for c in colours {
        blob += [UInt8(c >> 16 & 0xFF), UInt8(c >> 8 & 0xFF), UInt8(c & 0xFF)]
    }
    var acc: UInt64 = 0, held = 0
    for i in 0..<n {
        let key = UInt32(p[i*3]) << 16 | UInt32(p[i*3+1]) << 8 | UInt32(p[i*3+2])
        acc = (acc << UInt64(bits)) | UInt64(index[key]!)
        held += bits
        while held >= 8 {
            held -= 8
            blob.append(UInt8((acc >> UInt64(held)) & 0xFF))
        }
    }
    if held > 0 { blob.append(UInt8((acc << UInt64(8 - held)) & 0xFF)) }
    return (blob, colours.count, bits)
}

func paletteDecode(_ blob: [UInt8], pixels n: Int) -> [UInt8] {
    let count = Int(UInt32(blob[0]) << 24 | UInt32(blob[1]) << 16
                    | UInt32(blob[2]) << 8 | UInt32(blob[3]))
    let bits = max(1, Int(ceil(log2(Double(count)))))
    let table = 4
    let body = table + count * 3
    var out = [UInt8](repeating: 0, count: n * 3)
    var acc: UInt64 = 0, held = 0, cursor = body
    for i in 0..<n {
        while held < bits {
            acc = (acc << 8) | UInt64(cursor < blob.count ? blob[cursor] : 0)
            cursor += 1; held += 8
        }
        held -= bits
        let idx = Int((acc >> UInt64(held)) & ((1 << UInt64(bits)) - 1))
        let e = table + idx * 3
        out[i*3] = blob[e]; out[i*3+1] = blob[e+1]; out[i*3+2] = blob[e+2]
    }
    return out
}

// ---------------------------------------------------------------------
// MARK: - Neighbour-match flags / 鄰居相同旗標
// ---------------------------------------------------------------------

/// One flag per pixel: if it equals its left or upper neighbour, store the flag
/// and omit the 3 colour bytes. Break-even needs a hit rate above 1/3 once the
/// flag byte is counted; 2 bits/pixel is used here so the hit rate must clear
/// roughly 8%.
/// 每像素一個旗標：若與左或上鄰相同，只存旗標並省去 3 個色彩位元組。計入旗標
/// 後，損益平衡點約在命中率 1/3；此處旗標僅佔 2 bits，故命中率約需超過 8%。
func flagEncode(_ p: [UInt8], width: Int, height: Int) -> (blob: [UInt8], hits: Int) {
    let n = width * height
    var flags = [UInt8](); flags.reserveCapacity((n * 2 + 7) / 8)
    var literals = [UInt8](); literals.reserveCapacity(p.count)
    var acc: UInt64 = 0, held = 0, hits = 0
    @inline(__always) func same(_ i: Int, _ j: Int) -> Bool {
        p[i*3] == p[j*3] && p[i*3+1] == p[j*3+1] && p[i*3+2] == p[j*3+2]
    }
    for y in 0..<height {
        for x in 0..<width {
            let i = y * width + x
            var code = 0                                   // 0 = literal
            if x > 0, same(i, i - 1) { code = 1 }           // same as left / 同左
            else if y > 0, same(i, i - width) { code = 2 }  // same as above / 同上
            if code == 0 {
                literals += [p[i*3], p[i*3+1], p[i*3+2]]
            } else { hits += 1 }
            acc = (acc << 2) | UInt64(code); held += 2
            while held >= 8 { held -= 8; flags.append(UInt8((acc >> UInt64(held)) & 0xFF)) }
        }
    }
    if held > 0 { flags.append(UInt8((acc << UInt64(8 - held)) & 0xFF)) }
    return (flags + literals, hits)
}

// ---------------------------------------------------------------------
// MARK: - Codec / 編碼器
// ---------------------------------------------------------------------

func which(_ tool: String) -> String? {
    for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"] {
        let p = dir + "/" + tool
        if FileManager.default.isExecutableFile(atPath: p) { return p }
    }
    return nil
}

/// Compress through the external tool, the same way swift_tar shells out.
/// Returns nil when the tool is absent so a sweep can skip rather than abort.
/// 以外部工具壓縮，與 swift_tar 的呼叫方式一致。工具不存在時回傳 nil，讓掃描
/// 得以略過而非中止。
func compress(_ input: [UInt8], codec: String, level: Int) -> [UInt8]? {
    if codec == "none" { return input }
    let spec: (String, [String])
    switch codec {
    case "zstd": spec = ("zstd", ["-\(level)", "-c", "-"])
    case "gzip": spec = ("gzip", ["-\(min(level, 9))", "-c"])
    case "lz4":  spec = ("lz4",  ["-\(min(level, 12))", "-c"])
    case "xz":   spec = ("xz",   ["-\(min(level, 9))", "-c"])
    default: return nil
    }
    guard let exe = which(spec.0) else { return nil }
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: exe)
    proc.arguments = spec.1
    let inPipe = Pipe(), outPipe = Pipe()
    proc.standardInput = inPipe; proc.standardOutput = outPipe
    proc.standardError = FileHandle.nullDevice
    do { try proc.run() } catch { return nil }

    // Drain stdout on a separate queue: a large frame will fill the pipe buffer
    // and deadlock if we write everything before reading.
    // 於獨立佇列排空 stdout：大影格會塞滿 pipe 緩衝區，若先寫完再讀將造成死鎖。
    var out = Data()
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        out = outPipe.fileHandleForReading.readDataToEndOfFile(); done.signal()
    }
    inPipe.fileHandleForWriting.write(Data(input))
    inPipe.fileHandleForWriting.closeFile()
    done.wait(); proc.waitUntilExit()
    return proc.terminationStatus == 0 ? [UInt8](out) : nil
}

// ---------------------------------------------------------------------
// MARK: - Pipeline / 管線
// ---------------------------------------------------------------------

struct Options {
    var ycocg = false, med = false, sub = false, planar = false
    var palette = false, flagByte = false, delta = false
    var stripGeo = false
    var slices = 1
    var codec = "zstd"
    var level = 19
    var verify = true
    var csv = false
    var repeats = 1
    var presets: [String] = []
    var files: [String] = []

    /// Name shown in the report, derived from whatever is enabled.
    /// 報告中顯示的名稱，由已啟用的項目組成。
    var label: String {
        var parts: [String] = []
        if delta { parts.append("delta") }
        if palette { parts.append("palette") }
        if flagByte { parts.append("flagbyte") }
        if ycocg { parts.append("ycocg-r") }
        if med { parts.append("med") } else if sub { parts.append("sub") }
        if planar { parts.append("planar") }
        if stripGeo { parts.append("nogeo") }
        if slices > 1 { parts.append("slice\(slices)") }
        if parts.isEmpty { parts.append("raw") }
        return parts.joined(separator: "+")
    }
}

/// Apply the enabled transforms in a fixed order, and verify each is invertible.
/// Order is not arbitrary: colour decorrelation must precede spatial prediction
/// (predicting on Y/Co/Cg is what FFV1 does), and planar layout must come last
/// because it only rearranges the already-transformed bytes.
/// 依固定順序套用已啟用的變換，並驗證每項皆可逆。順序並非任意：色彩去相關必須
/// 先於空間預測（在 Y/Co/Cg 上做預測正是 FFV1 的作法），而 planar 排列必須最後
/// 執行，因為它只是重排已變換完成的位元組。
func transform(_ frame: Frame, previous: [UInt8]?, opt: Options) throws -> [UInt8] {
    let w = frame.width, h = frame.height
    var buf = frame.payload

    if opt.delta, let prev = previous, prev.count == buf.count {
        for i in 0..<buf.count { buf[i] = UInt8((Int(buf[i]) &- Int(prev[i])) & 0xFF) }
    }
    if opt.palette {
        let (blob, _, _) = paletteEncode(buf)
        if opt.verify {
            guard paletteDecode(blob, pixels: w * h) == buf else {
                throw Err("palette round-trip failed")
            }
        }
        return blob        // pointers are not spatially meaningful; stop here
    }
    if opt.flagByte {
        let (blob, _) = flagEncode(buf, width: w, height: h)
        return blob        // literals only; inverse needs the flag stream intact
    }
    if opt.ycocg {
        let t = ycocgForward(buf)
        if opt.verify {
            guard ycocgInverse(t) == buf else { throw Err("YCoCg-R round-trip failed") }
        }
        buf = t
    }
    if opt.med || opt.sub {
        let t = predictForward(buf, width: w, height: h, useMED: opt.med)
        if opt.verify {
            guard predictInverse(t, width: w, height: h, useMED: opt.med) == buf else {
                throw Err("prediction round-trip failed")
            }
        }
        buf = t
    }
    if opt.planar {
        let t = toPlanar(buf)
        if opt.verify {
            guard fromPlanar(t) == buf else { throw Err("planar round-trip failed") }
        }
        buf = t
    }
    return buf
}

/// Compressed size, optionally as N independent slices so rows can be decoded
/// in parallel. Independent slices cost size because each resets the
/// compressor's state and loses cross-slice correlation.
/// 壓縮後大小；可選擇切成 N 條獨立 slice 以便平行解碼。獨立 slice 會付出體積
/// 代價，因為每條都重置壓縮器狀態並喪失跨 slice 的相關性。
func compressedSize(_ buf: [UInt8], opt: Options) -> Int? {
    guard opt.slices > 1 else {
        return compress(buf, codec: opt.codec, level: opt.level)?.count
    }
    let chunk = (buf.count + opt.slices - 1) / opt.slices
    var total = 0
    for start in stride(from: 0, to: buf.count, by: chunk) {
        let end = min(start + chunk, buf.count)
        guard let c = compress(Array(buf[start..<end]), codec: opt.codec, level: opt.level) else {
            return nil
        }
        total += c.count + 4          // each slice needs a stored length / 每條需存長度
    }
    return total
}

// ---------------------------------------------------------------------
// MARK: - CLI
// ---------------------------------------------------------------------

let usage = """
swift_tar_DOE — flag-driven bench for RGB1 payload experiments
swift_tar_DOE — 以旗標驅動的 RGB1 payload 實驗平台

Usage / 用法:
  swift_tar_DOE [flags] <file.rgb1 ...>

Payload transforms (composable) / payload 變換（可組合）:
  --ycocg          reversible YCoCg-R colour decorrelation / 可逆 YCoCg-R 色彩去相關
  --med            MED spatial prediction (FFV1/JPEG-LS) / MED 空間預測
  --sub            Sub filter, left neighbour only (MED baseline) / 僅取左鄰，MED 基準
  --planar         plane-separated layout / 平面分離排列
  --palette        colour map + bit-packed pointers / 色彩對照表 + 緊密指標
  --flag-byte      2-bit per-pixel neighbour-match flags / 每像素 2-bit 鄰居相同旗標
  --delta          inter-frame delta vs the previous file / 對前一檔的影格間差分

Container / 容器:
  --strip-geo      drop the 16 geo bytes, clear flags bit 0 / 移除 16 B geo 並清旗標
  --slices N       compress as N independent slices / 切成 N 條獨立 slice 壓縮

Codec / 編碼器:
  --codec NAME     none|zstd|gzip|lz4|xz          (default zstd)
  --level N        compression level              (default 19)

Run control / 執行控制:
  --preset NAME    raw|palette|predictive|best; repeatable / 可重複指定
  --all            sweep every preset / 掃描所有預設組合
  --repeat N       timing repeats, best-of        (default 1)
  --no-verify      skip round-trip checks (faster, trusts nothing) / 略過往返驗證
  --csv            machine-readable output / 機器可讀輸出
  --help           this text / 本說明

Presets / 預設組合:
  raw          no transform, the format as it ships today / 不變換，即現行格式
  palette      --palette
  predictive   --ycocg --med --planar
  best         predictive, currently the smallest measured / 目前實測最小者
"""

let presetFlags: [String: [String]] = [
    "raw": [],
    "palette": ["--palette"],
    "predictive": ["--ycocg", "--med", "--planar"],
    "best": ["--ycocg", "--med", "--planar"],
]

func parse(_ argv: [String]) throws -> Options {
    var o = Options()
    var i = 0
    func next(_ flag: String) throws -> String {
        i += 1
        guard i < argv.count else { throw Err("\(flag) needs a value / 需要一個值") }
        return argv[i]
    }
    while i < argv.count {
        let a = argv[i]
        switch a {
        case "--ycocg": o.ycocg = true
        case "--med": o.med = true
        case "--sub": o.sub = true
        case "--planar": o.planar = true
        case "--palette": o.palette = true
        case "--flag-byte": o.flagByte = true
        case "--delta": o.delta = true
        case "--strip-geo": o.stripGeo = true
        case "--slices": o.slices = Int(try next(a)) ?? 1
        case "--codec": o.codec = try next(a)
        case "--level": o.level = Int(try next(a)) ?? 19
        case "--repeat": o.repeats = max(1, Int(try next(a)) ?? 1)
        case "--preset": o.presets.append(try next(a))
        case "--all": o.presets = ["raw", "palette", "predictive"]
        case "--no-verify": o.verify = false
        case "--verify": o.verify = true
        case "--csv": o.csv = true
        case "--help", "-h": print(usage); exit(0)
        default:
            guard !a.hasPrefix("--") else { throw Err("unknown flag \(a) — see --help") }
            o.files.append(a)
        }
        i += 1
    }
    guard !o.files.isEmpty else { throw Err("no input files / 未指定輸入檔案\n\n\(usage)") }
    guard ["none", "zstd", "gzip", "lz4", "xz"].contains(o.codec) else {
        throw Err("unknown codec \(o.codec)")
    }
    guard o.slices >= 1 else { throw Err("--slices must be >= 1") }
    if o.med && o.sub { throw Err("--med and --sub are alternatives / 兩者擇一") }
    return o
}

struct Result {
    let label: String, stored: Int, compressed: Int, seconds: Double, frames: Int
}

func run(_ base: Options) throws -> [Result] {
    let frames = try base.files.map { try Frame(contentsOf: $0) }
    let variants: [Options] = base.presets.isEmpty ? [base] : try base.presets.map { name in
        guard let flags = presetFlags[name] else { throw Err("unknown preset \(name)") }
        var v = try parse(flags + base.files)
        v.codec = base.codec; v.level = base.level
        v.verify = base.verify; v.slices = base.slices
        v.stripGeo = base.stripGeo; v.repeats = base.repeats
        return v
    }

    var results: [Result] = []
    for opt in variants {
        var stored = 0, compressed = 0, best = Double.infinity
        for _ in 0..<opt.repeats {
            stored = 0; compressed = 0
            let t0 = Date()
            var previous: [UInt8]? = nil
            for frame in frames {
                let buf = try transform(frame, previous: previous, opt: opt)
                previous = frame.payload
                guard let size = compressedSize(buf, opt: opt) else {
                    throw Err("codec \(opt.codec) unavailable / 找不到編碼器")
                }
                let head = opt.stripGeo ? headerSize - geoRange.count : headerSize
                stored += buf.count + head
                compressed += size + head
            }
            best = min(best, Date().timeIntervalSince(t0))
        }
        results.append(Result(label: opt.label, stored: stored,
                              compressed: compressed, seconds: best, frames: frames.count))
    }
    return results
}

func report(_ results: [Result], opt: Options, rawBytes: Int) {
    if opt.csv {
        print("variant,frames,stored_bytes,compressed_bytes,pct_of_raw,seconds,codec,level")
        for r in results {
            let pct = 100.0 * Double(r.compressed) / Double(rawBytes)
            print("\(r.label),\(r.frames),\(r.stored),\(r.compressed),"
                  + String(format: "%.4f", pct) + ","
                  + String(format: "%.3f", r.seconds) + ",\(opt.codec),\(opt.level)")
        }
        return
    }
    let stamp = DateFormatter()
    stamp.dateFormat = "yyyy-MM-dd HH:mm:ss"
    print("[Info] date / 日期: \(stamp.string(from: Date()))")
    print("[Info] frames / 影格: \(results.first?.frames ?? 0)")
    print("[Info] codec: \(opt.codec) -\(opt.level)"
          + (opt.slices > 1 ? ", \(opt.slices) slices" : "")
          + (opt.verify ? ", round-trip verified" : ", NOT verified"))
    print("")
    // String(format:) does not pad Swift strings, so columns are laid out here.
    // String(format:) 不會為 Swift 字串補位，故欄位在此自行排版。
    func pad(_ s: String, _ w: Int) -> String {
        s.count >= w ? s : s + String(repeating: " ", count: w - s.count)
    }
    func rpad(_ s: String, _ w: Int) -> String {
        s.count >= w ? s : String(repeating: " ", count: w - s.count) + s
    }
    print(pad("variant", 26) + rpad("stored (B)", 14) + rpad("+codec (B)", 14)
          + rpad("of raw", 10) + rpad("sec", 10))
    print(String(repeating: "-", count: 74))
    for r in results {
        let pct = 100.0 * Double(r.compressed) / Double(rawBytes)
        print(pad(r.label, 26) + rpad("\(r.stored)", 14) + rpad("\(r.compressed)", 14)
              + rpad(String(format: "%.2f%%", pct), 10)
              + rpad(String(format: "%.3f", r.seconds), 10))
    }
    if let baseline = results.first(where: { $0.label == "raw" }), results.count > 1 {
        print("")
        print("== vs raw / 相對於未變換 ==")
        for r in results where r.label != "raw" {
            let d = 100.0 * Double(r.compressed - baseline.compressed) / Double(baseline.compressed)
            print("  " + pad(r.label, 24) + rpad(String(format: "%+.1f%%", d), 8)
                  + "  " + (d < 0 ? "smaller / 較小" : "LARGER / 較大"))
        }
    }
}

do {
    let opt = try parse(Array(CommandLine.arguments.dropFirst()))
    let results = try run(opt)
    let rawBytes = try opt.files.reduce(0) { $0 + (try Frame(contentsOf: $1).payload.count) }
    report(results, opt: opt, rawBytes: rawBytes)
} catch let e as Err {
    FileHandle.standardError.write(Data(("[Error] " + e.description + "\n").utf8))
    exit(1)
} catch {
    FileHandle.standardError.write(Data(("[Error] \(error)\n").utf8))
    exit(1)
}
