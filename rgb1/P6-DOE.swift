// =====================================================================
//  P6-DOE.swift — does the planar layout let P6 skip the RGBA conversion?
//  P6-DOE.swift — planar 排列能否讓 P6 省下 RGBA 轉換？
//
//  The predictive stack already stores the payload planar (RRR...GGG...BBB...)
//  because it compresses better that way. That happens to be the layout a
//  three-plane GPU upload wants, so the client may be able to hand Metal the
//  decoded planes directly instead of interleaving them and padding to RGBA.
//  預測式堆疊已將 payload 以 planar 儲存（RRR…GGG…BBB…），因為那樣較好壓縮。
//  該排列恰好就是三平面 GPU 上傳所需的格式，因此客戶端或許能把解碼後的平面直接
//  交給 Metal，而不必先交錯再補成 RGBA。
//
//  Three paths are compared end to end, all rendering the same frame:
//    A  interleave to RGBA on the CPU, upload one rgba8Unorm texture
//       (what P6 does today: Image<RGBA> -> texture.replace)
//    B  upload three r8Unorm plane textures in R,G,B order, assemble in the
//       fragment shader (the technique NV12 uses for its Y and UV planes)
//    C  the same, in ffmpeg's `gbrp` plane order (G,B,R), to check that standard
//       ffmpeg output feeds this path without moving any bytes
//  三條路徑端到端比較，皆渲染同一影格：
//    A  於 CPU 交錯成 RGBA，上傳單一 rgba8Unorm texture（P6 現行作法）
//    B  以 R,G,B 順序上傳三個 r8Unorm 平面 texture，於 fragment shader 組合
//       （NV12 對其 Y 與 UV 平面所用的手法）
//    C  同上，但採 ffmpeg 的 `gbrp` 平面順序（G,B,R），用以確認標準 ffmpeg 輸出
//       可直接餵入此路徑而無需搬動任何位元組
//
//  All are read back and compared pixel for pixel. A faster path that renders
//  different pixels is not a faster path.
//  三者皆讀回並逐像素比對。渲染出不同像素的「較快路徑」不算較快。
//
//  Build / 建置:
//    swiftc -O P6-DOE.swift -o P6-DOE -framework Metal -framework Foundation
//
//  Usage / 用法:
//    ./P6-DOE <frame.rgb1> [iterations]
//    defaults / 預設: 60 iterations
// =====================================================================

import Foundation
import Metal

let headerSize = 876

// ---------------------------------------------------------------------
// MARK: - Shaders / 著色器
// ---------------------------------------------------------------------

// A full-screen triangle strip; the fragment stage is the only difference
// between the paths.
// 全螢幕 triangle strip；各路徑的差異僅在 fragment 階段。
let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct VOut { float4 pos [[position]]; float2 uv; };

vertex VOut vmain(uint vid [[vertex_id]]) {
    float2 p[4] = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,1) };
    VOut o;
    o.pos = float4(p[vid], 0, 1);
    o.uv  = float2((p[vid].x + 1) * 0.5, (1 - p[vid].y) * 0.5);
    return o;
}

// Path A: one interleaved RGBA texture, one sample.
// 路徑 A：單一交錯 RGBA texture，取樣一次。
fragment float4 frgba(VOut in [[stage_in]],
                      texture2d<float> tex [[texture(0)]],
                      sampler smp [[sampler(0)]]) {
    return tex.sample(smp, in.uv);
}

// Path C: ffmpeg's gbrp plane order. Same three textures, same sampling; only
// which plane is bound to which index changes, so interop costs nothing.
// 路徑 C：ffmpeg 的 gbrp 平面順序。相同的三個 texture、相同的取樣；改變的只是
// 哪個平面綁到哪個索引，故互通不需任何成本。
fragment float4 fgbrp(VOut in [[stage_in]],
                      texture2d<float> gp [[texture(0)]],
                      texture2d<float> bp [[texture(1)]],
                      texture2d<float> rp [[texture(2)]],
                      sampler smp [[sampler(0)]]) {
    return float4(rp.sample(smp, in.uv).r,
                  gp.sample(smp, in.uv).r,
                  bp.sample(smp, in.uv).r,
                  1.0);
}

