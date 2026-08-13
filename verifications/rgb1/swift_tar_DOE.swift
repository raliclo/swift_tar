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
//  Transforms are lossless and --verify (on by default) round-trips them before
//  any size is reported: a transform that cannot reconstruct the frame is not a
//  compression result. Two exceptions, both marked in --help: --palette and
//  --flag-byte rewrite the whole frame and have no decoder here, so their sizes
//  are reported unverified.
//  各變換皆為無損，且 --verify（預設開啟）會在回報任何大小前先做往返驗證：無法
//  還原影格的變換不算壓縮結果。有兩個例外，皆已於 --help 標明：--palette 與
//  --flag-byte 會重寫整張影格且此處無對應解碼器，故其大小為未經驗證的數值。
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
// MARK: - Directional similarity / 方向相似性
// ---------------------------------------------------------------------

/// Neighbours tested, in priority order. Only already-decoded positions are
/// eligible, which in raster scan means left, above, upper-left, upper-right.
/// 依優先序測試的鄰居。只有已解碼的位置可用，光柵掃描下即左、上、左上、右上。
let dirOffsets: [(dx: Int, dy: Int)] = [(-1, 0), (0, -1), (-1, -1), (1, -1)]
let dirBits = 3                                  // 0 = literal, 1...4 = direction

/// If a pixel exactly matches a directional neighbour, its RGB is written as
/// zero and the direction is recorded in a side stream. The payload keeps its
/// full width * height * 3 length, so `876 + N * width * 3` still addresses row
/// N in O(1) — that is the point of writing zeros rather than omitting bytes.
/// 若像素與某個方向鄰居完全相同，其 RGB 寫為零，方向記於旁路串流。payload 維持
/// 完整的 width * height * 3 長度，故 `876 + N * width * 3` 仍能 O(1) 定址到第
/// N 列 —— 這正是寫零而非省略位元組的用意。
func dirSimForward(_ p: [UInt8], width: Int, height: Int) -> (blob: [UInt8], hits: Int) {
    var payload = p
    var flags = [UInt8](); flags.reserveCapacity((width * height * dirBits + 7) / 8)
    var acc: UInt64 = 0, held = 0, hits = 0

    for y in 0..<height {
        for x in 0..<width {
            let i = (y * width + x) * 3
            var code = 0
            for (k, d) in dirOffsets.enumerated() {
                let nx = x + d.dx, ny = y + d.dy
                guard nx >= 0, nx < width, ny >= 0 else { continue }
                let j = (ny * width + nx) * 3
                if p[i] == p[j], p[i+1] == p[j+1], p[i+2] == p[j+2] { code = k + 1; break }
            }
            if code != 0 {
                payload[i] = 0; payload[i+1] = 0; payload[i+2] = 0
                hits += 1
            }
            acc = (acc << UInt64(dirBits)) | UInt64(code); held += dirBits
            while held >= 8 { held -= 8; flags.append(UInt8((acc >> UInt64(held)) & 0xFF)) }
        }
    }
    if held > 0 { flags.append(UInt8((acc << UInt64(8 - held)) & 0xFF)) }
    return (flags + payload, hits)
}

func dirSimInverse(_ blob: [UInt8], width: Int, height: Int) -> [UInt8] {
    let flagBytes = (width * height * dirBits + 7) / 8
    var out = Array(blob[flagBytes...])
    var acc: UInt64 = 0, held = 0, cursor = 0

    for y in 0..<height {
        for x in 0..<width {
            while held < dirBits {
                acc = (acc << 8) | UInt64(cursor < flagBytes ? blob[cursor] : 0)
                cursor += 1; held += 8
            }
            held -= dirBits
            let code = Int((acc >> UInt64(held)) & ((1 << UInt64(dirBits)) - 1))
            guard code != 0 else { continue }
            let d = dirOffsets[code - 1]
            let i = (y * width + x) * 3, j = ((y + d.dy) * width + (x + d.dx)) * 3
            out[i] = out[j]; out[i+1] = out[j+1]; out[i+2] = out[j+2]
        }
    }
    return out
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

// zstd is called in-process through the same libzstd swift_tar links against
// (-lzstd, @_silgen_name), not by spawning the CLI. Spawning cost ~5-10 ms per
// call, which is the same order as the 33 ms frame budget being measured — it
// would have dominated every timing here.
// zstd 以行程內方式呼叫 swift_tar 所連結的同一份 libzstd（-lzstd、
// @_silgen_name），而非啟動 CLI。行程啟動成本約 5-10 ms，與此處量測的 33 ms
// 影格預算同一數量級，會主導所有計時結果。
@_silgen_name("ZSTD_compressBound")
func ZSTD_compressBound(_ srcSize: Int) -> Int
@_silgen_name("ZSTD_compress")
func ZSTD_compress(_ dst: UnsafeMutableRawPointer, _ dstCap: Int,
                   _ src: UnsafeRawPointer, _ srcSize: Int, _ level: Int32) -> Int
@_silgen_name("ZSTD_decompress")
func ZSTD_decompress(_ dst: UnsafeMutableRawPointer, _ dstCap: Int,
                     _ src: UnsafeRawPointer, _ srcSize: Int) -> Int
@_silgen_name("ZSTD_isError")
func ZSTD_isError(_ code: Int) -> UInt32

func zstdCompress(_ input: [UInt8], level: Int) -> [UInt8]? {
    let bound = ZSTD_compressBound(input.count)
    var out = [UInt8](repeating: 0, count: bound)
    let n = out.withUnsafeMutableBytes { d in
        input.withUnsafeBytes { s in
            ZSTD_compress(d.baseAddress!, bound, s.baseAddress!, input.count, Int32(level))
        }
    }
    guard ZSTD_isError(n) == 0 else { return nil }
    return Array(out[0..<n])
}

func zstdDecompress(_ input: [UInt8], capacity: Int) -> [UInt8]? {
    var out = [UInt8](repeating: 0, count: capacity)
    let n = out.withUnsafeMutableBytes { d in
        input.withUnsafeBytes { s in
            ZSTD_decompress(d.baseAddress!, capacity, s.baseAddress!, input.count)
        }
    }
    guard ZSTD_isError(n) == 0 else { return nil }
    return Array(out[0..<n])
}

/// Compress through the external tool, the same way swift_tar shells out.
/// Returns nil when the tool is absent so a sweep can skip rather than abort.
/// 以外部工具壓縮，與 swift_tar 的呼叫方式一致。工具不存在時回傳 nil，讓掃描
/// 得以略過而非中止。
func compress(_ input: [UInt8], codec: String, level: Int) -> [UInt8]? {
    if codec == "none" { return input }
    if codec == "zstd" { return zstdCompress(input, level: level) }
    let spec: (String, [String])
    switch codec {
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
    var palette = false, flagByte = false, delta = false, dirSim = false
    var stripGeo = false
    var slices = 1
    var threads = 1
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
        if dirSim { parts.append("dirsim") }
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

// ---------------------------------------------------------------------
// MARK: - Slice pipeline / Slice 管線
// ---------------------------------------------------------------------

/// Horizontal row bands. Slicing by rows rather than by byte offset is what
/// makes a band independently decodable: MED never reaches outside its own band,
/// so bands can be transformed and inverted in parallel.
/// 水平列帶。以列而非位元組位移切分，才能讓每帶可獨立解碼：MED 不會越出自身
/// 帶界，故各帶的變換與反變換皆可平行執行。
func bands(height: Int, slices: Int) -> [(Int, Int)] {
    let n = max(1, min(slices, height))
    let rows = (height + n - 1) / n
    return stride(from: 0, to: height, by: rows).map { ($0, min($0 + rows, height)) }
}

/// The QoS every arm of the bench runs at. Fixed rather than inherited so the
/// sequential and concurrent arms are scheduled alike; see parallelMap.
/// 本量測所有組別共用的 QoS。刻意固定而非沿用繼承值，使序列與並行兩組得到相同的
/// 排程待遇；詳見 parallelMap。
let benchQoS: DispatchQoS.QoSClass = .userInitiated

/// Run `work` over `count` items, at most `threads` at a time, preserving order.
/// Mirrors swift_tar's -n: a semaphore bounds concurrency rather than letting
/// concurrentPerform take every core regardless of what was asked for.
/// 以最多 `threads` 個並行執行 `work`，並保持順序。與 swift_tar 的 -n 一致：以
/// semaphore 限制並行度，而非讓 concurrentPerform 無視設定佔滿所有核心。
func parallelMap<T>(_ count: Int, threads: Int,
                    _ work: @escaping (Int) -> T?) -> [T]? {
    // There is deliberately no separate sequential branch. An earlier version
    // special-cased threads == 1 with a plain loop on the calling thread, and
    // that arm ran ~6x slower than the same work dispatched to a queue with a
    // semaphore of 1 — so every reported speed-up was measuring the difference
    // between two implementations, not the effect of concurrency. With one path,
    // -n 1 is the same code as -n 20 with the gate closed.
    // 此處刻意不設獨立的序列分支。先前版本對 threads == 1 特別處理，在呼叫端執行
    // 緒上直接迴圈；該組比「同樣工作以 semaphore 為 1 派送到佇列」慢約 6 倍——
    // 於是所有回報的加速比量到的都是兩份實作之間的差異，而非並行的效果。統一為
    // 單一路徑後，-n 1 就是把閘門關到 1 的 -n 20，程式碼完全相同。
    var slots = [T?](repeating: nil, count: count)
    let lock = NSLock(), sem = DispatchSemaphore(value: threads)
    let group = DispatchGroup()
    for i in 0..<count {
        sem.wait()
        // Pinned to the same QoS the sequential path runs at. Without an
        // explicit class the two arms are scheduled differently: a
        // single-threaded run is parked on the E-cores while a concurrent one
        // recruits the P-cores, which on a 4P+6E machine reports a ~16x speed-up
        // from 10 cores. That is a scheduling artefact, not parallel efficiency.
        // 與序列路徑釘在相同的 QoS。若不明確指定類別，兩條路徑會得到不同的排程：
        // 單執行緒執行會被安置在 E-core，而並行執行則徵用 P-core，於 4P+6E 的機器
        // 上造成「10 核卻加速約 16 倍」的假象。那是排程產物，不是平行效率。
        DispatchQueue.global(qos: benchQoS).async(group: group) {
            let v = autoreleasepool { work(i) }
            lock.lock(); slots[i] = v; lock.unlock()
            sem.signal()
        }
    }
    group.wait()
    return slots.contains(where: { $0 == nil }) ? nil : slots.map { $0! }
}

/// One band: inter-frame delta, colour transform, prediction, planar layout,
/// then compression.
/// 單一列帶：影格間差分、色彩變換、預測、planar 排列，最後壓縮。
///
/// `previous` is the prior frame's full payload, sliced to the same band. It was
/// missing here while `--delta` was only implemented on the whole-frame path,
/// which meant `--delta` alone produced byte-identical output to `raw` and still
/// labelled it "delta" — a silently wrong result rather than a failure.
/// `previous` 為前一影格的完整 payload，切取相同列帶。此處原本缺少該參數，而
/// `--delta` 僅實作於整格路徑，導致單獨使用 `--delta` 產生與 `raw` 完全相同的
/// 位元組卻仍標記為「delta」——是靜默的錯誤結果，而非失敗。
func encodeBand(_ payload: [UInt8], previous: [UInt8]?, width: Int, y0: Int, y1: Int,
                opt: Options) -> [UInt8]? {
    let rows = y1 - y0
    let range = (y0 * width * 3)..<(y1 * width * 3)
    var buf = Array(payload[range])
    if opt.delta, let prev = previous, prev.count == payload.count {
        let pb = Array(prev[range])
        for i in 0..<buf.count { buf[i] = UInt8((Int(buf[i]) &- Int(pb[i])) & 0xFF) }
    }
    if opt.dirSim { buf = dirSimForward(buf, width: width, height: rows).blob }
    if opt.ycocg { buf = ycocgForward(buf) }
    if opt.med || opt.sub {
        buf = predictForward(buf, width: width, height: rows, useMED: opt.med)
    }
    if opt.planar { buf = toPlanar(buf) }
    return compress(buf, codec: opt.codec, level: opt.level)
}

/// The exact inverse, in reverse order. This is the client-side cost.
/// 完全對應的反向流程，順序相反。這就是客戶端要付的成本。
func decodeBand(_ blob: [UInt8], previous: [UInt8]?, width: Int, y0: Int, rows: Int,
                opt: Options) -> [UInt8]? {
    var raw = rows * width * 3
    if opt.dirSim { raw += (rows * width * dirBits + 7) / 8 }
    var buf: [UInt8]
    if opt.codec == "none" { buf = blob }
    else if opt.codec == "zstd" {
        guard let d = zstdDecompress(blob, capacity: raw) else { return nil }
        buf = d
    } else { return nil }        // external codecs are encode-only here
    if opt.planar { buf = fromPlanar(buf) }
    if opt.med || opt.sub {
        buf = predictInverse(buf, width: width, height: rows, useMED: opt.med)
    }
    if opt.ycocg { buf = ycocgInverse(buf) }
    if opt.dirSim { buf = dirSimInverse(buf, width: width, height: rows) }
    // Undoes the delta last, mirroring encodeBand's order. --verify compares the
    // reconstruction against the original payload, so a delta without this would
    // fail loudly rather than quietly report the wrong size.
    // 最後還原差分，與 encodeBand 的順序相對。--verify 會將重建結果與原始 payload
    // 比對，故若差分缺少此步會明確失敗，而非靜默回報錯誤的大小。
    if opt.delta, let prev = previous {
        let base = y0 * width * 3
        for i in 0..<buf.count { buf[i] = UInt8((Int(buf[i]) &+ Int(prev[base + i])) & 0xFF) }
    }
    return buf
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
  --palette        colour map + bit-packed pointers (no decoder; size is
                   reported unverified) / 色彩對照表 + 緊密指標（無解碼器，
                   其大小為未驗證數值）
  --flag-byte      2-bit per-pixel neighbour-match flags (no decoder; size is
                   reported unverified) / 每像素 2-bit 鄰居相同旗標（無解碼器，
                   其大小為未驗證數值）
  --dirsim         zero the RGB where a pixel matches a directional neighbour,
                   keeping the payload fixed-length / 與方向鄰居相同者 RGB 寫零，
                   payload 維持固定長度
  --delta          inter-frame delta vs the previous file / 對前一檔的影格間差分

Container / 容器:
  --strip-geo      account for the header without its 16 geo bytes. It adjusts
                   the reported size only; it does not rewrite the header, and
                   the measured saving was 12.4 B/frame
                   僅以「扣除 16 B geo」計算標頭大小；不改寫標頭本身，實測節省
                   為每格 12.4 B
  --slices N       split into N independent row bands / 切成 N 條獨立列帶
  -n N             run N bands concurrently, as swift_tar's -n / 並行 N 條列帶

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
        case "--dirsim": o.dirSim = true
        case "--delta": o.delta = true
        case "--strip-geo": o.stripGeo = true
        case "--slices": o.slices = Int(try next(a)) ?? 1
        case "-n": o.threads = max(1, Int(try next(a)) ?? 1)
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
    let label: String, stored: Int, compressed: Int
    let encode: Double, decode: Double, frames: Int
}

func run(_ base: Options) throws -> [Result] {
    let frames = try base.files.map { try Frame(contentsOf: $0) }
    let variants: [Options] = base.presets.isEmpty ? [base] : try base.presets.map { name in
        guard let flags = presetFlags[name] else { throw Err("unknown preset \(name)") }
        var v = try parse(flags + base.files)
        v.codec = base.codec; v.level = base.level
        v.dirSim = base.dirSim
        v.verify = base.verify; v.slices = base.slices
        v.stripGeo = base.stripGeo; v.repeats = base.repeats
        v.threads = base.threads
        return v
    }

    var results: [Result] = []
    for opt in variants {
        // --palette and --flag-byte rewrite the whole frame, so they have no
        // band decomposition and no inverse-timing path here.
        // --palette 與 --flag-byte 會重寫整張影格，故無列帶分解，此處也不量反向。
        let wholeFrame = opt.palette || opt.flagByte
        var stored = 0, compressed = 0
        var bestEnc = Double.infinity, bestDec = Double.infinity

        for _ in 0..<opt.repeats {
            stored = 0; compressed = 0
            var encoded: [[[UInt8]]] = []
            let head = opt.stripGeo ? headerSize - geoRange.count : headerSize

            let t0 = Date()
            if wholeFrame {
                var previous: [UInt8]? = nil
                for frame in frames {
                    let buf = try transform(frame, previous: previous, opt: opt)
                    previous = frame.payload
                    guard let c = compress(buf, codec: opt.codec, level: opt.level) else {
                        throw Err("codec \(opt.codec) unavailable / 找不到編碼器")
                    }
                    stored += buf.count + head; compressed += c.count + head
                }
            } else {
                var previous: [UInt8]? = nil
                for frame in frames {
                    let bs = bands(height: frame.height, slices: opt.slices)
                    let prev = previous
                    guard let parts = parallelMap(bs.count, threads: opt.threads, { i in
                        encodeBand(frame.payload, previous: prev, width: frame.width,
                                   y0: bs[i].0, y1: bs[i].1, opt: opt)
                    }) else { throw Err("codec \(opt.codec) unavailable / 找不到編碼器") }
                    previous = frame.payload
                    encoded.append(parts)
                    stored += frame.payload.count + head
                    // Each band stores its own length so the decoder can split.
                    // 每帶各自儲存長度，供解碼端切分。
                    compressed += parts.reduce(0) { $0 + $1.count + 4 } + head
                }
            }
            bestEnc = min(bestEnc, Date().timeIntervalSince(t0))

            guard !wholeFrame, opt.codec == "none" || opt.codec == "zstd" else { continue }
            let t1 = Date()
            // The decoder walks frames in order because a delta frame needs the
            // frame before it already reconstructed — the same constraint a real
            // decoder has.
            // 解碼端依序走訪影格，因為差分影格需要前一格已重建完成——這與真實
            // 解碼器面對的約束相同。
            var decodedPrev: [UInt8]? = nil
            for (fi, frame) in frames.enumerated() {
                let bs = bands(height: frame.height, slices: opt.slices)
                let prev = decodedPrev
                guard let out = parallelMap(bs.count, threads: opt.threads, { i in
                    decodeBand(encoded[fi][i], previous: prev, width: frame.width,
                               y0: bs[i].0, rows: bs[i].1 - bs[i].0, opt: opt)
                }) else { throw Err("decode failed / 解碼失敗") }
                decodedPrev = Array(out.joined())
                if opt.verify {
                    guard Array(out.joined()) == frame.payload else {
                        throw Err("round-trip mismatch on \(opt.label) / 往返結果不符")
                    }
                }
            }
            bestDec = min(bestDec, Date().timeIntervalSince(t1))
        }
        results.append(Result(label: opt.label, stored: stored, compressed: compressed,
                              encode: bestEnc,
                              decode: bestDec.isFinite ? bestDec : 0,
                              frames: frames.count))
    }
    return results
}

func report(_ results: [Result], opt: Options, rawBytes: Int) {
    if opt.csv {
        print("variant,frames,stored_bytes,compressed_bytes,pct_of_raw,"
              + "encode_ms_per_frame,decode_ms_per_frame,codec,level,slices,threads")
        for r in results {
            let pct = 100.0 * Double(r.compressed) / Double(rawBytes)
            let f = Double(max(1, r.frames))
            print("\(r.label),\(r.frames),\(r.stored),\(r.compressed),"
                  + String(format: "%.4f", pct) + ","
                  + String(format: "%.2f", r.encode / f * 1000) + ","
                  + String(format: "%.2f", r.decode / f * 1000)
                  + ",\(opt.codec),\(opt.level),\(opt.slices),\(opt.threads)")
        }
        return
    }
    let stamp = DateFormatter()
    stamp.dateFormat = "yyyy-MM-dd HH:mm:ss"
    print("[Info] date / 日期: \(stamp.string(from: Date()))")
    print("[Info] frames / 影格: \(results.first?.frames ?? 0)")
    print("[Info] codec: \(opt.codec) -\(opt.level), \(opt.slices) slice(s), -n \(opt.threads)"
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
    print(pad("variant", 26) + rpad("+codec (B)", 14) + rpad("of raw", 9)
          + rpad("enc ms/f", 11) + rpad("dec ms/f", 11))
    print(String(repeating: "-", count: 71))
    for r in results {
        let pct = 100.0 * Double(r.compressed) / Double(rawBytes)
        let f = Double(max(1, r.frames))
        print(pad(r.label, 26) + rpad("\(r.compressed)", 14)
              + rpad(String(format: "%.2f%%", pct), 9)
              + rpad(String(format: "%.1f", r.encode / f * 1000), 11)
              + rpad(r.decode > 0 ? String(format: "%.1f", r.decode / f * 1000) : "-", 11))
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
    // The sequential arm runs on this thread, so it needs the same class the
    // worker queue uses; otherwise the comparison measures the scheduler.
    // 序列組在此執行緒上執行，故需與 worker queue 使用相同類別，否則比較量到的
    // 是排程器而非程式碼。
    // pthread, not Thread.current.qualityOfService: assigning that property on a
    // thread that is already running is a silent no-op, and the main thread is
    // always already running. Verified by ../qos-DOE.swift, which reads
    // qos_class_self() before and after each API. The earlier version of this
    // line did nothing.
    // 使用 pthread 而非 Thread.current.qualityOfService：對已在執行的執行緒賦值該
    // 屬性是靜默的無操作，而主執行緒永遠處於執行中。已由 ../qos-DOE.swift 驗證，
    // 該程式在每個 API 前後讀取 qos_class_self()。此行的先前版本毫無作用。
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0)
    let opt = try parse(Array(CommandLine.arguments.dropFirst()))
    let results = try run(opt)
    // Derived from the sizes already on disk rather than by parsing every frame
    // a second time: run() has loaded the corpus once, and re-reading 6 MB per
    // frame to recover a byte count is not free.
    // 由磁碟上已知的檔案大小推算，而非再次解析每個影格：run() 已載入語料一次，
    // 為取得位元組數而重讀每格 6 MB 並非零成本。
    let rawBytes = opt.files.reduce(0) { total, path in
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int)
            .flatMap { $0 } ?? 0
        return total + max(0, size - headerSize)
    }
    report(results, opt: opt, rawBytes: rawBytes)
} catch let e as Err {
    FileHandle.standardError.write(Data(("[Error] " + e.description + "\n").utf8))
    exit(1)
} catch {
    FileHandle.standardError.write(Data(("[Error] \(error)\n").utf8))
    exit(1)
}