// Path B: three single-channel planes in R,G,B order, assembled here.
// 路徑 B：以 R,G,B 順序排列的三個單通道平面，於此組合。
fragment float4 fplanes(VOut in [[stage_in]],
                        texture2d<float> rp [[texture(0)]],
                        texture2d<float> gp [[texture(1)]],
                        texture2d<float> bp [[texture(2)]],
                        sampler smp [[sampler(0)]]) {
    return float4(rp.sample(smp, in.uv).r,
                  gp.sample(smp, in.uv).r,
                  bp.sample(smp, in.uv).r,
                  1.0);
}
"""

// ---------------------------------------------------------------------
// MARK: - Input / 輸入
// ---------------------------------------------------------------------

func fail(_ m: String) -> Never {
    FileHandle.standardError.write(Data(("[Error] " + m + "\n").utf8))
    exit(1)
}

func loadRGB1(_ path: String) -> (w: Int, h: Int, payload: [UInt8]) {
    guard let data = FileManager.default.contents(atPath: path) else {
        fail("cannot read \(path)")
    }
    let b = [UInt8](data)
    guard b.count > headerSize, Array(b[0...3]) == Array("RGB1".utf8) else {
        fail("\(path) is not an RGB1 container")
    }
    func be32(_ o: Int) -> Int {
        (Int(b[o]) << 24) | (Int(b[o+1]) << 16) | (Int(b[o+2]) << 8) | Int(b[o+3])
    }
    let w = be32(4), h = be32(8)
    guard b.count == headerSize + w * h * 3 else { fail("\(path): payload size mismatch") }
    return (w, h, Array(b[headerSize...]))
}

/// What path A must do on the CPU: interleave and pad to 4 bytes per pixel.
/// Metal has no 24-bit texture format, so this cannot be skipped for path A.
/// 路徑 A 必須在 CPU 上做的事：交錯並補成每像素 4 位元組。Metal 沒有 24-bit 的
/// texture 格式，故路徑 A 無法省略此步。
func interleaveToRGBA(_ planar: [UInt8], pixels n: Int) -> [UInt8] {
    var out = [UInt8](repeating: 255, count: n * 4)
    for i in 0..<n {
        out[i*4]     = planar[i]
        out[i*4 + 1] = planar[n + i]
        out[i*4 + 2] = planar[2*n + i]
    }
    return out
}

// ---------------------------------------------------------------------
// MARK: - Bench / 量測
// ---------------------------------------------------------------------

let args = CommandLine.arguments
guard args.count >= 2 else {
    fail("""
    Usage: P6-DOE <frame.rgb1> [iterations]
    用法： P6-DOE <影格.rgb1> [次數]
    """)
}
let iterations = args.count > 2 ? (Int(args[2]) ?? 60) : 60
let (width, height, interleavedPayload) = loadRGB1(args[1])
let pixels = width * height

// The decoder emits planar; the file on disk is interleaved, so convert once
// up front. This is setup, not part of either measured path.
// 解碼器輸出 planar；磁碟上的檔案是交錯的，故先轉換一次。此為前置作業，不屬於
// 任何一條受測路徑。
var planar = [UInt8](repeating: 0, count: pixels * 3)
for i in 0..<pixels {
    planar[i]              = interleavedPayload[i*3]
    planar[pixels + i]     = interleavedPayload[i*3 + 1]
    planar[2*pixels + i]   = interleavedPayload[i*3 + 2]
}

// ffmpeg's planar RGB format is `gbrp`: plane 0 is G, plane 1 is B, plane 2 is
// R. Verified with `ffmpeg -pix_fmt gbrp`. Building it here as ffmpeg would emit
// it lets path C prove the interop without a conversion step at render time.
// ffmpeg 的 planar RGB 格式為 `gbrp`：plane 0 為 G、plane 1 為 B、plane 2 為 R
// （已以 `ffmpeg -pix_fmt gbrp` 驗證）。此處依 ffmpeg 的輸出方式建構，使路徑 C
// 得以在渲染時不做任何轉換即證明互通性。
var gbrp = [UInt8](repeating: 0, count: pixels * 3)
for i in 0..<pixels {
    gbrp[i]            = planar[pixels + i]      // G
    gbrp[pixels + i]   = planar[2*pixels + i]    // B
    gbrp[2*pixels + i] = planar[i]               // R
}

guard let device = MTLCreateSystemDefaultDevice() else { fail("no Metal device") }
guard let queue = device.makeCommandQueue() else { fail("no command queue") }
let library: MTLLibrary
do { library = try device.makeLibrary(source: shaderSource, options: nil) }
catch { fail("shader compile failed: \(error)") }

func makePipeline(fragment: String) -> MTLRenderPipelineState {
    let d = MTLRenderPipelineDescriptor()
    d.vertexFunction = library.makeFunction(name: "vmain")
    d.fragmentFunction = library.makeFunction(name: fragment)
    d.colorAttachments[0].pixelFormat = .rgba8Unorm
    do { return try device.makeRenderPipelineState(descriptor: d) }
    catch { fail("pipeline \(fragment) failed: \(error)") }
}

func makeTexture(_ format: MTLPixelFormat, _ w: Int, _ h: Int,
                 usage: MTLTextureUsage = [.shaderRead]) -> MTLTexture {
    let d = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: format, width: w, height: h, mipmapped: false)
    d.usage = usage
    guard let t = device.makeTexture(descriptor: d) else { fail("texture alloc failed") }
    return t
}

let sampler: MTLSamplerState = {
    let d = MTLSamplerDescriptor()
    d.minFilter = .nearest; d.magFilter = .nearest      // exact texels, so readback compares
    d.sAddressMode = .clampToEdge; d.tAddressMode = .clampToEdge
    guard let s = device.makeSamplerState(descriptor: d) else { fail("sampler failed") }
    return s
}()

let target = makeTexture(.rgba8Unorm, width, height, usage: [.renderTarget, .shaderRead])
let rgbaPipeline = makePipeline(fragment: "frgba")
let planePipeline = makePipeline(fragment: "fplanes")
let gbrpPipeline = makePipeline(fragment: "fgbrp")

let rgbaTexture = makeTexture(.rgba8Unorm, width, height)
let planeTextures = (0..<3).map { _ in makeTexture(.r8Unorm, width, height) }

/// One frame: CPU preparation, texture upload, render. Returns the two costs
/// separately because they land on different parts of the budget.
/// 單一影格：CPU 前置、texture 上傳、渲染。分別回傳兩項成本，因為它們落在預算的
/// 不同部分。
enum Path { case rgba, planes, gbrp }

func runFrame(_ mode: Path) -> (cpu: Double, gpu: Double) {
    let t0 = Date()
    var staged: [UInt8] = []
    if mode == .rgba { staged = interleaveToRGBA(planar, pixels: pixels) }
    let cpu = Date().timeIntervalSince(t0)

    let t1 = Date()
    if mode != .rgba {
        let source = mode == .gbrp ? gbrp : planar
        for (i, tex) in planeTextures.enumerated() {
            source.withUnsafeBytes { p in
                tex.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                            withBytes: p.baseAddress!.advanced(by: i * pixels),
                            bytesPerRow: width)
            }
        }
    } else {
        staged.withUnsafeBytes { p in
            rgbaTexture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                                withBytes: p.baseAddress!, bytesPerRow: width * 4)
        }
    }

    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = target
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .store
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)

    guard let cb = queue.makeCommandBuffer(),
          let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { fail("encode failed") }
    switch mode {
    case .rgba:   enc.setRenderPipelineState(rgbaPipeline)
    case .planes: enc.setRenderPipelineState(planePipeline)
    case .gbrp:   enc.setRenderPipelineState(gbrpPipeline)
    }
    enc.setFragmentSamplerState(sampler, index: 0)
    if mode != .rgba {
        for (i, t) in planeTextures.enumerated() { enc.setFragmentTexture(t, index: i) }
    } else {
        enc.setFragmentTexture(rgbaTexture, index: 0)
    }
    enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    enc.endEncoding()
    cb.commit()
    cb.waitUntilCompleted()
    return (cpu, Date().timeIntervalSince(t1))
}

func readback() -> [UInt8] {
    var out = [UInt8](repeating: 0, count: pixels * 4)
    out.withUnsafeMutableBytes { p in
        target.getBytes(p.baseAddress!, bytesPerRow: width * 4,
                        from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
    }
    return out
}

// ---------------------------------------------------------------------
print("[Info] date / 日期: \(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .medium))")
print("[Info] device / 裝置: \(device.name)")
print("[Info] frame / 影格: \(width)x\(height), \(iterations) iterations")
print("")

_ = runFrame(.rgba)                              // warm up / 暖機
let rgbaPixels = readback()
_ = runFrame(.planes)
let planePixels = readback()
_ = runFrame(.gbrp)
let gbrpPixels = readback()

// Correctness first: a faster path that renders different pixels is not faster.
// 先驗正確性：渲染出不同像素的「較快路徑」不算較快。
for (name, other) in [("B planes", planePixels), ("C gbrp", gbrpPixels)] {
    var mismatches = 0
    for i in 0..<rgbaPixels.count where rgbaPixels[i] != other[i] { mismatches += 1 }
    if mismatches == 0 {
        print("[OK] \(name) renders identical pixels to A / 與 A 渲染結果完全相同")
    } else {
        print("[FAIL] \(name): \(mismatches) byte(s) differ / 位元組不同 — timings meaningless")
    }
}
print("")

var results: [(String, Double, Double)] = []
for (label, mode) in [("A  RGBA interleave + 1 texture", Path.rgba),
                      ("B  3 planes, RGB order (ours)", Path.planes),
                      ("C  3 planes, GBR order (ffmpeg gbrp)", Path.gbrp)] {
    var bestCPU = Double.infinity, bestGPU = Double.infinity
    for _ in 0..<iterations {
        let (c, g) = runFrame(mode)
        bestCPU = min(bestCPU, c); bestGPU = min(bestGPU, g)
    }
    results.append((label, bestCPU * 1000, bestGPU * 1000))
}

// String(format:) does not pad Swift strings, so columns are laid out here.
// String(format:) 不會為 Swift 字串補位，故欄位在此自行排版。
func pad(_ s: String, _ w: Int) -> String {
    s.count >= w ? s : s + String(repeating: " ", count: w - s.count)
}
func rpad(_ s: String, _ w: Int) -> String {
    s.count >= w ? s : String(repeating: " ", count: w - s.count) + s
}

print("== Per frame, best of \(iterations) / 每格，取 \(iterations) 次最佳 ==")
print(pad("path", 34) + rpad("cpu ms", 10) + rpad("upload+gpu ms", 15) + rpad("total", 10))
print(String(repeating: "-", count: 69))
for (label, cpu, gpu) in results {
    print(pad(label, 34) + rpad(String(format: "%.2f", cpu), 10)
          + rpad(String(format: "%.2f", gpu), 15)
          + rpad(String(format: "%.2f", cpu + gpu), 10))
}

if results.count >= 2 {
    let a = results[0].1 + results[0].2, b = results[1].1 + results[1].2
    let d = (a - b) / a * 100
    print("")
    print("== Verdict / 結論 ==")
    print(String(format: "  planes save %.2f ms/frame (%.1f%%) / 三平面省下 %.2f ms",
                 a - b, d, a - b))
    print(String(format: "  CPU alpha expansion alone: %.2f ms / 單是補 alpha：%.2f ms",
                 results[0].1, results[0].1))
    for (fps, budget) in [(60, 1000.0/60), (30, 1000.0/30)] {
        let av = a <= budget ? "PASS" : "FAIL", bv = b <= budget ? "PASS" : "FAIL"
        print(String(format: "  %d fps budget %.2f ms — A %@, B %@", fps, budget,
                     av as NSString, bv as NSString))
    }
}
