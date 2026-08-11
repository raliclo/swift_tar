// =====================================================================
//  swift_tar.swift — Multi-core tar archiver in Swift
//  swift_tar.swift — Swift 多核心 tar 打包工具
//
//  Compile: ./compile_tar.sh   (pairs with lzfse-cli.swift, runCLI() stripped)
//  編譯：./compile_tar.sh（與剝除 runCLI() 的 lzfse-cli.swift 一起編譯）
//
//  Design / 設計：
//   - Tar container: POSIX ustar + pax extended headers (long paths, big files)
//     Tar 容器：POSIX ustar + pax 擴充標頭（長路徑、大檔案）
//   - Write codecs: chunked multi-core, same pattern as lzfse2 runParallelEncode
//     寫入引擎：分塊多核心，沿用 lzfse2 runParallelEncode 的平行模式
//       --other3-fast    = LZFSEv1 other3 (standard bvx2; Apple-decodable)
//       --other3-optimal = other3 + -optimal3 (price-driven DP, still standard bvx2)
//       --bvx3-fast      = LZFSEv1 bvx3 private blocks (4-slot lazy parser)
//       --bvx3-optimal   = bvx3 + -optimal (segmented DP optimal parsing)
//       --gzip / -z      = zlib, one gzip member per chunk (pigz-style)
//       --bzip2 / -j     = libbz2, one bzip2 stream per chunk (pbzip2-style)
//       --xz / -J        = liblzma, one xz stream per chunk (xz multi-stream)
//       --zstd           = libzstd, one zstd frame per chunk
//       --lz4            = liblz4, one standard LZ4 frame per chunk
//     All five are standard multi-stream/multi-member concatenations that the
//     stock CLI tools (gunzip/bunzip2/xz/zstd/lz4) decode transparently.
//     以上皆為標準多串流串接，原生 CLI 工具可直接解開。
//   - Read filters (libarchive model: bidder chain, auto-detected by magic,
//     stackable, e.g. payload.tar.gz.uu):
//     讀取端 filter（仿 libarchive：magic 自動偵測、可疊層）：
//       uuencoded files (uu + base64 variants)      / uuencode（含 base64 變體）
//       files with RPM wrapper                      / RPM 外包裝剝除
//       gzip, bzip2, compress/LZW, lzma, lzip, xz,  / 各家壓縮格式
//       lz4, zstandard, LZFSE family (bvx*)
//       lzop: detected; needs liblzo2, reported as unavailable (same behavior
//       as libarchive built without lzo)            / lzop 偵測後回報缺 liblzo2
//   - C-library usage follows libarchive's model: the C lib provides the
//     compression primitive, the container framing is assembled here
//     (see archive_write_add_filter_gzip.c / _lz4.c; compress/LZW, uu and RPM
//     are pure-Swift ports of libarchive's built-in filters).
//     C 庫用法仿 libarchive：C 庫只提供壓縮原語，容器框架由本工具自組；
//     compress/LZW、uu、RPM 為 libarchive 內建 filter 的純 Swift 移植。
//   - LZFSE-family streams decode with the multi-core chunk-parallel decoder
//     from lzfse-cli.swift.
//     LZFSE 家族用 lzfse-cli.swift 的多核心分塊平行解碼器。
//   - True ZIP/ZIP64 containers are created and read through the bundled
//     libarchive backend on macOS and Windows.
//     真實 ZIP/ZIP64 容器在 macOS 與 Windows 上皆透過內附 libarchive 後端建立與讀取。
// =====================================================================

import Foundation
import zlib
#if os(Windows)
// CRT-level file I/O for the -write_ucrt extraction backend (one open per
// file, mtime set on the open fd via _futime64 — same syscall profile as
// bsdtar). This is the C runtime module, NOT WinSDK (removed in R44-Win).
// -write_ucrt 解壓後端所需的 CRT 層檔案 I/O（每檔僅開檔一次，mtime 以
// _futime64 直接設定在已開啟的 fd 上——syscall 輪廓同 bsdtar）。這是 C
// runtime module，並非 R44-Win 已移除的 WinSDK。
import ucrt
#endif

#if os(Linux)
// autoreleasepool is an Objective-C runtime facility and exists only on
// Darwin. The call sites below use it to bound peak memory while reading
// chunks and building Data buffers; on Linux there is no autorelease pool to
// drain, so this is a plain pass-through and the surrounding logic is
// unchanged. Inlined, so it costs nothing at runtime.
// autoreleasepool 屬於 Objective-C runtime，僅存在於 Darwin。下方各呼叫點以它
// 限制逐塊讀取與建立 Data 時的尖峰記憶體；Linux 沒有 autorelease pool 需要
// 排空，因此此處為單純直通，不改變周圍邏輯。標記 inline 故無執行期成本。
@inline(__always)
func autoreleasepool<Result>(invoking body: () throws -> Result) rethrows -> Result {
    try body()
}
#endif

// A narrow C ABI keeps libarchive's C types out of the Swift implementation
// while sharing exactly the same ZIP/ZIP64 backend on macOS and Windows.
// 使用精簡 C ABI 隔離 libarchive C 型別，讓 macOS 與 Windows 共用完全相同的
// ZIP/ZIP64 後端。
@_silgen_name("swift_tar_zip_create")
private func cSwiftTarZipCreate(
    _ archivePath: UnsafePointer<CChar>,
    _ changeDir: UnsafePointer<CChar>,
    _ paths: UnsafePointer<UnsafePointer<CChar>?>,
    _ pathCount: Int,
    _ forceZip64: Int32,
    _ verbose: Int32,
    _ errorBuffer: UnsafeMutablePointer<CChar>,
    _ errorCapacity: Int
) -> Int32

@_silgen_name("swift_tar_zip_read")
private func cSwiftTarZipRead(
    _ archivePath: UnsafePointer<CChar>,
    _ destinationDir: UnsafePointer<CChar>,
    _ extract: Int32,
    _ verbose: Int32,
    _ restoreMtime: Int32,
    _ errorBuffer: UnsafeMutablePointer<CChar>,
    _ errorCapacity: Int
) -> Int32

private func withCStrings<R>(_ strings: [String],
                             _ body: ([UnsafePointer<CChar>]) -> R) -> R {
    var pointers: [UnsafePointer<CChar>] = []
    pointers.reserveCapacity(strings.count)
    func append(_ index: Int) -> R {
        guard index < strings.count else { return body(pointers) }
        return strings[index].withCString { pointer in
            pointers.append(pointer)
            defer { pointers.removeLast() }
            return append(index + 1)
        }
    }
    return append(0)
}

private func isZipMagic(_ archivePath: String) -> Bool {
    guard archivePath != "-", let input = FileHandle(forReadingAtPath: archivePath) else {
        return false
    }
    defer { try? input.close() }
    guard let data = try? input.read(upToCount: 4), data.count == 4 else { return false }
    let bytes = [UInt8](data)
    guard bytes[0] == 0x50 && bytes[1] == 0x4b else { return false }
    return (bytes[2] == 0x03 && bytes[3] == 0x04) ||
           (bytes[2] == 0x05 && bytes[3] == 0x06) ||
           (bytes[2] == 0x06 && bytes[3] == 0x06) ||
           (bytes[2] == 0x07 && bytes[3] == 0x08)
}

private func runZipCreate(archivePath: String, files: [String], changeDir: String,
                          forceZip64: Bool, verbose: Bool) throws {
    guard !files.isEmpty else {
        throw TarError.io("no files to archive / 未指定要打包的檔案")
    }
    var error = [CChar](repeating: 0, count: 4096)
    let status = archivePath.withCString { archive in
        changeDir.withCString { directory in
            withCStrings(files) { filePointers in
                let nullable = filePointers.map(Optional.some)
                return nullable.withUnsafeBufferPointer { paths in
                    cSwiftTarZipCreate(archive, directory, paths.baseAddress!, paths.count,
                                       forceZip64 ? 1 : 0, verbose ? 1 : 0,
                                       &error, error.count)
                }
            }
        }
    }
    guard status == 0 else {
        throw TarError.io(String(cString: error))
    }
}

private func runZipRead(archivePath: String, extract: Bool, destDir: String,
                        verbose: Bool, restoreMtime: Bool) throws {
    var error = [CChar](repeating: 0, count: 4096)
    let status = archivePath.withCString { archive in
        destDir.withCString { directory in
            cSwiftTarZipRead(archive, directory, extract ? 1 : 0, verbose ? 1 : 0,
                             restoreMtime ? 1 : 0, &error, error.count)
        }
    }
    guard status == 0 else {
        throw TarError.io(String(cString: error))
    }
}

/// Streaming chunk size for the decompression/extraction paths (decoder
/// loops, pipe pumps, tar-layer reads and file writes). Raised from 1 MiB
/// to 4 MiB to cut per-chunk call overhead on large archives.
/// 解壓／解出路徑的串流分塊大小（解碼迴圈、pipe 泵送、tar 層讀取與寫檔）。
/// 由 1 MiB 調升為 4 MiB，降低大型封存檔的每塊呼叫成本。
let DECODE_CHUNK = 1 << 22

// 4 MiB parallel chunk size for the tar stream. In a normal build this mirrors
// LZFSEv1.parallelChunkSize; defined locally so the --no-lzfse build (which does
// not compile the LZFSE library) still has it.
// tar 串流的 4 MiB 平行分塊大小。一般建置與 LZFSEv1.parallelChunkSize 相同；此處
// 本地定義，讓不編譯 LZFSE library 的 --no-lzfse 建置仍可使用。
let TAR_CHUNK_SIZE = 1 << 22

#if EXCLUDE_LZFSE
// The LZFSE library also provides eprint(); supply a local one when it is not
// compiled in (--no-lzfse). / LZFSE library 也提供 eprint()，未編入（--no-lzfse）
// 時在此提供本地版本。
func eprint(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}
#endif

// Windows statically links zlib and zstd for in-process gzip and zstd. bzip2,
// xz, lz4, and lzip still shell out to CLI tools. The remaining C-library
// silgen declarations below are macOS/Linux-only.
// Windows 靜態連結 zlib 與 zstd，在程序內處理 gzip 與 zstd；bzip2、xz、lz4
// 與 lzip 仍呼叫外部 CLI 工具。以下其餘 C 庫 silgen 宣告僅用於 macOS/Linux。
#if !os(Windows)

// =================================================================
// MARK: - liblz4 frame API (silgen; standard LZ4 frame format)
// MARK: - liblz4 frame API（silgen 直接宣告；標準 LZ4 frame 格式）
// =================================================================

@_silgen_name("LZ4F_compressFrameBound")
private func LZ4F_compressFrameBound(_ srcSize: Int, _ prefs: UnsafeRawPointer?) -> Int
@_silgen_name("LZ4F_compressFrame")
private func LZ4F_compressFrame(_ dst: UnsafeMutableRawPointer, _ dstCap: Int,
                                _ src: UnsafeRawPointer, _ srcSize: Int,
                                _ prefs: UnsafeRawPointer?) -> Int
@_silgen_name("LZ4F_isError")
private func LZ4F_isError(_ code: Int) -> UInt32
@_silgen_name("LZ4F_createDecompressionContext")
private func LZ4F_createDecompressionContext(_ ctx: UnsafeMutablePointer<OpaquePointer?>,
                                             _ version: UInt32) -> Int
@_silgen_name("LZ4F_freeDecompressionContext")
private func LZ4F_freeDecompressionContext(_ ctx: OpaquePointer?) -> Int
@_silgen_name("LZ4F_decompress")
private func LZ4F_decompress(_ ctx: OpaquePointer?,
                             _ dst: UnsafeMutableRawPointer, _ dstSize: UnsafeMutablePointer<Int>,
                             _ src: UnsafeRawPointer, _ srcSize: UnsafeMutablePointer<Int>,
                             _ opts: UnsafeRawPointer?) -> Int

private let LZ4F_VERSION: UInt32 = 100

// =================================================================
// MARK: - libbz2 API (silgen; SDK ships libbz2.tbd + bzlib.h)
// MARK: - libbz2 API（silgen；SDK 內建 libbz2）
// =================================================================
// bz_stream layout mirrors <bzlib.h>; field order and alignment match the
// C definition exactly. / bz_stream 佈局精確對應 <bzlib.h>。

private struct BZStream {
    var next_in: UnsafeMutablePointer<CChar>? = nil
    var avail_in: UInt32 = 0
    var total_in_lo32: UInt32 = 0
    var total_in_hi32: UInt32 = 0
    var next_out: UnsafeMutablePointer<CChar>? = nil
    var avail_out: UInt32 = 0
    var total_out_lo32: UInt32 = 0
    var total_out_hi32: UInt32 = 0
    var state: UnsafeMutableRawPointer? = nil
    var bzalloc: UnsafeMutableRawPointer? = nil
    var bzfree: UnsafeMutableRawPointer? = nil
    var opaque: UnsafeMutableRawPointer? = nil
}

@_silgen_name("BZ2_bzBuffToBuffCompress")
private func BZ2_bzBuffToBuffCompress(_ dest: UnsafeMutablePointer<CChar>,
                                      _ destLen: UnsafeMutablePointer<UInt32>,
                                      _ source: UnsafeMutablePointer<CChar>, _ sourceLen: UInt32,
                                      _ blockSize100k: Int32, _ verbosity: Int32,
                                      _ workFactor: Int32) -> Int32
@_silgen_name("BZ2_bzDecompressInit")
private func BZ2_bzDecompressInit(_ strm: UnsafeMutableRawPointer, _ verbosity: Int32,
                                  _ small: Int32) -> Int32
@_silgen_name("BZ2_bzDecompress")
private func BZ2_bzDecompress(_ strm: UnsafeMutableRawPointer) -> Int32
@_silgen_name("BZ2_bzDecompressEnd")
private func BZ2_bzDecompressEnd(_ strm: UnsafeMutableRawPointer) -> Int32

private let BZ_OK: Int32 = 0
private let BZ_STREAM_END: Int32 = 4

// =================================================================
// MARK: - liblzma API (silgen; homebrew xz — covers xz / lzma-alone / lzip)
// MARK: - liblzma API（silgen；homebrew xz —— 涵蓋 xz／lzma-alone／lzip）
// =================================================================
// lzma_stream layout mirrors <lzma/base.h> (ABI-stable public struct).
// lzma_stream 佈局精確對應 <lzma/base.h>（公開且 ABI 穩定）。

private struct LZMAStream {
    var next_in: UnsafePointer<UInt8>? = nil
    var avail_in: Int = 0
    var total_in: UInt64 = 0
    var next_out: UnsafeMutablePointer<UInt8>? = nil
    var avail_out: Int = 0
    var total_out: UInt64 = 0
    var allocator: UnsafeRawPointer? = nil
    var internalState: UnsafeMutableRawPointer? = nil
    var reserved_ptr1: UnsafeMutableRawPointer? = nil
    var reserved_ptr2: UnsafeMutableRawPointer? = nil
    var reserved_ptr3: UnsafeMutableRawPointer? = nil
    var reserved_ptr4: UnsafeMutableRawPointer? = nil
    var reserved_int1: UInt64 = 0
    var reserved_int2: UInt64 = 0
    var reserved_int3: Int = 0
    var reserved_int4: Int = 0
    var reserved_enum1: UInt32 = 0
    var reserved_enum2: UInt32 = 0
}

@_silgen_name("lzma_stream_decoder")
private func lzma_stream_decoder(_ strm: UnsafeMutableRawPointer, _ memlimit: UInt64,
                                 _ flags: UInt32) -> Int32
@_silgen_name("lzma_alone_decoder")
private func lzma_alone_decoder(_ strm: UnsafeMutableRawPointer, _ memlimit: UInt64) -> Int32
@_silgen_name("lzma_lzip_decoder")
private func lzma_lzip_decoder(_ strm: UnsafeMutableRawPointer, _ memlimit: UInt64,
                               _ flags: UInt32) -> Int32
@_silgen_name("lzma_code")
private func lzma_code(_ strm: UnsafeMutableRawPointer, _ action: Int32) -> Int32
@_silgen_name("lzma_end")
private func lzma_end(_ strm: UnsafeMutableRawPointer)
@_silgen_name("lzma_stream_buffer_bound")
private func lzma_stream_buffer_bound(_ size: Int) -> Int
@_silgen_name("lzma_easy_buffer_encode")
private func lzma_easy_buffer_encode(_ preset: UInt32, _ check: Int32,
                                     _ allocator: UnsafeRawPointer?,
                                     _ input: UnsafePointer<UInt8>, _ inSize: Int,
                                     _ out: UnsafeMutablePointer<UInt8>,
                                     _ outPos: UnsafeMutablePointer<Int>, _ outSize: Int) -> Int32

private let LZMA_OK: Int32 = 0
private let LZMA_STREAM_END: Int32 = 1
private let LZMA_RUN: Int32 = 0
private let LZMA_FINISH: Int32 = 3
private let LZMA_CONCATENATED: UInt32 = 0x08
private let LZMA_CHECK_CRC64: Int32 = 4

#endif // !os(Windows)

// =================================================================
// MARK: - libzstd API (silgen; static libzstd on Windows, homebrew on macOS)
// MARK: - libzstd API（silgen；Windows 靜態 libzstd、macOS homebrew）
// =================================================================
// zstd runs in-process on ALL platforms — Windows links the static libzstd
// submodule (see build_zstd-win.sh) instead of spawning one zstd.exe per chunk.
// zstd 在所有平台皆 in-process——Windows 連結靜態 libzstd submodule
// （見 build_zstd-win.sh），不再每個 chunk 生一個 zstd.exe。

private struct ZSTDInBuffer {                 // ZSTD_inBuffer
    var src: UnsafeRawPointer? = nil
    var size: Int = 0
    var pos: Int = 0
}
private struct ZSTDOutBuffer {                // ZSTD_outBuffer
    var dst: UnsafeMutableRawPointer? = nil
    var size: Int = 0
    var pos: Int = 0
}

@_silgen_name("ZSTD_compressBound")
private func ZSTD_compressBound(_ srcSize: Int) -> Int
@_silgen_name("ZSTD_compress")
private func ZSTD_compress(_ dst: UnsafeMutableRawPointer, _ dstCap: Int,
                           _ src: UnsafeRawPointer, _ srcSize: Int, _ level: Int32) -> Int
@_silgen_name("ZSTD_isError")
private func ZSTD_isError(_ code: Int) -> UInt32
@_silgen_name("ZSTD_createDStream")
private func ZSTD_createDStream() -> OpaquePointer?
@_silgen_name("ZSTD_freeDStream")
private func ZSTD_freeDStream(_ zds: OpaquePointer?) -> Int
@_silgen_name("ZSTD_decompressStream")
private func ZSTD_decompressStream(_ zds: OpaquePointer?,
                                   _ output: UnsafeMutableRawPointer,
                                   _ input: UnsafeMutableRawPointer) -> Int

#if !os(Windows)

/// Resolve a CLI helper on POSIX platforms. Homebrew paths are included so a
/// non-login shell still finds tools such as lzip.
/// 在 POSIX 平台尋找外部 CLI helper；包含 Homebrew 路徑，讓非 login shell 也
/// 能找到 lzip 這類工具。
private func posixResolveExecutable(_ name: String) -> String? {
    if name.contains("/") {
        return FileManager.default.isExecutableFile(atPath: name) ? name : nil
    }
    let envPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
    let searchDirs = envPath.split(separator: ":").map(String.init)
        + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
    for dir in searchDirs {
        let candidate = "\(dir)/\(name)"
        if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
    }
    return nil
}

/// Run an external POSIX compressor: write `input` to stdin, collect stdout.
/// 呼叫 POSIX 外部壓縮工具：把 input 寫入 stdin，收集 stdout。
private func posixRunCompress(exe: String, args: [String], input: Data) -> Data? {
    guard let path = posixResolveExecutable(exe) else {
        eprint("swift_tar: '\(exe)' not found in PATH / 在 PATH 中找不到 '\(exe)'")
        return nil
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
    process.standardInput = inPipe
    process.standardOutput = outPipe
    process.standardError = errPipe
    guard (try? process.run()) != nil else { return nil }
    let writeHandle = inPipe.fileHandleForWriting
    let writer = Thread {
        try? writeHandle.write(contentsOf: input)
        try? writeHandle.close()
    }
    writer.start()
    let output = outPipe.fileHandleForReading.readDataToEndOfFile()
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        let msg = String(decoding: errData, as: UTF8.self)
        eprint("swift_tar: '\(exe)' exited \(process.terminationStatus): \(msg)")
        return nil
    }
    return output
}

#endif // !os(Windows)

// =================================================================
// MARK: - Windows process-based codec backend
// MARK: - Windows 版：外部程序壓縮引擎
// =================================================================
// Windows process backend for codecs that are not linked in-process
// (bzip2/xz/lz4/lzip, available via scoop). gzip and zstd use the static
// libraries declared above.
// Windows 外部程序 backend 用於未在程序內連結的 codec
//（bzip2/xz/lz4/lzip，由 scoop 提供）；gzip 與 zstd 使用上方宣告的靜態庫。
#if os(Windows)

/// Resolve an executable's full path by searching PATH (Process on Windows
/// needs a resolved path, not a bare command name).
/// 在 PATH 中搜尋執行檔完整路徑（Windows 上 Process 需要完整路徑，不能只給命令名稱）。
private func resolveExecutable(_ name: String) -> String? {
    let env = ProcessInfo.processInfo.environment
    let pathVar = env["Path"] ?? env["PATH"] ?? env["path"] ?? ""
    for dir in pathVar.split(separator: ";") {
        let candidate = "\(dir)\\\(name).exe"
        if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
    }
    return nil
}

/// Run an external compressor: write all of `input` to stdin, collect stdout.
/// 呼叫外部壓縮工具：把 input 全部寫入 stdin，收集 stdout。
private func winRunCompress(exe: String, args: [String], input: Data) -> Data? {
    guard let path = resolveExecutable(exe) else {
        eprint("swift_tar: '\(exe)' not found in PATH / 在 PATH 中找不到 '\(exe)'")
        return nil
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
    process.standardInput = inPipe
    process.standardOutput = outPipe
    process.standardError = errPipe
    guard (try? process.run()) != nil else { return nil }
    let writeHandle = inPipe.fileHandleForWriting
    // A dedicated queue avoids starving behind the concurrent compression
    // workers that are synchronously waiting for this pipe to drain.
    // 使用專用 queue，避免排在同步等待 pipe 排空的壓縮 worker 後方而飢餓。
    DispatchQueue(label: "swifttar.win.codec.stdin").async {
        try? writeHandle.write(contentsOf: input)
        try? writeHandle.close()
    }
    let output = outPipe.fileHandleForReading.readDataToEndOfFile()
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        let msg = String(decoding: errData, as: UTF8.self)
        eprint("swift_tar: '\(exe)' exited \(process.terminationStatus): \(msg)")
        return nil
    }
    return output
}

/// Run an external decompressor: stream `prefix` + the rest of `input` to
/// stdin, stream stdout straight into `output`. Handles concatenated
/// members/streams the same way the stock CLI tools already do.
/// 呼叫外部解壓工具：把 prefix + input 剩餘部分串流進 stdin，stdout 直接串流進
/// output；串接的多成員/多串流沿用各工具原生行為處理。
private func winRunDecompress(exe: String, args: [String], input: FileHandle,
                              prefix: Data, output: FileHandle) -> Bool {
    guard let path = resolveExecutable(exe) else {
        eprint("swift_tar: '\(exe)' not found in PATH / 在 PATH 中找不到 '\(exe)'")
        return false
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
    process.standardInput = inPipe
    process.standardOutput = outPipe
    process.standardError = errPipe
    guard (try? process.run()) != nil else { return false }
    let writeHandle = inPipe.fileHandleForWriting
    // Keep pipe pumping independent of the filter-chain worker pool.
    // 讓 pipe 泵送不受 filter-chain worker pool 飢餓影響。
    DispatchQueue(label: "swifttar.win.codec.stdin").async {
        if !prefix.isEmpty { try? writeHandle.write(contentsOf: prefix) }
        while true {
            let part = input.readData(ofLength: DECODE_CHUNK)
            if part.isEmpty { break }
            try? writeHandle.write(contentsOf: part)
        }
        try? writeHandle.close()
    }
    let readHandle = outPipe.fileHandleForReading
    while true {
        let part = readHandle.readData(ofLength: DECODE_CHUNK)
        if part.isEmpty { break }
        if (try? output.write(contentsOf: part)) == nil { return false }
    }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let msg = String(decoding: errData, as: UTF8.self)
        eprint("swift_tar: '\(exe)' exited \(process.terminationStatus): \(msg)")
        return false
    }
    return true
}

#endif // os(Windows)

// =================================================================
// MARK: - Codec selection (write side) / 壓縮引擎選擇（寫入端）
// =================================================================

enum TarCodec {
    case none                       // plain tar / 純 tar
#if !EXCLUDE_LZFSE
    case other3(optimal: Bool)      // standard bvx2 blocks / 標準 bvx2 區塊
    case bvx3(optimal: Bool)        // private big-alphabet blocks / 私有大字母表區塊
#endif
    case gzip                       // zlib, gzip members / gzip 成員
    case bzip2                      // libbz2 streams / bzip2 串流
    case xz                         // liblzma xz streams / xz 串流
    case lzip                       // lzip streams via CLI / 透過 CLI 產生 lzip 串流
    case zstd                       // libzstd frames / zstd frame
    case lz4                        // liblz4 standard frames / 標準 LZ4 frame

    var isLZFSEFamily: Bool {
#if EXCLUDE_LZFSE
        return false
#else
        switch self { case .other3, .bvx3: return true; default: return false }
#endif
    }

    /// Compress one chunk into an independent, self-contained unit.
    /// All non-LZFSE outputs are standard concatenatable streams.
    /// 將一個分塊壓成獨立自足的單元；非 LZFSE 輸出皆為可串接的標準串流。
    func compressChunk(_ chunk: Data) -> Data? {
        switch self {
        case .none:
            return chunk
#if !EXCLUDE_LZFSE
        case .other3(let opt):
            return LZFSEv1.compressBody(chunk, strong: true, optimal3: opt)
        case .bvx3(let opt):
            return LZFSEv1.compressBody(chunk, strong: true, bvx3: true, optimal: opt)
#endif
        case .gzip:
            return gzipCompressMember(chunk)
        case .bzip2:
            return bzip2CompressStream(chunk)
        case .xz:
            return xzCompressStream(chunk)
        case .lzip:
            return lzipCompressStream(chunk)
        case .zstd:
            return zstdCompressFrame(chunk)
        case .lz4:
            return lz4CompressFrame(chunk)
        }
    }
}

// =================================================================
// MARK: - Write-side chunk compressors / 寫入端分塊壓縮器
// =================================================================
// Container framing follows libarchive's write filters: the C library
// supplies the primitive, we assemble one standalone stream per chunk.
// 容器框架仿 libarchive 的 write filter：C 庫提供原語，每分塊組一個獨立串流。

/// One complete gzip member per chunk (zlib windowBits=31 emits the container).
/// 每分塊一個完整 gzip 成員（windowBits=31 由 zlib 直接輸出 gzip 容器）。
func gzipCompressMember(_ input: Data, level: Int32 = 6) -> Data? {
    var strm = z_stream()
    guard deflateInit2_(&strm, level, Z_DEFLATED, 31, 8, Z_DEFAULT_STRATEGY,
                        ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
    defer { deflateEnd(&strm) }
    var out = Data(count: Int(deflateBound(&strm, uLong(input.count))) + 32)
    var written = 0
    let ok = input.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Bool in
        out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Bool in
            strm.next_in = UnsafeMutablePointer(mutating: src.bindMemory(to: UInt8.self).baseAddress)
            strm.avail_in = uInt(input.count)
            strm.next_out = dst.bindMemory(to: UInt8.self).baseAddress
            strm.avail_out = uInt(dst.count)
            let rc = deflate(&strm, Z_FINISH)
            written = dst.count - Int(strm.avail_out)
            return rc == Z_STREAM_END
        }
    }
    guard ok else { return nil }
    return out.prefix(written)
}

/// One complete bzip2 stream per chunk (pbzip2-style concatenation).
/// 每分塊一個完整 bzip2 串流（pbzip2 式串接）。
func bzip2CompressStream(_ input: Data, blockSize100k: Int32 = 9) -> Data? {
#if os(Windows)
    return winRunCompress(exe: "bzip2", args: ["-\(blockSize100k)", "-c"], input: input)
#else
    var destLen = UInt32(input.count + input.count / 100 + 600)
    var out = Data(count: Int(destLen))
    var src = input   // BZ2 API wants a mutable source pointer / BZ2 API 需要可變來源指標
    let rc: Int32 = src.withUnsafeMutableBytes { s in
        out.withUnsafeMutableBytes { d in
            BZ2_bzBuffToBuffCompress(d.bindMemory(to: CChar.self).baseAddress!, &destLen,
                                     s.bindMemory(to: CChar.self).baseAddress!,
                                     UInt32(input.count), blockSize100k, 0, 0)
        }
    }
    guard rc == BZ_OK else { return nil }
    return out.prefix(Int(destLen))
#endif
}

/// One complete xz stream per chunk (xz multi-stream concatenation).
/// 每分塊一個完整 xz 串流（xz 多串流串接）。
func xzCompressStream(_ input: Data, preset: UInt32 = 6) -> Data? {
#if os(Windows)
    return winRunCompress(exe: "xz", args: ["-\(preset)", "-c"], input: input)
#else
    let bound = lzma_stream_buffer_bound(input.count)
    var out = Data(count: bound)
    var outPos = 0
    let rc: Int32 = input.withUnsafeBytes { s in
        out.withUnsafeMutableBytes { d in
            lzma_easy_buffer_encode(preset, LZMA_CHECK_CRC64, nil,
                                    s.bindMemory(to: UInt8.self).baseAddress!, input.count,
                                    d.bindMemory(to: UInt8.self).baseAddress!, &outPos, bound)
        }
    }
    guard rc == LZMA_OK else { return nil }
    return out.prefix(outPos)
#endif
}

/// One complete lzip stream per chunk. liblzma decodes lzip but does not
/// expose a lzip encoder here, so creation shells out to the lzip CLI.
/// 每分塊一個完整 lzip 串流。liblzma 可解 lzip，但此處未提供 lzip encoder，
/// 因此建立端呼叫 lzip CLI。
func lzipCompressStream(_ input: Data, level: Int32 = 6) -> Data? {
#if os(Windows)
    return winRunCompress(exe: "lzip", args: ["-\(level)", "-c"], input: input)
#else
    return posixRunCompress(exe: "lzip", args: ["-\(level)", "-c"], input: input)
#endif
}

/// One complete zstd frame per chunk (frames concatenate per spec).
/// 每分塊一個完整 zstd frame（依規格可串接）。
func zstdCompressFrame(_ input: Data, level: Int32 = 3) -> Data? {
    let bound = ZSTD_compressBound(input.count)
    var out = Data(count: bound)
    let n: Int = input.withUnsafeBytes { s in
        out.withUnsafeMutableBytes { d in
            ZSTD_compress(d.baseAddress!, bound, s.baseAddress!, input.count, level)
        }
    }
    guard ZSTD_isError(n) == 0 else { return nil }
    return out.prefix(n)
}

/// One standard LZ4 frame per chunk (magic 0x184D2204).
/// 每分塊一個標準 LZ4 frame（magic 0x184D2204）。
func lz4CompressFrame(_ input: Data) -> Data? {
#if os(Windows)
    return winRunCompress(exe: "lz4", args: ["-9", "-q", "-c", "-"], input: input)
#else
    let bound = LZ4F_compressFrameBound(input.count, nil)
    var out = Data(count: bound)
    let n: Int = input.withUnsafeBytes { src in
        out.withUnsafeMutableBytes { dst in
            LZ4F_compressFrame(dst.baseAddress!, bound, src.baseAddress!, input.count, nil)
        }
    }
    guard LZ4F_isError(n) == 0 else { return nil }
    return out.prefix(n)
#endif
}

// =================================================================
// MARK: - ByteReader: buffered pull-reader for filter implementations
// MARK: - ByteReader：filter 實作用的緩衝式讀取器
// =================================================================

final class ByteReader {
    private let fh: FileHandle
    private var buf: Data
    private var pos = 0

    init(_ fh: FileHandle, prefix: Data) {
        self.fh = fh
        self.buf = prefix
    }

    /// Ensure at least n bytes are buffered; returns false at EOF-short.
    /// 確保緩衝內至少 n 位元組；資料不足時回傳 false。
    func ensure(_ n: Int) -> Bool {
        while buf.count - pos < n {
            guard let part = try? fh.read(upToCount: max(n - (buf.count - pos), 1 << 16)),
                  !part.isEmpty else { return false }
            if pos > 0 { buf.removeFirst(pos); pos = 0 }
            buf.append(part)
        }
        return true
    }

    func peek(_ n: Int) -> Data? {
        guard ensure(n) else { return nil }
        return buf.subdata(in: pos..<pos + n)
    }

    func skip(_ n: Int) -> Bool {
        guard ensure(n) else { return false }
        pos += n
        return true
    }

    func readByte() -> UInt8? {
        guard ensure(1) else { return nil }
        let b = buf[buf.startIndex + pos]
        pos += 1
        return b
    }

    /// Read up to n bytes (whatever is available); nil at EOF.
    /// 讀取至多 n 位元組（有多少讀多少）；EOF 回傳 nil。
    func readSome(_ n: Int) -> Data? {
        if buf.count - pos == 0 {
            guard let part = try? fh.read(upToCount: n), !part.isEmpty else { return nil }
            return part
        }
        let take = min(n, buf.count - pos)
        let out = buf.subdata(in: pos..<pos + take)
        pos += take
        return out
    }

    /// Read one text line (without "\n"); nil at EOF with no data.
    /// 讀取一行文字（不含換行）；EOF 且無資料時回傳 nil。
    func readLine(maxLen: Int = 1 << 16) -> String? {
        var line = Data()
        while line.count < maxLen, let b = readByte() {
            if b == UInt8(ascii: "\n") {
                if line.last == UInt8(ascii: "\r") { line.removeLast() }
                return String(decoding: line, as: UTF8.self)
            }
            line.append(b)
        }
        return line.isEmpty ? nil : String(decoding: line, as: UTF8.self)
    }
}

// =================================================================
// MARK: - Read filters (libarchive read-filter ports) / 讀取端 filter
// =================================================================
// All share one shape: (input, prefix, output) -> Bool.
// 統一介面：(輸入, 已嗅探前綴, 輸出) -> 成功與否。

/// Sequential multi-member gzip decode. / 循序解多成員 gzip。
func gzipDecodeStream(input: FileHandle, prefix: Data, output: FileHandle) -> Bool {
    var strm = z_stream()
    guard inflateInit2_(&strm, 15 + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK
    else { return false }
    defer { inflateEnd(&strm) }
    var outBuf = [UInt8](repeating: 0, count: DECODE_CHUNK)
    var atBoundary = true
    let reader = ByteReader(input, prefix: prefix)
    // autoreleasepool: per-chunk reads and Data(bytes:count:) writes are
    // autoreleased; drain each iteration to keep decode RSS bounded.
    // autoreleasepool：逐塊讀取與 Data(bytes:count:) 寫出皆為 autoreleased；
    // 每輪排空以維持 decode RSS 上限。
    while true {
        var eof = false
        var failed = false
        autoreleasepool {
            guard var inBuf = reader.readSome(DECODE_CHUNK).map({ [UInt8]($0) }) else {
                eof = true
                return
            }
            var consumed = 0
            let ok: Bool = inBuf.withUnsafeMutableBufferPointer { ib in
                while consumed < ib.count {
                    strm.next_in = ib.baseAddress! + consumed
                    strm.avail_in = uInt(ib.count - consumed)
                    var rc: Int32 = Z_OK
                    let produced: Int = outBuf.withUnsafeMutableBufferPointer { ob -> Int in
                        strm.next_out = ob.baseAddress
                        strm.avail_out = uInt(ob.count)
                        rc = inflate(&strm, Z_NO_FLUSH)
                        return ob.count - Int(strm.avail_out)
                    }
                    consumed = ib.count - Int(strm.avail_in)
                    if produced > 0 {
                        if (try? output.write(contentsOf: Data(bytes: outBuf, count: produced))) == nil { return false }
                        atBoundary = false
                    }
                    if rc == Z_STREAM_END {
                        inflateReset(&strm)
                        atBoundary = true
                    } else if rc == Z_OK || rc == Z_BUF_ERROR {
                        if rc == Z_BUF_ERROR && strm.avail_in == 0 && produced == 0 { break }
                    } else {
                        return false
                    }
                }
                return true
            }
            if !ok { failed = true }
        }
        if failed { return false }
        if eof { break }
    }
    return atBoundary
}

/// Sequential multi-stream bzip2 decode (pbzip2-style concatenation).
/// 循序解多串流 bzip2（pbzip2 式串接）。
func bzip2DecodeStream(input: FileHandle, prefix: Data, output: FileHandle) -> Bool {
#if os(Windows)
    return winRunDecompress(exe: "bzip2", args: ["-dc"], input: input, prefix: prefix, output: output)
#else
    var strm = BZStream()
    guard withUnsafeMutablePointer(to: &strm, { BZ2_bzDecompressInit($0, 0, 0) }) == BZ_OK
    else { return false }
    var open = true
    defer { if open { _ = withUnsafeMutablePointer(to: &strm) { BZ2_bzDecompressEnd($0) } } }
    var outBuf = [UInt8](repeating: 0, count: DECODE_CHUNK)
    var atBoundary = true
    let reader = ByteReader(input, prefix: prefix)
    while var inBuf = reader.readSome(DECODE_CHUNK).map({ [UInt8]($0) }) {
        var consumed = 0
        let ok: Bool = inBuf.withUnsafeMutableBufferPointer { ib in
            while consumed < ib.count {
                var rc: Int32 = BZ_OK
                var produced = 0
                outBuf.withUnsafeMutableBufferPointer { ob in
                    withUnsafeMutablePointer(to: &strm) { sp in
                        sp.pointee.next_in = UnsafeMutableRawPointer(ib.baseAddress! + consumed)
                            .assumingMemoryBound(to: CChar.self)
                        sp.pointee.avail_in = UInt32(ib.count - consumed)
                        sp.pointee.next_out = UnsafeMutableRawPointer(ob.baseAddress!)
                            .assumingMemoryBound(to: CChar.self)
                        sp.pointee.avail_out = UInt32(ob.count)
                        rc = BZ2_bzDecompress(sp)
                        consumed = ib.count - Int(sp.pointee.avail_in)
                        produced = ob.count - Int(sp.pointee.avail_out)
                    }
                }
                if produced > 0 {
                    if (try? output.write(contentsOf: Data(bytes: outBuf, count: produced))) == nil { return false }
                    atBoundary = false
                }
                if rc == BZ_STREAM_END {
                    // next concatenated stream: re-init / 換下一段串流：重新初始化
                    _ = withUnsafeMutablePointer(to: &strm) { BZ2_bzDecompressEnd($0) }
                    strm = BZStream()
                    guard withUnsafeMutablePointer(to: &strm, { BZ2_bzDecompressInit($0, 0, 0) }) == BZ_OK
                    else { open = false; return false }
                    atBoundary = true
                } else if rc != BZ_OK {
                    return false
                } else if produced == 0 && consumed == ib.count {
                    break
                }
            }
            return true
        }
        if !ok { return false }
    }
    return atBoundary
#endif
}

/// liblzma-family decode: .xz / .lzma (alone) / .lz (lzip).
/// liblzma 家族解碼：.xz／.lzma（alone）／.lz（lzip）。
enum LZMAKind { case xz, alone, lzip }
func lzmaDecodeStream(kind: LZMAKind, input: FileHandle, prefix: Data, output: FileHandle) -> Bool {
#if os(Windows)
    switch kind {
    case .xz:    return winRunDecompress(exe: "xz", args: ["-dc"], input: input, prefix: prefix, output: output)
    case .alone: return winRunDecompress(exe: "xz", args: ["-dc", "--format=lzma"], input: input, prefix: prefix, output: output)
    case .lzip:  return winRunDecompress(exe: "lzip", args: ["-dc"], input: input, prefix: prefix, output: output)
    }
#else
    var strm = LZMAStream()
    let initRC: Int32 = withUnsafeMutablePointer(to: &strm) { sp in
        switch kind {
        case .xz:    return lzma_stream_decoder(sp, UInt64.max, LZMA_CONCATENATED)
        case .alone: return lzma_alone_decoder(sp, UInt64.max)
        case .lzip:  return lzma_lzip_decoder(sp, UInt64.max, LZMA_CONCATENATED)
        }
    }
    guard initRC == LZMA_OK else { return false }
    defer { withUnsafeMutablePointer(to: &strm) { lzma_end($0) } }
    var outBuf = [UInt8](repeating: 0, count: DECODE_CHUNK)
    var ended = false
    let reader = ByteReader(input, prefix: prefix)
    var pending: [UInt8]? = reader.readSome(DECODE_CHUNK).map { [UInt8]($0) }
    while let inBuf = pending {
        let next = reader.readSome(DECODE_CHUNK).map { [UInt8]($0) }
        let action: Int32 = next == nil ? LZMA_FINISH : LZMA_RUN
        var consumed = 0
        let ok: Bool = inBuf.withUnsafeBufferPointer { ib in
            while consumed < ib.count || (action == LZMA_FINISH && !ended) {
                var rc: Int32 = LZMA_OK
                var produced = 0
                outBuf.withUnsafeMutableBufferPointer { ob in
                    withUnsafeMutablePointer(to: &strm) { sp in
                        sp.pointee.next_in = ib.baseAddress! + consumed
                        sp.pointee.avail_in = ib.count - consumed
                        sp.pointee.next_out = ob.baseAddress!
                        sp.pointee.avail_out = ob.count
                        rc = lzma_code(sp, action)
                        consumed = ib.count - sp.pointee.avail_in
                        produced = ob.count - sp.pointee.avail_out
                    }
                }
                if produced > 0 {
                    if (try? output.write(contentsOf: Data(bytes: outBuf, count: produced))) == nil { return false }
                }
                if rc == LZMA_STREAM_END { ended = true; break }
                if rc != LZMA_OK { return false }
                if produced == 0 && consumed == ib.count && action == LZMA_RUN { break }
            }
            return true
        }
        if !ok { return false }
        if ended { break }
        pending = next
        if next == nil { break }
    }
    // .alone has no CONCATENATED mode; reaching clean EOF is acceptable.
    // .alone 無 CONCATENATED 模式；讀至 EOF 即視為結束。
    return ended || kind == .alone
#endif
}

/// zstd streaming decode (handles back-to-back frames).
/// zstd 串流解碼（自動處理背靠背 frame）。
func zstdDecodeStream(input: FileHandle, prefix: Data, output: FileHandle) -> Bool {
    guard let zds = ZSTD_createDStream() else { return false }
    defer { _ = ZSTD_freeDStream(zds) }
    var outBuf = [UInt8](repeating: 0, count: DECODE_CHUNK)
    var lastRet = 0
    let reader = ByteReader(input, prefix: prefix)
    while let chunk = reader.readSome(DECODE_CHUNK).map({ [UInt8]($0) }) {
        let ok: Bool = chunk.withUnsafeBufferPointer { ib in
            var inB = ZSTDInBuffer(src: UnsafeRawPointer(ib.baseAddress), size: ib.count, pos: 0)
            while inB.pos < inB.size {
                var produced = 0
                var ret = 0
                outBuf.withUnsafeMutableBufferPointer { ob in
                    var outB = ZSTDOutBuffer(dst: UnsafeMutableRawPointer(ob.baseAddress),
                                             size: ob.count, pos: 0)
                    ret = withUnsafeMutablePointer(to: &outB) { op in
                        withUnsafeMutablePointer(to: &inB) { ip in
                            ZSTD_decompressStream(zds, op, ip)
                        }
                    }
                    produced = outB.pos
                }
                if ZSTD_isError(ret) != 0 { return false }
                lastRet = ret
                if produced > 0 {
                    if (try? output.write(contentsOf: Data(bytes: outBuf, count: produced))) == nil { return false }
                }
                if produced == 0 && inB.pos == inB.size { break }
            }
            return true
        }
        if !ok { return false }
    }
    return lastRet == 0   // 0 ⟺ frame boundary at EOF / EOF 落在 frame 邊界
}

/// Sequential decode of concatenated LZ4 frames. / 循序解串接 LZ4 frame。
func lz4DecodeStream(input: FileHandle, prefix: Data, output: FileHandle) -> Bool {
#if os(Windows)
    return winRunDecompress(exe: "lz4", args: ["-dc", "-q"], input: input, prefix: prefix, output: output)
#else
    var ctx: OpaquePointer? = nil
    guard LZ4F_isError(LZ4F_createDecompressionContext(&ctx, LZ4F_VERSION)) == 0 else { return false }
    defer { _ = LZ4F_freeDecompressionContext(ctx) }
    var outBuf = [UInt8](repeating: 0, count: DECODE_CHUNK)
    var lastHint = 0
    let reader = ByteReader(input, prefix: prefix)
    while let chunk = reader.readSome(DECODE_CHUNK).map({ [UInt8]($0) }) {
        var srcPos = 0
        let ok: Bool = chunk.withUnsafeBufferPointer { ib in
            while srcPos < ib.count {
                var dstSize = outBuf.count
                var srcSize = ib.count - srcPos
                let hint: Int = outBuf.withUnsafeMutableBufferPointer { ob in
                    LZ4F_decompress(ctx, ob.baseAddress!, &dstSize,
                                    ib.baseAddress! + srcPos, &srcSize, nil)
                }
                if LZ4F_isError(hint) != 0 { return false }
                if dstSize > 0 {
                    if (try? output.write(contentsOf: Data(bytes: outBuf, count: dstSize))) == nil { return false }
                }
                srcPos += srcSize
                lastHint = hint
                if dstSize == 0 && srcSize == 0 { break }
            }
            return true
        }
        if !ok { return false }
    }
    return lastHint == 0
#endif
}

/// compress/LZW (.Z) decoder — pure-Swift port of libarchive's
/// archive_read_support_filter_compress.c (including the historical
/// junk-byte skip after each reset code).
/// compress/LZW（.Z）解碼器 —— libarchive 內建 filter 的純 Swift 移植
/// （含 reset code 之後跳過殘餘位元組的歷史怪癖）。
func lzwDecodeStream(input: FileHandle, prefix: Data, output: FileHandle) -> Bool {
    let reader = ByteReader(input, prefix: prefix)
    // header / 標頭
    guard reader.readByte() == 0x1F, reader.readByte() == 0x9D,
          let flags = reader.readByte(), (flags & 0x60) == 0 else { return false }
    let maxBits = Int(flags & 0x1F)
    guard maxBits >= 9 && maxBits <= 16 else { return false }
    let useReset = (flags & 0x80) != 0
    let maxCode = 1 << maxBits

    var bits = 9
    var sectionEnd = (1 << bits) - 1
    var bitBuffer: UInt32 = 0
    var bitsAvail = 0
    var bytesInSection = 0
    var freeEnt = useReset ? 257 : 256
    var oldCode = -1
    var finByte = 0
    var prefixTab = [Int](repeating: 0, count: 65536)
    var suffixTab = [UInt8](repeating: 0, count: 65536)
    for c in 0..<256 { suffixTab[c] = UInt8(c) }
    var stack = [UInt8]()
    stack.reserveCapacity(65536)
    var outBuf = Data(); outBuf.reserveCapacity(DECODE_CHUNK)

    func getbits(_ n: Int) -> Int? {
        while bitsAvail < n {
            guard let b = reader.readByte() else { return nil }
            bitBuffer |= UInt32(b) << bitsAvail
            bitsAvail += 8
            bytesInSection += 1
        }
        let code = Int(bitBuffer & ((1 << UInt32(n)) - 1))
        bitBuffer >>= UInt32(n)
        bitsAvail -= n
        return code
    }
    func flushOut() -> Bool {
        guard !outBuf.isEmpty else { return true }
        let ok = (try? output.write(contentsOf: outBuf)) != nil
        outBuf.removeAll(keepingCapacity: true)
        return ok
    }

    while true {
        // emit pending stack / 先倒出堆疊中的展開結果
        while let b = stack.popLast() {
            outBuf.append(b)
            if outBuf.count >= (DECODE_CHUNK) { if !flushOut() { return false } }
        }
        guard var code = getbits(bits) else { break }   // EOF = normal end / EOF 即正常結束
        let newCode = code
        if code == 256 && useReset {
            // historical junk-byte skip (a function of current bit length!)
            // 歷史怪癖：重置後要跳過的「位元組數」由當前位元長度決定
            var skip = (bits - (bytesInSection % bits)) % bits
            bitsAvail = 0; bitBuffer = 0
            while skip > 0 { guard reader.readByte() != nil else { return false }; skip -= 1 }
            bytesInSection = 0
            bits = 9; sectionEnd = (1 << bits) - 1
            freeEnt = 257; oldCode = -1
            continue
        }
        if code > freeEnt || (code == freeEnt && oldCode < 0) { return false }
        if code >= freeEnt {          // KwKwK special case / KwKwK 特例
            stack.append(UInt8(finByte))
            code = oldCode
        }
        while code >= 256 {
            stack.append(suffixTab[code])
            code = prefixTab[code]
        }
        finByte = code
        stack.append(UInt8(finByte))
        if freeEnt < maxCode && oldCode >= 0 {
            prefixTab[freeEnt] = oldCode
            suffixTab[freeEnt] = UInt8(finByte)
            freeEnt += 1
        }
        if freeEnt > sectionEnd {
            bits += 1
            bytesInSection = 0
            sectionEnd = bits == maxBits ? maxCode : (1 << bits) - 1
        }
        oldCode = newCode
    }
    while let b = stack.popLast() { outBuf.append(b) }
    return flushOut()
}

/// uudecode filter (classic uu and base64 variants), port of libarchive's
/// archive_read_support_filter_uu.c behavior.
/// uudecode filter（傳統 uu 與 base64 兩種變體），仿 libarchive 行為。
func uuDecodeStream(input: FileHandle, prefix: Data, output: FileHandle) -> Bool {
    let reader = ByteReader(input, prefix: prefix)
    var inBody = false
    var isBase64 = false
    var wroteAny = false
    while let line = reader.readLine() {
        if !inBody {
            if line.hasPrefix("begin-base64 ") { inBody = true; isBase64 = true; continue }
            if line.hasPrefix("begin ") { inBody = true; isBase64 = false; continue }
            continue   // skip leading garbage lines / 跳過前置雜訊行
        }
        if isBase64 {
            if line == "====" { inBody = false; wroteAny = true; continue }
            guard let d = Data(base64Encoded: line) else { return false }
            if (try? output.write(contentsOf: d)) == nil { return false }
        } else {
            if line == "end" { inBody = false; wroteAny = true; continue }
            let bytes = Array(line.utf8)
            guard let first = bytes.first else { continue }
            let len = Int((first - 0x20) & 0x3F)
            if len == 0 { continue }                    // "`" length-0 line / 長度 0 行
            var out = [UInt8](); out.reserveCapacity(len)
            var i = 1
            func dec(_ c: UInt8) -> UInt8 { (c - 0x20) & 0x3F }
            while out.count < len {
                guard i + 3 < bytes.count + 4 else { break }
                // tolerate short trailing groups (space-stripped lines)
                // 容忍結尾被截短的群組（有些工具會去掉尾端空白）
                let c0 = i < bytes.count ? dec(bytes[i]) : 0
                let c1 = i + 1 < bytes.count ? dec(bytes[i + 1]) : 0
                let c2 = i + 2 < bytes.count ? dec(bytes[i + 2]) : 0
                let c3 = i + 3 < bytes.count ? dec(bytes[i + 3]) : 0
                out.append((c0 << 2) | (c1 >> 4))
                if out.count < len { out.append((c1 << 4) | (c2 >> 2)) }
                if out.count < len { out.append((c2 << 6) | c3) }
                i += 4
            }
            guard out.count == len else { return false }
            if (try? output.write(contentsOf: Data(out))) == nil { return false }
        }
    }
    return wroteAny && !inBody   // must have seen a complete section / 必須有完整段落
}

/// RPM wrapper strip, port of libarchive archive_read_support_filter_rpm.c:
/// 96-byte lead → N×(header magic 8E AD E8 01, len = 16 + nindex·16 + hsize)
/// → zero padding → payload (typically cpio.gz/xz/zstd; use --cat for it).
/// RPM 外包裝剝除（仿 libarchive）：96 位元組 lead → 連續 header → 零填充
/// → payload（通常為 cpio.gz/xz/zstd；可用 --cat 取出）。
func rpmUnwrapStream(input: FileHandle, prefix: Data, output: FileHandle) -> Bool {
    let reader = ByteReader(input, prefix: prefix)
    guard reader.skip(96) else { return false }        // RPM lead
    var seenHeader = false
    while let intro = reader.peek(16) {
        let h = [UInt8](intro)
        guard h[0] == 0x8E && h[1] == 0xAD && h[2] == 0xE8 && h[3] == 0x01 else { break }
        seenHeader = true
        let nindex = Int(h[8]) << 24 | Int(h[9]) << 16 | Int(h[10]) << 8 | Int(h[11])
        let hsize = Int(h[12]) << 24 | Int(h[13]) << 16 | Int(h[14]) << 8 | Int(h[15])
        guard reader.skip(16 + nindex * 16 + hsize) else { return false }
        // skip zero padding up to the next section / 跳過零填充
        while let b = reader.peek(1), b[0] == 0 { _ = reader.skip(1) }
    }
    guard seenHeader else { return false }
    while let part = reader.readSome(DECODE_CHUNK) {
        if (try? output.write(contentsOf: part)) == nil { return false }
    }
    return true
}

// =================================================================
// MARK: - Filter sniffing & chain (libarchive bidder model)
// MARK: - Filter 嗅探與鏈式解包（仿 libarchive bidder 機制）
// =================================================================

/// How the reader obtains the key for an encrypted archive. Set once from the
/// parsed command line before any archive is opened; the filter chain is
/// resolved deep inside the reader, so threading a key through every call site
/// would touch far more code than this single hand-off.
/// 讀取端取得加密封存金鑰的方式。於解析命令列後、開啟封存前設定一次；filter 鏈
/// 在讀取端深處解析，若要逐層傳遞金鑰，改動範圍遠大於此單一交接點。
var tarDecryptionSecretProvider: (() throws -> TarCrypto.KeySecret)? = nil

/// Set when `--encrypt` (or `--keyfile` with `-c`) is given; nil means the
/// archive is written in the clear. / 指定 `--encrypt`（或 `-c` 搭配 `--keyfile`）
/// 時設定；nil 表示封存不加密。
var tarEncryptionSecret: TarCrypto.KeySecret? = nil

enum ReadFilter {
#if EXCLUDE_LZFSE
    case gzip, bzip2, xz, lzmaAlone, lzip, lz4, zstd, compressLZW, uu, rpm, lzop, encrypted
#else
    case gzip, bzip2, xz, lzmaAlone, lzip, lz4, zstd, compressLZW, uu, rpm, lzfse, lzop, encrypted
#endif

    var name: String {
        switch self {
        case .gzip: return "gzip";        case .bzip2: return "bzip2"
        case .xz: return "xz";            case .lzmaAlone: return "lzma"
        case .lzip: return "lzip";        case .lz4: return "lz4"
        case .zstd: return "zstd";        case .compressLZW: return "compress (.Z)"
        case .uu: return "uudecode";      case .rpm: return "rpm"
#if !EXCLUDE_LZFSE
        case .lzfse: return "lzfse"
#endif
        case .lzop: return "lzop"
        case .encrypted: return "encrypted (ChaCha20-Poly1305)"
        }
    }
}

/// Magic-based detection over the first 16 bytes. / 依前 16 位元組 magic 偵測。
func sniffFilter(_ head: [UInt8]) -> ReadFilter? {
    let b = head + [UInt8](repeating: 0, count: max(0, 16 - head.count))
    // The encryption layer wraps everything else, so it is checked first.
    // 加密層包在最外層，故最先檢查。
    if Array(b[0..<8]) == TarCrypto.magic { return .encrypted }
    if b[0] == 0x1F && b[1] == 0x8B { return .gzip }
    if b[0] == 0x1F && b[1] == 0x9D { return .compressLZW }
    if b[0] == UInt8(ascii: "B") && b[1] == UInt8(ascii: "Z") && b[2] == UInt8(ascii: "h"),
       b[3] >= UInt8(ascii: "1") && b[3] <= UInt8(ascii: "9") { return .bzip2 }
    if b[0] == 0xFD && b[1] == 0x37 && b[2] == 0x7A && b[3] == 0x58
        && b[4] == 0x5A && b[5] == 0x00 { return .xz }
    if b[0] == UInt8(ascii: "L") && b[1] == UInt8(ascii: "Z")
        && b[2] == UInt8(ascii: "I") && b[3] == UInt8(ascii: "P") { return .lzip }
    if b[0] == 0x04 && b[1] == 0x22 && b[2] == 0x4D && b[3] == 0x18 { return .lz4 }
    if b[0] == 0x28 && b[1] == 0xB5 && b[2] == 0x2F && b[3] == 0xFD { return .zstd }
    if b[0] == 0x89 && b[1] == UInt8(ascii: "L") && b[2] == UInt8(ascii: "Z")
        && b[3] == UInt8(ascii: "O") && b[4] == 0x00 { return .lzop }
    if b[0] == 0xED && b[1] == 0xAB && b[2] == 0xEE && b[3] == 0xDB { return .rpm }
#if !EXCLUDE_LZFSE
    if b[0] == UInt8(ascii: "b") && b[1] == UInt8(ascii: "v") && b[2] == UInt8(ascii: "x") { return .lzfse }
#endif
    // .lzma alone: properties byte (commonly 0x5D) + LE dict size whose two
    // low bytes are zero for the usual power-of-two sizes.
    // .lzma alone：屬性位元組（常見 0x5D）+ LE 字典大小（常見 2 的冪，低位為零）。
    if b[0] == 0x5D && b[1] == 0x00 && b[2] == 0x00 { return .lzmaAlone }
    let text = String(decoding: head.prefix(13), as: UTF8.self)
    if text.hasPrefix("begin ") || text.hasPrefix("begin-base64 ") { return .uu }
    return nil
}

/// Thread-safe accumulated result of all decoder layers.
/// 各層解碼執行緒的共同結果（thread-safe）。
final class ChainResult: @unchecked Sendable {
    private let lock = NSLock()
    private var _ok = true
    private var _message: String? = nil
    var ok: Bool { lock.lock(); defer { lock.unlock() }; return _ok }
    var message: String? { lock.lock(); defer { lock.unlock() }; return _message }
    func fail(_ msg: String) { lock.lock(); _ok = false; _message = _message ?? msg; lock.unlock() }
}

struct FilteredStream {
    let handle: FileHandle       // read end after all filters / 過完所有 filter 的讀取端
    let prefix: Data             // sniffed bytes not yet consumed / 已嗅探未消費的前綴
    let names: [String]          // applied filter names / 已套用的 filter 名稱
}

/// Peel filters recursively until no bidder claims the stream.
/// 遞迴剝除 filter，直到沒有任何 bidder 認領。
func resolveFilterChain(input: FileHandle, prefix: Data, filePath: String?,
                        inflight: Int, group: DispatchGroup, result: ChainResult,
                        depth: Int = 0, names: [String] = []) -> FilteredStream {
    var head = prefix
    while head.count < 16, let part = try? input.read(upToCount: 16 - head.count), !part.isEmpty {
        head.append(part)
    }
    guard depth < 8, let filter = sniffFilter([UInt8](head)) else {
        return FilteredStream(handle: input, prefix: head, names: names)
    }
    if case .lzop = filter {
        // Same behavior as libarchive built without liblzo2: detected, then
        // reported as unavailable. / 與缺 liblzo2 的 libarchive 行為一致。
        result.fail("lzop detected but liblzo2 is not available (brew install lzop) / 偵測到 lzop，但缺 liblzo2")
        return FilteredStream(handle: input, prefix: head, names: names + [filter.name])
    }
    // Resolve the key before going async: prompting for a passphrase from the
    // decode thread would interleave with the reader's own output.
    // 在轉入背景執行緒前先取得金鑰：於解碼執行緒提示輸入密語會與讀取端輸出交錯。
    var encryptionSecret: TarCrypto.KeySecret? = nil
    if case .encrypted = filter {
        guard let provider = tarDecryptionSecretProvider else {
            result.fail("archive is encrypted — supply --keyfile <path>, or run on a terminal to be prompted"
                        + " / 封存已加密——請以 --keyfile <path> 提供金鑰，或於終端機執行以輸入密語")
            return FilteredStream(handle: input, prefix: head, names: names + [filter.name])
        }
        do { encryptionSecret = try provider() } catch {
            result.fail(error.localizedDescription)
            return FilteredStream(handle: input, prefix: head, names: names + [filter.name])
        }
    }

    let pipe = Pipe()
    let w = pipe.fileHandleForWriting
    let capturedHead = head
    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
        let ok: Bool
        switch filter {
        case .gzip:        ok = gzipDecodeStream(input: input, prefix: capturedHead, output: w)
        case .bzip2:       ok = bzip2DecodeStream(input: input, prefix: capturedHead, output: w)
        case .xz:          ok = lzmaDecodeStream(kind: .xz, input: input, prefix: capturedHead, output: w)
        case .lzmaAlone:   ok = lzmaDecodeStream(kind: .alone, input: input, prefix: capturedHead, output: w)
        case .lzip:        ok = lzmaDecodeStream(kind: .lzip, input: input, prefix: capturedHead, output: w)
        case .lz4:         ok = lz4DecodeStream(input: input, prefix: capturedHead, output: w)
        case .zstd:        ok = zstdDecodeStream(input: input, prefix: capturedHead, output: w)
        case .compressLZW: ok = lzwDecodeStream(input: input, prefix: capturedHead, output: w)
        case .uu:          ok = uuDecodeStream(input: input, prefix: capturedHead, output: w)
        case .rpm:         ok = rpmUnwrapStream(input: input, prefix: capturedHead, output: w)
#if !EXCLUDE_LZFSE
        case .lzfse:
            // Top layer + real file → multi-core chunk-parallel file decoder.
            // 最外層且輸入為檔案 → 多核心分塊平行檔案解碼。
            if depth == 0, let p = filePath, p != "-" {
                switch LZFSEv1.decodeStreamFromFile(path: p, chunkRaw: LZFSEv1.parallelChunkSize,
                                                    inflight: inflight, output: w) {
                case .ok:       ok = true
                case .error:    ok = false
                case .fallback: ok = wholeBufferLZFSEDecode(input: input, head: capturedHead,
                                                            filePath: p, inflight: inflight, output: w)
                }
            } else {
                ok = wholeBufferLZFSEDecode(input: input, head: capturedHead, filePath: nil,
                                            inflight: inflight, output: w)
            }
#endif
        case .lzop:
            ok = false
        case .encrypted:
            // Authenticated decryption; the decrypted bytes are then re-sniffed
            // by the recursive call below, so an encrypted .tar.gz still works.
            // 認證解密；解密後的位元組由下方遞迴再次嗅探，因此加密的 .tar.gz 亦可運作。
            do {
                try TarCrypto.decryptStream(input: input, prefix: capturedHead, output: w,
                                            secret: encryptionSecret!, inflight: inflight)
                ok = true
            } catch {
                result.fail(error.localizedDescription)
                ok = false
            }
        }
        if !ok { result.fail("\(filter.name) decode failed / \(filter.name) 解碼失敗") }
        try? w.close()
        group.leave()
    }
    return resolveFilterChain(input: pipe.fileHandleForReading, prefix: Data(),
                              filePath: nil, inflight: inflight, group: group,
                              result: result, depth: depth + 1, names: names + [filter.name])
}

#if !EXCLUDE_LZFSE
/// Whole-buffer LZFSE-family decode (nested layers / stdin / foreign streams).
/// 整檔緩衝的 LZFSE 家族解碼（巢狀層、標準輸入或外來串流）。
func wholeBufferLZFSEDecode(input: FileHandle, head: Data, filePath: String?,
                            inflight: Int, output: FileHandle) -> Bool {
    var src: [UInt8]
    if let p = filePath, let fh = FileHandle(forReadingAtPath: p) {
        defer { try? fh.close() }
        src = []
        if let attrs = try? FileManager.default.attributesOfItem(atPath: p),
           let size = (attrs[.size] as? NSNumber)?.intValue { src.reserveCapacity(size) }
        while let part = try? fh.read(upToCount: DECODE_CHUNK), !part.isEmpty {
            src.append(contentsOf: part)
        }
    } else {
        src = [UInt8](head)
        while let part = try? input.read(upToCount: DECODE_CHUNK), !part.isEmpty {
            src.append(contentsOf: part)
        }
    }
    return LZFSEv1.decodeStreamToHandle(src, parallel: true,
                                        chunkRaw: LZFSEv1.parallelChunkSize,
                                        inflight: inflight, output: output)
}
#endif

// =================================================================
// MARK: - Multi-core chunked compression sink
// MARK: - 多核心分塊壓縮匯出端（同 lzfse2 runParallelEncode 的平行模式）
// =================================================================
// Push-based variant of runParallelEncode: the tar serializer streams bytes
// in; every full 4MiB chunk is compressed on a concurrent queue and written
// back in order (semaphore bounds in-flight chunks, lock + writeIndex keeps
// output ordered) — identical concurrency skeleton to lzfse2.
// runParallelEncode 的推送式變體：tar 序列化器持續灌入位元組，每滿 4MiB
// 便丟進併發佇列壓縮、按序寫回（semaphore 限制在途分塊、lock + writeIndex
// 保序）—— 與 lzfse2 完全相同的併發骨架。

final class ParallelChunkSink {
    private let codec: TarCodec
    private let output: FileHandle
    private let chunkSize: Int
    private let sem: DispatchSemaphore
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "swifttar.parallel", qos: .userInitiated,
                                      attributes: .concurrent)
    private let group = DispatchGroup()
    private var buffer = Data()
    private var readIndex = 0

    private final class State: @unchecked Sendable {
        var results: [Int: Data] = [:]
        var writeIndex = 0
        var failure: String? = nil
    }
    private let state = State()

    init(codec: TarCodec, output: FileHandle, inflight: Int,
         chunkSize: Int = TAR_CHUNK_SIZE) {
        self.codec = codec
        self.output = output
        self.chunkSize = chunkSize
        self.sem = DispatchSemaphore(value: max(2, inflight))
    }

    func write(_ data: Data) throws {
        if case .none = codec {          // passthrough / 純 tar 直寫
            try output.write(contentsOf: data)
            return
        }
        // Fill the staging buffer to exactly chunkSize, then hand the whole
        // Data to the worker and start a fresh one. The old append +
        // removeFirst pattern kept extending one backing store to the size
        // of the entire tar stream (removeFirst retains storage), which
        // showed up as a single ~1GB malloc node.
        // 將暫存緩衝填到剛好 chunkSize 後整塊交給 worker，再換一塊新的。
        // 舊的 append + removeFirst 模式會讓同一塊 backing store 延長到
        // 整條 tar stream 的大小（removeFirst 保留儲存空間），實測出現
        // 單筆約 1GB 的 malloc 節點。
        var rest = data[data.startIndex...]
        while !rest.isEmpty {
            let take = min(chunkSize - buffer.count, rest.count)
            buffer.append(rest.prefix(take))
            rest = rest.dropFirst(take)
            if buffer.count == chunkSize {
                let chunk = buffer
                buffer = Data()
                buffer.reserveCapacity(chunkSize)
                dispatch(chunk)
            }
        }
        if let f = state.failure { throw TarError.io(f) }
    }

    private func dispatch(_ chunk: Data) {
        sem.wait()
        let idx = readIndex
        readIndex += 1
        let codec = self.codec
        group.enter()
        queue.async { [self] in
            // autoreleasepool: GCD worker threads drain pools lazily; compressed
            // chunk buffers otherwise linger past their ordered write.
            // autoreleasepool：GCD worker 執行緒的 pool 排空時機不定；壓縮後的
            // chunk 緩衝區會在按序寫出後仍滯留。
            autoreleasepool {
                let body = codec.compressChunk(chunk)
                lock.lock()
                if let body = body {
                    state.results[idx] = body
                    while let r = state.results.removeValue(forKey: state.writeIndex) {
                        do { try output.write(contentsOf: r) }
                        catch { state.failure = state.failure ?? "\(error)" }
                        state.writeIndex += 1
                    }
                } else {
                    state.failure = state.failure ?? "chunk compression failed"
                }
                lock.unlock()
            }
            sem.signal()
            group.leave()
        }
    }

    /// Flush the tail chunk, wait for all workers, write the stream terminator.
    /// 沖出尾塊、等待所有 worker，寫入串流終止符。
    func finish() throws {
        if case .none = codec { return }
        if !buffer.isEmpty {
            let chunk = buffer
            buffer = Data()
            dispatch(chunk)
        }
        group.wait()
        if let f = state.failure { throw TarError.io(f) }
        if codec.isLZFSEFamily {
            try output.write(contentsOf: Data([0x62, 0x76, 0x78, 0x24]))  // 'bvx$'
        }
    }
}

// =================================================================
// MARK: - Tar format shared bits / Tar 格式共用工具
// =================================================================

enum TarError: LocalizedError {
    case io(String)
    case format(String)
    var errorDescription: String? {
        switch self {
        case .io(let m):     return "I/O error: \(m)"
        case .format(let m): return "Tar format error: \(m)"
        }
    }
}

let TAR_BLOCK = 512

/// Zero-padded octal field with trailing NUL, e.g. "%07o\0" for width 8.
/// 零填充八進位欄位、尾隨 NUL，例如寬度 8 時為 "%07o\0"。
private func octalField(_ value: UInt64, width: Int) -> [UInt8] {
    let digits = String(value, radix: 8)
    let pad = String(repeating: "0", count: max(0, width - 1 - digits.count))
    var bytes = Array((pad + digits).utf8.suffix(width - 1))
    bytes.append(0)
    return bytes
}

/// Parse an octal field; also accepts GNU base-256 (first byte high bit set).
/// 解析八進位欄位；同時接受 GNU base-256（首位元組最高位為 1）。
private func parseTarNumber(_ field: ArraySlice<UInt8>) -> UInt64 {
    let bytes = Array(field)
    if let first = bytes.first, first & 0x80 != 0 {
        var v: UInt64 = UInt64(first & 0x7f)
        for b in bytes.dropFirst() { v = (v << 8) | UInt64(b) }
        return v
    }
    var v: UInt64 = 0
    for b in bytes {
        if b == 0 { break }
        if b == UInt8(ascii: " ") { continue }
        guard b >= UInt8(ascii: "0"), b <= UInt8(ascii: "7") else { break }
        v = (v << 3) | UInt64(b - UInt8(ascii: "0"))
    }
    return v
}

// =================================================================
// MARK: - Windows file identity (stat/lstat/symlink/link replacement)
// MARK: - Windows 版檔案識別（取代 stat/lstat/symlink/link）
// =================================================================
// Windows has no POSIX stat()/lstat()/S_IFLNK/symlink()/link()/chmod(), but
// no raw WinSDK calls are needed either: swift-corelibs-foundation's Windows
// port already exposes everything through portable FileManager APIs —
// attributesOfItem's .type/.systemFileNumber/.systemNumber/.referenceCount
// map to lstat's S_IFLNK/dev/ino/nlink, and createSymbolicLink(atPath:
// withDestinationPath:) already passes the modern unprivileged-creation flag
// (verified: succeeds under Developer Mode without admin, same as our old
// manual CreateSymbolicLinkW call). The one gap is hardlinks: Foundation's
// linkItem(atPath:toPath:) silently creates a *symlink* on Windows instead of
// a true hardlink (verified empirically), which would be a correctness
// regression for tar's hardlink-dedup entries — so hardlink creation shells
// out to `fsutil hardlink create` instead (no admin required, verified).
// There is no Unix permission bit to preserve — directories/files get
// conventional 0o755/0o644 on archive, and chmod is a no-op on extract.
// Windows 沒有 POSIX stat()/lstat()/S_IFLNK/symlink()/link()/chmod()，但也不
// 需要原始 WinSDK 呼叫：swift-corelibs-foundation 的 Windows 版本已經透過
// 可攜的 FileManager API 全部曝露——attributesOfItem 的
// .type/.systemFileNumber/.systemNumber/.referenceCount 對應 lstat 的
// S_IFLNK/dev/ino/nlink；createSymbolicLink(atPath:withDestinationPath:) 本身
// 已經帶了現代版「免權限建立」旗標（實測：在開發者模式下不需系統管理員權限
// 就能成功，跟舊版手動呼叫 CreateSymbolicLinkW 效果相同）。唯一的缺口是硬連
// 結：Foundation 的 linkItem(atPath:toPath:) 在 Windows 上實測會靜默建立
// symlink 而非真正的硬連結，對 tar 的硬連結去重項目來說是正確性倒退——因此
// 硬連結改為呼叫外部 `fsutil hardlink create`（不需系統管理員權限，已實測）。
// 沒有 Unix 權限位元可保留，打包時目錄/檔案一律給慣例值 0o755/0o644，解壓時
// chmod 為 no-op。
#if os(Windows)

private struct WinStat {
    var isDir: Bool
    var isSymlink: Bool
    var size: UInt64
    var mtime: UInt64
    var nlink: UInt32
    var volumeSerial: UInt64
    var fileIndex: UInt64
}

/// lstat()-equivalent via FileManager.attributesOfItem, which (verified) does
/// NOT follow the final reparse point, so a symlink reports itself (matching
/// lstat's S_IFLNK) even when it targets a directory.
/// 等同 lstat()：透過 FileManager.attributesOfItem（實測不會追隨最後一層
/// reparse point），symlink 一律回報自身（對應 lstat 的 S_IFLNK），即使目標
/// 是目錄。
private func winStat(_ path: String) -> WinStat? {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
    let type = attrs[.type] as? FileAttributeType
    let size = (attrs[.size] as? UInt64) ?? 0
    let mtime: UInt64
    if let date = attrs[.modificationDate] as? Date {
        mtime = UInt64(max(0, date.timeIntervalSince1970))
    } else {
        mtime = 0
    }
    let nlink = UInt32((attrs[.referenceCount] as? UInt64) ?? 1)
    let volumeSerial = (attrs[.systemNumber] as? UInt64) ?? 0
    let fileIndex = (attrs[.systemFileNumber] as? UInt64) ?? 0
    return WinStat(isDir: type == .typeDirectory, isSymlink: type == .typeSymbolicLink,
                   size: size, mtime: mtime, nlink: nlink,
                   volumeSerial: volumeSerial, fileIndex: fileIndex)
}

/// Best-effort symlink creation; Windows requires admin rights or Developer
/// Mode for FileManager.createSymbolicLink to succeed. On failure this only
/// warns and skips the entry, per project decision — archive extraction
/// should not hard-fail just because symlinks are unavailable in the current
/// environment.
/// 盡力嘗試建立 symlink；FileManager.createSymbolicLink 在 Windows 上需要系統
/// 管理員權限或開發者模式才會成功。失敗時僅警告並略過該項目，不中止整個
/// 解壓——避免因環境缺乏 symlink 權限而讓整個 extract 失敗。
private func winCreateSymlink(dest: String, target: String) {
    do {
        try FileManager.default.createSymbolicLink(atPath: dest, withDestinationPath: target)
    } catch {
        eprint("swift_tar: warning: failed to create symlink '\(dest)' -> '\(target)' (needs admin rights or Developer Mode), skipping / 警告：無法建立符號連結 '\(dest)' -> '\(target)'（需要系統管理員權限或開發者模式），已略過")
    }
}

/// Best-effort hardlink creation via `fsutil hardlink create` (no admin
/// required, verified); warns and skips on failure, same policy as
/// winCreateSymlink. Not FileManager.linkItem: verified to silently create a
/// symlink instead of a true hardlink on Windows, which would defeat tar's
/// hardlink-dedup semantics.
/// 透過 `fsutil hardlink create` 盡力嘗試建立硬連結（不需系統管理員權限，已
/// 實測）；失敗時警告並略過，政策同 winCreateSymlink。不用
/// FileManager.linkItem：實測在 Windows 上會靜默建立 symlink 而非真正的硬連
/// 結，會破壞 tar 硬連結去重的語意。
private func winCreateHardlink(dest: String, target: String) {
    guard let fsutil = resolveExecutable("fsutil") ?? {
        let sysPath = "\(ProcessInfo.processInfo.environment["SystemRoot"] ?? "C:\\Windows")\\System32\\fsutil.exe"
        return FileManager.default.isExecutableFile(atPath: sysPath) ? sysPath : nil
    }() else {
        eprint("swift_tar: warning: fsutil not found, cannot create hardlink '\(dest)' -> '\(target)', skipping / 警告：找不到 fsutil，無法建立硬連結 '\(dest)' -> '\(target)'，已略過")
        return
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: fsutil)
    process.arguments = ["hardlink", "create", dest, target]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else {
        eprint("swift_tar: warning: failed to launch fsutil for hardlink '\(dest)' -> '\(target)', skipping / 警告：無法啟動 fsutil 建立硬連結 '\(dest)' -> '\(target)'，已略過")
        return
    }
    process.waitUntilExit()
    if process.terminationStatus != 0 {
        eprint("swift_tar: warning: failed to create hardlink '\(dest)' -> '\(target)', skipping / 警告：無法建立硬連結 '\(dest)' -> '\(target)'，已略過")
    }
}

/// Cached process cwd for building absolute paths in the ucrt backend
/// (swift_tar never chdirs during extraction; lazy global init is
/// thread-safe).
/// 供 ucrt 後端組絕對路徑用的 cwd 快取（解壓過程不會 chdir；Swift 全域
/// lazy 初始化為執行緒安全）。
private let winProcessCwd = FileManager.default.currentDirectoryPath

/// CRT calls receive the path verbatim — unlike Foundation they do not handle
/// long paths automatically — so: normalize to backslashes, make absolute,
/// and past MAX_PATH resolve "."/".." lexically and add the \\?\ prefix
/// (which disables normalization and requires a fully resolved path).
/// CRT 呼叫拿到的路徑不做任何加工——不像 Foundation 會自動處理長路徑——因此：
/// 統一反斜線、轉絕對路徑；超過 MAX_PATH 時詞法解析 "."/".." 並加 \\?\ 前綴
/// （該前綴會停用正規化，路徑必須已完全解析）。
private func winUcrtPath(_ path: String) -> String {
    var p = path.replacingOccurrences(of: "/", with: "\\")
    let u = Array(p.utf16)
    let hasDrive = u.count >= 2 && u[1] == UInt16(UInt8(ascii: ":"))
    if !hasDrive && !p.hasPrefix("\\\\") {
        p = winProcessCwd + "\\" + p
    }
    if p.utf16.count >= 260 && !p.hasPrefix("\\\\?\\") {
        var comps: [Substring] = []
        for c in p.split(separator: "\\", omittingEmptySubsequences: false) {
            if c == "." { continue }
            if c == ".." { if comps.count > 1 { comps.removeLast() }; continue }
            comps.append(c)
        }
        p = "\\\\?\\" + comps.joined(separator: "\\")
    }
    return p
}

/// Write one extracted regular file with the selected backend; returns an
/// error message on failure, nil on success. Called from FileWriterPool
/// workers (distinct paths only, no shared state).
/// 以選定後端寫出一個解壓檔案；失敗回傳錯誤訊息，成功回傳 nil。由
/// FileWriterPool 的 worker 呼叫（路徑各自獨立，無共享狀態）。
private func winWriteFile(dest: String, data: Data, mtime: UInt64,
                          backend: WriteBackend, restoreMtime: Bool = true) -> String? {
    switch backend {
    case .foundation:
        // Single-call create+write+close (ONE open), then mtime via
        // setAttributes (second open). Current inline path costs three opens.
        // 一次呼叫完成建檔＋寫入＋關檔（單次開檔），再以 setAttributes 設
        // mtime（第二次開檔）。原 inline 路徑每檔要開三次。
        do {
            try data.write(to: URL(fileURLWithPath: dest), options: [])
        } catch {
            return "cannot write '\(dest)': \(error) / 無法寫入 '\(dest)'"
        }
        if restoreMtime {
            try? FileManager.default.setAttributes([.modificationDate:
                Date(timeIntervalSince1970: TimeInterval(mtime))], ofItemAtPath: dest)
        }
        return nil
    case .ucrt:
        // One CRT open per file; mtime set on the same fd — no extra opens.
        // (_wsopen itself is variadic and unavailable to Swift; _wsopen_s is
        // the fixed-arity form.)
        // 每檔僅一次 CRT 開檔；mtime 直接設在同一 fd 上——零額外開檔。
        // （_wsopen 本身是可變參數，Swift 無法呼叫；_wsopen_s 為固定參數版。）
        var fd: Int32 = -1
        let openErr = winUcrtPath(dest).withCString(encodedAs: UTF16.self) { w in
            _wsopen_s(&fd, w, _O_WRONLY | _O_CREAT | _O_TRUNC | _O_BINARY | _O_SEQUENTIAL,
                      _SH_DENYNO, _S_IREAD | _S_IWRITE)
        }
        guard openErr == 0, fd >= 0 else {
            return "cannot create '\(dest)' (errno \(openErr)) / 無法建立 '\(dest)'"
        }
        var writeOK = true
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var off = 0
            while off < raw.count {
                let n = _write(fd, raw.baseAddress! + off, UInt32(min(raw.count - off, 1 << 30)))
                if n <= 0 { writeOK = false; return }
                off += Int(n)
            }
        }
        if writeOK && restoreMtime {
            var tb = __utimbuf64(actime: __time64_t(mtime), modtime: __time64_t(mtime))
            _ = _futime64(fd, &tb)
        }
        _ = _close(fd)
        return writeOK ? nil : "write failed for '\(dest)' / 寫入失敗 '\(dest)'"
    }
}

#endif // os(Windows)

#if !os(Windows)
/// Write one extracted regular file on POSIX; returns an error message on
/// failure, nil on success. Called from FileWriterPool workers (distinct
/// paths only, no shared state).
///
/// ONE open per file, against three on the inline path this replaces
/// (`createFile`, then `FileHandle(forWritingAtPath:)`, then `setAttributes`).
///
/// `fchmod`/`futimens` act on the already-open descriptor rather than the
/// path. That is not only cheaper -- it is also the correct choice here,
/// because a path-based `chmod` after the fact would race with any other
/// worker that has since replaced the file at that name. The mode must be
/// applied explicitly rather than relying on `open`'s mode argument: that one
/// is masked by umask and only honoured on creation, so an archive member
/// marked 0755 would come out 0755 & ~umask, and would not be corrected at
/// all when overwriting an existing file.
///
/// 在 POSIX 上寫出一個解壓檔案；失敗回傳錯誤訊息，成功回傳 nil。由
/// FileWriterPool 的 worker 呼叫（路徑各自獨立，無共享狀態）。
/// 每檔僅一次開檔，取代原 inline 路徑的三次（createFile、FileHandle、
/// setAttributes）。fchmod/futimens 作用於已開啟的 fd 而非路徑：這不只較便宜，
/// 在此更是正確的選擇——事後以路徑 chmod 會與「其間已把同名檔案換掉」的其他
/// worker 競態。權限必須明確套用而不能依賴 open 的 mode 參數：後者受 umask
/// 遮罩且僅在建立時生效，因此標記為 0755 的成員會變成 0755 & ~umask，覆蓋既有
/// 檔案時更完全不會被修正。
private func posixWriteFile(dest: String, data: Data, mtime: UInt64, mode: UInt32,
                            restoreMtime: Bool) -> String? {
    let fd = dest.withCString { open($0, O_WRONLY | O_CREAT | O_TRUNC, mode_t(mode)) }
    guard fd >= 0 else {
        return "cannot create '\(dest)' (errno \(errno)) / 無法建立 '\(dest)'"
    }
    defer { close(fd) }

    var writeOK = true
    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        guard let base = raw.baseAddress else { return }
        var off = 0
        while off < raw.count {
            // write(2) may return a short count on a signal or a full pipe
            // buffer; looping is required, not defensive.
            // write(2) 可能因訊號或緩衝已滿而寫入不足，必須迴圈，這不是防禦性寫法。
            let n = write(fd, base + off, raw.count - off)
            if n <= 0 {
                if errno == EINTR { continue }
                writeOK = false
                return
            }
            off += n
        }
    }
    guard writeOK else { return "write failed for '\(dest)' / 寫入失敗 '\(dest)'" }

    _ = fchmod(fd, mode_t(mode))
    if restoreMtime {
        var ts = [timespec(tv_sec: time_t(mtime), tv_nsec: 0),
                  timespec(tv_sec: time_t(mtime), tv_nsec: 0)]
        _ = futimens(fd, &ts)
    }
    return nil
}
#endif // !os(Windows)

/// Extraction writer pool. The per-file cost it overlaps is fixed latency, so
/// N files in flight overlap it nearly linearly. Same idiom as
/// ParallelChunkSink: concurrent queue + group + semaphore backpressure +
/// locked first-failure. The semaphore also bounds memory: inflight ×
/// smallFileMax.
///
/// On Windows that fixed cost is ~2ms of kernel/filter-driver latency
/// (OPTIMIZATION.md R43-Win §4). On macOS/Linux it is smaller but the shape is
/// the same: extraction of many small files is syscall-bound, not CPU-bound --
/// measured at sys 1390ms against user 280ms, with CPU/wall pinned at 1.01
/// before this pool existed on POSIX. See verifications/extract_write_path.zsh.
///
/// 解壓寫入池。它重疊掉的是「每檔固定延遲」，故 N 檔並行可近乎線性重疊。與
/// ParallelChunkSink 同一 idiom：concurrent queue + group + semaphore 反壓
/// + 鎖保護 first-failure。semaphore 同時就是記憶體上限：inflight × 小檔上限。
/// Windows 上該固定成本約 2ms（kernel/filter driver 延遲）。macOS/Linux 上較小，
/// 但形狀相同：大量小檔的解壓是 syscall-bound 而非 CPU-bound——實測 sys 1390ms
/// 對 user 280ms，且在 POSIX 尚無此池之前 CPU/wall 固定為 1.01。
/// 見 verifications/extract_write_path.zsh。
final class FileWriterPool {
    static let smallFileMax = 4 << 20        // ≤4 MiB buffered / 小檔緩衝上限

    private let backend: WriteBackend
    private let restoreMtime: Bool
    private let sem: DispatchSemaphore
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "swifttar.extract", qos: .userInitiated,
                                      attributes: .concurrent)
    private let group = DispatchGroup()

    private final class State: @unchecked Sendable { var failure: String? = nil }
    private let state = State()

    init(backend: WriteBackend, inflight: Int, restoreMtime: Bool = true) {
        self.backend = backend
        self.restoreMtime = restoreMtime
        self.sem = DispatchSemaphore(value: max(2, inflight))
    }

    var failure: String? {
        lock.lock(); defer { lock.unlock() }
        return state.failure
    }

    /// `mode` is ignored on Windows, which has no POSIX permission bits.
    /// `mode` 在 Windows 上被忽略：該平台沒有 POSIX 權限位元。
    func submit(dest: String, data: Data, mtime: UInt64, mode: UInt32) {
        sem.wait()                            // backpressure / 反壓
        group.enter()
        let restoreMtime = self.restoreMtime
#if os(Windows)
        let backend = self.backend
#endif
        queue.async { [self] in
#if os(Windows)
            let err = winWriteFile(dest: dest, data: data, mtime: mtime, backend: backend,
                                   restoreMtime: restoreMtime)
#else
            let err = posixWriteFile(dest: dest, data: data, mtime: mtime, mode: mode,
                                     restoreMtime: restoreMtime)
#endif
            if let err = err {
                lock.lock()
                state.failure = state.failure ?? err
                lock.unlock()
            }
            sem.signal()
            group.leave()
        }
    }

    /// Barrier: wait until every queued write has completed.
    /// 屏障：等待所有已排入的寫入完成。
    func drain() { group.wait() }
}

/// Extraction write backend, selected by -write_foundation / -write_ucrt.
/// Only affects Windows extraction; other platforms keep the POSIX path.
/// 解壓寫檔後端，由 -write_foundation / -write_ucrt 選擇。僅影響 Windows
/// 解壓；其他平台維持 POSIX 路徑。
enum WriteBackend {
    case foundation   // Data.write + setAttributes（每檔 2 次開檔 / 2 opens per file）
    case ucrt         // _wsopen_s + _write + _futime64 + _close（每檔 1 次開檔 / 1 open per file）
}

// =================================================================
// MARK: - Tar writer (ustar + pax) / Tar 寫入端（ustar + pax）
// =================================================================

final class TarWriter {
    private let sink: ParallelChunkSink
    private let verbose: Bool
    /// Hardlink tracking: (dev, ino) → archived name, for st_nlink > 1 files.
    /// 硬連結追蹤：(dev, ino) → 已入檔名稱，用於 st_nlink > 1 的檔案。
    private var seenInodes: [String: String] = [:]
    /// Update (-u) baseline: archived name → mtime. When set, a non-directory
    /// entry whose mtime is not newer than the archived copy is skipped
    /// (GNU tar --update semantics). nil for plain append (-r) / create (-c).
    /// 更新（-u）基準：檔內名稱 → mtime。設定後，mtime 未比封存副本新的非目錄
    /// 項目會被略過（GNU tar --update 語意）。純追加（-r）／建立（-c）為 nil。
    private let updateBaseline: [String: UInt64]?

    init(sink: ParallelChunkSink, verbose: Bool, updateBaseline: [String: UInt64]? = nil) {
        self.sink = sink
        self.verbose = verbose
        self.updateBaseline = updateBaseline
    }

    /// -u gate: true ⟺ an archived copy exists and is at least as new, so this
    /// entry should be skipped. Directories are never gated (we still descend).
    /// -u 閘門：true ⟺ 已有同名且不比其舊的封存副本，故此項目應略過。目錄不受
    /// 閘門限制（仍需向下遞迴尋找較新的子檔）。
    private func skipForUpdate(_ name: String, _ mtime: UInt64) -> Bool {
        guard let base = updateBaseline, let old = base[name] else { return false }
        return mtime <= old
    }

    // ---- pax helpers / pax 輔助 ----

    /// "len key=value\n" where len counts the whole record including itself.
    /// pax 記錄格式 "len key=value\n"，len 含記錄全長（包括 len 自身位數）。
    private static func paxRecord(_ key: String, _ value: String) -> Data {
        let body = " \(key)=\(value)\n"
        var len = body.utf8.count + 1
        while true {
            let total = String(len).utf8.count + body.utf8.count
            if total == len { break }
            len = total
        }
        return Data((String(len) + body).utf8)
    }

    /// Emit a pax 'x' extended header block + its data blocks.
    /// 送出 pax 'x' 擴充標頭區塊與其資料區塊。
    private func writePaxHeader(records: Data, mtime: UInt64) throws {
        let paxName = "PaxHeaders.0/swift_tar"
        let hdr = buildHeader(name: paxName, prefix: "", mode: 0o644, uid: 0, gid: 0,
                              size: UInt64(records.count), mtime: mtime,
                              typeflag: UInt8(ascii: "x"), linkname: "")
        try sink.write(Data(hdr))
        try writePadded(records)
    }

    private func writePadded(_ data: Data) throws {
        try sink.write(data)
        let rem = data.count % TAR_BLOCK
        if rem != 0 {
            try sink.write(Data(count: TAR_BLOCK - rem))
        }
    }

    // ---- ustar header assembly / ustar 標頭組裝 ----

    private func buildHeader(name: String, prefix: String, mode: UInt32,
                             uid: UInt32, gid: UInt32, size: UInt64, mtime: UInt64,
                             typeflag: UInt8, linkname: String) -> [UInt8] {
        var h = [UInt8](repeating: 0, count: TAR_BLOCK)
        func put(_ s: String, at off: Int, max len: Int) {
            let b = Array(s.utf8.prefix(len))
            h.replaceSubrange(off..<off + b.count, with: b)
        }
        func putNum(_ v: UInt64, at off: Int, width: Int) {
            h.replaceSubrange(off..<off + width, with: octalField(v, width: width))
        }
        put(name, at: 0, max: 100)
        putNum(UInt64(mode & 0o7777), at: 100, width: 8)
        putNum(UInt64(uid), at: 108, width: 8)
        putNum(UInt64(gid), at: 116, width: 8)
        putNum(size, at: 124, width: 12)
        putNum(mtime, at: 136, width: 12)
        // chksum computed with the field as spaces / 校驗和先以空白計算
        for i in 148..<156 { h[i] = UInt8(ascii: " ") }
        h[156] = typeflag
        put(linkname, at: 157, max: 100)
        put("ustar", at: 257, max: 6)      // magic "ustar\0" (last byte already 0)
        h[263] = UInt8(ascii: "0"); h[264] = UInt8(ascii: "0")  // version "00"
        putNum(0, at: 329, width: 8)       // devmajor
        putNum(0, at: 337, width: 8)       // devminor
        put(prefix, at: 345, max: 155)
        let sum = h.reduce(0) { $0 + UInt64($1) }
        var chk = octalField(sum, width: 7)  // "%06o\0"
        chk.append(UInt8(ascii: " "))        // POSIX: NUL then space / NUL 後接空白
        h.replaceSubrange(148..<156, with: chk)
        return h
    }

    /// Split a long path at a "/" into (prefix ≤155, name ≤100) if possible.
    /// 嘗試在 "/" 處把長路徑拆為（prefix ≤155，name ≤100）。
    private static func splitUstarPath(_ path: String) -> (prefix: String, name: String)? {
        let bytes = Array(path.utf8)
        if bytes.count <= 100 { return ("", path) }
        var idx = bytes.count - 101          // earliest slash giving name ≤ 100
        if idx < 0 { idx = 0 }
        for i in idx..<bytes.count where bytes[i] == UInt8(ascii: "/") {
            let p = i, n = bytes.count - i - 1
            if p <= 155 && n <= 100 && n > 0 {
                return (String(decoding: bytes[0..<p], as: UTF8.self),
                        String(decoding: bytes[(p + 1)...], as: UTF8.self))
            }
        }
        return nil
    }

    /// Emit one entry header (+ pax header first if needed).
    /// 送出一筆項目標頭（必要時先送 pax 擴充標頭）。
    private func writeEntryHeader(name: String, mode: UInt32, uid: UInt32, gid: UInt32,
                                  size: UInt64, mtime: UInt64,
                                  typeflag: UInt8, linkname: String) throws {
        var pax = Data()
        var hdrName = name
        var hdrPrefix = ""
        if let split = TarWriter.splitUstarPath(name) {
            hdrPrefix = split.prefix
            hdrName = split.name
        } else {
            pax.append(TarWriter.paxRecord("path", name))
            hdrName = String(decoding: Array(name.utf8.prefix(100)), as: UTF8.self)
        }
        var hdrLink = linkname
        if linkname.utf8.count > 100 {
            pax.append(TarWriter.paxRecord("linkpath", linkname))
            hdrLink = String(decoding: Array(linkname.utf8.prefix(100)), as: UTF8.self)
        }
        var hdrSize = size
        if size >= (1 << 33) {                       // 8 GiB octal-field ceiling / 八進位欄位上限
            pax.append(TarWriter.paxRecord("size", String(size)))
            hdrSize = 0
        }
        if !pax.isEmpty {
            try writePaxHeader(records: pax, mtime: mtime)
        }
        let hdr = buildHeader(name: hdrName, prefix: hdrPrefix, mode: mode,
                              uid: uid, gid: gid, size: hdrSize, mtime: mtime,
                              typeflag: typeflag, linkname: hdrLink)
        try sink.write(Data(hdr))
    }

    // ---- entry walkers / 項目走訪 ----

    /// Archive-internal name: normalize "\" to "/", strip a Windows drive
    /// letter (e.g. "C:"), then strip leading "/" and "./" -- keeps entries
    /// portable POSIX-relative paths regardless of platform, matching
    /// bsdtar's own behavior when given an absolute Windows path.
    /// 檔內名稱：把 "\" 正規化成 "/"、去除 Windows 磁碟機代號（例如 "C:"），
    /// 再去除開頭的 "/" 與 "./"——不論平台，項目一律維持可攜的 POSIX 相對
    /// 路徑，與 bsdtar 收到 Windows 絕對路徑時的行為一致。
    private static func archiveName(_ path: String) -> String {
        var p = path.replacingOccurrences(of: "\\", with: "/")
        if p.count >= 2, p[p.startIndex].isLetter, p[p.index(after: p.startIndex)] == ":" {
            p.removeFirst(2)
        }
        while p.hasPrefix("/") { p.removeFirst() }
        while p.hasPrefix("./") && p.count > 2 { p.removeFirst(2) }
        return p
    }

    func add(path: String) throws {
        let name = TarWriter.archiveName(path)
#if os(Windows)
        guard let st = winStat(path) else {
            throw TarError.io("cannot stat '\(path)' / 無法讀取 '\(path)' 的檔案資訊")
        }
        // No Unix permission bits on Windows; use conventional defaults.
        // Windows 沒有 Unix 權限位元，使用慣例預設值。
        let mode: UInt32 = st.isDir ? 0o755 : 0o644
        let uid: UInt32 = 0, gid: UInt32 = 0
        let mtime = st.mtime

        // -u: skip non-directory entries that are not newer than the archived
        // copy. / -u：略過不比封存副本新的非目錄項目。
        if !st.isDir && skipForUpdate(name, mtime) { return }

        if st.isSymlink {
            if verbose { eprint("a \(name)") }
            let dest = (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) ?? ""
            try writeEntryHeader(name: name, mode: mode, uid: uid, gid: gid,
                                 size: 0, mtime: mtime, typeflag: UInt8(ascii: "2"), linkname: dest)
            return
        }
        if st.isDir {
            if verbose { eprint("a \(name)/") }
            try writeEntryHeader(name: name + "/", mode: mode, uid: uid, gid: gid,
                                 size: 0, mtime: mtime, typeflag: UInt8(ascii: "5"), linkname: "")
            let children = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
            for child in children.sorted() {
                try add(path: path + "/" + child)
            }
            return
        }
        // Regular file. Hardlink dedup, same behavior as bsdtar (volume serial
        // + file index stand in for dev/ino).
        // 一般檔案。硬連結去重，行為同 bsdtar（volume serial + file index 取代 dev/ino）。
        let key = "\(st.volumeSerial)/\(st.fileIndex)"
        if st.nlink > 1, let first = seenInodes[key] {
            if verbose { eprint("a \(name) link to \(first)") }
            try writeEntryHeader(name: name, mode: mode, uid: uid, gid: gid,
                                 size: 0, mtime: mtime, typeflag: UInt8(ascii: "1"),
                                 linkname: first)
            return
        }
        if st.nlink > 1 { seenInodes[key] = name }
        if verbose { eprint("a \(name)") }
        let size = st.size
        try writeEntryHeader(name: name, mode: mode, uid: uid, gid: gid,
                             size: size, mtime: mtime, typeflag: UInt8(ascii: "0"), linkname: "")
        guard let fh = FileHandle(forReadingAtPath: path) else {
            throw TarError.io("cannot open '\(path)' / 無法開啟 '\(path)'")
        }
        defer { try? fh.close() }
        var remaining = size
        while remaining > 0 {
            // autoreleasepool: FileHandle.read returns autoreleased buffers;
            // without draining per chunk, RSS grows to ~corpus size.
            // autoreleasepool：FileHandle.read 回傳 autoreleased 緩衝區；
            // 不逐塊排空的話 RSS 會膨脹到接近整個語料大小。
            try autoreleasepool {
                let want = Int(min(remaining, UInt64(TAR_CHUNK_SIZE)))
                guard let part = try fh.read(upToCount: want), !part.isEmpty else {
                    throw TarError.io("short read on '\(path)' / 讀取 '\(path)' 時提前結束")
                }
                try sink.write(part)
                remaining -= UInt64(part.count)
            }
        }
        let rem = Int(size % UInt64(TAR_BLOCK))
        if rem != 0 { try sink.write(Data(count: TAR_BLOCK - rem)) }
#else
        var st = stat()
        guard lstat(path, &st) == 0 else {
            throw TarError.io("cannot stat '\(path)' / 無法讀取 '\(path)' 的檔案資訊")
        }
        let mode = UInt32(st.st_mode & 0o7777)
        let uid = UInt32(st.st_uid), gid = UInt32(st.st_gid)
        // st_mtimespec is the Darwin spelling; POSIX/Linux uses st_mtim.
        // Both are struct timespec, so only the member name differs.
        // st_mtimespec 為 Darwin 的欄位名，POSIX/Linux 使用 st_mtim；
        // 兩者型別同為 struct timespec，僅名稱不同。
        #if os(Linux)
        let mtime = UInt64(max(0, st.st_mtim.tv_sec))
        #else
        let mtime = UInt64(max(0, st.st_mtimespec.tv_sec))
        #endif

        // -u: skip non-directory entries that are not newer than the archived
        // copy. / -u：略過不比封存副本新的非目錄項目。
        if (st.st_mode & S_IFMT) != S_IFDIR && skipForUpdate(name, mtime) { return }

        switch st.st_mode & S_IFMT {
        case S_IFDIR:
            if verbose { eprint("a \(name)/") }
            try writeEntryHeader(name: name + "/", mode: mode, uid: uid, gid: gid,
                                 size: 0, mtime: mtime, typeflag: UInt8(ascii: "5"), linkname: "")
            let children = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
            for child in children.sorted() {
                try add(path: path + "/" + child)
            }
        case S_IFLNK:
            if verbose { eprint("a \(name)") }
            let dest = (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) ?? ""
            try writeEntryHeader(name: name, mode: mode, uid: uid, gid: gid,
                                 size: 0, mtime: mtime, typeflag: UInt8(ascii: "2"), linkname: dest)
        case S_IFREG:
            // Hardlink dedup, same behavior as bsdtar / 硬連結去重，行為同 bsdtar
            let key = "\(st.st_dev)/\(st.st_ino)"
            if st.st_nlink > 1, let first = seenInodes[key] {
                if verbose { eprint("a \(name) link to \(first)") }
                try writeEntryHeader(name: name, mode: mode, uid: uid, gid: gid,
                                     size: 0, mtime: mtime, typeflag: UInt8(ascii: "1"),
                                     linkname: first)
                return
            }
            if st.st_nlink > 1 { seenInodes[key] = name }
            if verbose { eprint("a \(name)") }
            let size = UInt64(st.st_size)
            try writeEntryHeader(name: name, mode: mode, uid: uid, gid: gid,
                                 size: size, mtime: mtime, typeflag: UInt8(ascii: "0"), linkname: "")
            guard let fh = FileHandle(forReadingAtPath: path) else {
                throw TarError.io("cannot open '\(path)' / 無法開啟 '\(path)'")
            }
            defer { try? fh.close() }
            var remaining = size
            while remaining > 0 {
                // autoreleasepool: FileHandle.read returns autoreleased buffers;
                // without draining per chunk, RSS grows to ~corpus size.
                // autoreleasepool：FileHandle.read 回傳 autoreleased 緩衝區；
                // 不逐塊排空的話 RSS 會膨脹到接近整個語料大小。
                try autoreleasepool {
                    let want = Int(min(remaining, UInt64(TAR_CHUNK_SIZE)))
                    guard let part = try fh.read(upToCount: want), !part.isEmpty else {
                        throw TarError.io("short read on '\(path)' / 讀取 '\(path)' 時提前結束")
                    }
                    try sink.write(part)
                    remaining -= UInt64(part.count)
                }
            }
            let rem = Int(size % UInt64(TAR_BLOCK))
            if rem != 0 { try sink.write(Data(count: TAR_BLOCK - rem)) }
        default:
            eprint("swift_tar: skipping special file '\(path)' / 略過特殊檔案 '\(path)'")
        }
#endif
    }

    /// Two zero blocks terminate the archive, then flush the sink.
    /// 兩個全零區塊作為結尾，再沖出壓縮匯出端。
    func finish() throws {
        try sink.write(Data(count: TAR_BLOCK * 2))
        try sink.finish()
    }
}

// =================================================================
// MARK: - Tar reader (list / extract) / Tar 讀取端（列出／解出）
// =================================================================

final class TarReader {
    private let input: FileHandle
    private var pending = Data()
    // Consumed bytes at the front of `pending`. The old removeFirst pattern
    // kept extending one backing store to the size of the whole tar stream
    // (removeFirst retains storage); an explicit offset + subdata compaction
    // keeps the backing bounded.
    // `pending` 前端已消耗的位元組數。舊的 removeFirst 模式會讓同一塊
    // backing store 延長到整條 tar stream 的大小（removeFirst 保留儲存
    // 空間）；改用明確 offset + subdata 壓實可讓 backing 保持有界。
    private var offset = 0

    init(input: FileHandle, prefix: Data = Data()) {
        self.input = input
        // Copy into a fresh zero-based Data: `prefix` may be a slice with a
        // non-zero startIndex, which would break the integer offset math.
        // 複製到全新的零基底 Data：`prefix` 可能是 startIndex 非零的
        // slice，會破壞整數 offset 的索引計算。
        self.pending = Data()
        self.pending.append(prefix)
    }

    private func readExactly(_ n: Int) -> Data? {
        while pending.count - offset < n {
            // Compact the consumed prefix before growing (subdata copies into
            // a fresh backing store, releasing the old one).
            // 追加前先壓實已消耗前綴（subdata 複製到新 backing store，釋放舊的）。
            if offset > 0 {
                pending = pending.subdata(in: offset..<pending.count)
                offset = 0
            }
            // autoreleasepool: keep pipe-read buffers from accumulating
            // across the whole archive walk.
            // autoreleasepool：避免 pipe 讀取緩衝在整個 archive 掃描期間累積。
            let got = autoreleasepool { () -> Bool in
                guard let part = try? input.read(upToCount: max(n - pending.count, 1 << 16)),
                      !part.isEmpty else { return false }
                pending.append(part)
                return true
            }
            if !got { return nil }
        }
        let out = pending.subdata(in: offset..<(offset + n))
        offset += n
        if offset == pending.count {
            pending = Data()
            offset = 0
        }
        return out
    }

    /// Reject absolute paths and ".." traversal on extract (libarchive-style hardening).
    /// 解出時拒絕絕對路徑與 ".." 逃逸（仿 libarchive 的防護）。
    private static func safeRelativePath(_ name: String) -> String? {
        var p = name
        while p.hasPrefix("/") { p.removeFirst() }
        let comps = p.split(separator: "/")
        if comps.contains("..") { return nil }
        return comps.joined(separator: "/")
    }

    private static func stripComponents(_ rel: String, count: Int) -> String? {
        guard count > 0 else { return rel }
        let comps = rel.split(separator: "/", omittingEmptySubsequences: true)
        guard comps.count > count else { return nil }
        return comps.dropFirst(count).joined(separator: "/")
    }

    struct Options {
        var extract: Bool          // false = list only / false 表僅列出
        var destDir: String        // -C target / -C 目的地
        var verbose: Bool
        // Windows extraction only: parallel writer count (-n) and write
        // backend (-write_foundation / -write_ucrt); unused elsewhere.
        // 僅 Windows 解壓使用：平行寫入數（-n）與寫檔後端；其他平台不使用。
        var inflight: Int = 1
        var writeBackend: WriteBackend = .ucrt
        var stripComponents: Int = 0
        // false (--touch) leaves extracted entries at the current time,
        // GNU tar --touch semantics. / false（--touch）時解出項目維持目前
        // 時間，語意同 GNU tar --touch。
        var restoreMtime: Bool = true
    }

    func run(options: Options) throws {
        var zeroBlocks = 0
        var paxPath: String? = nil, paxLink: String? = nil, paxSize: UInt64? = nil
        var gnuLongName: String? = nil, gnuLongLink: String? = nil
        // Deferred directory mtimes (children would bump them) / 目錄 mtime 延後套用
        var dirTimes: [(path: String, mtime: UInt64)] = []
        let fm = FileManager.default
        // Parallel small-file writer pool + dests already handed to it (for
        // ordering barriers: duplicate paths, hardlink targets).
        //
        // The pool runs on every platform. It used to be Windows-only because
        // that is where the per-file latency was first measured, but the cost
        // is syscall latency rather than anything Windows-specific, and
        // POSIX extraction was confirmed single-threaded (CPU/wall 1.01 with
        // any -n) before this changed.
        //
        // 平行小檔寫入池＋已交付路徑集合（供順序屏障用：重複路徑、硬連結目標）。
        // 此池在所有平台皆啟用。它原本僅限 Windows，是因為每檔延遲最早在該平台
        // 量到；但那個成本是 syscall 延遲而非 Windows 特有，且在此改動之前已確認
        // POSIX 解壓為單執行緒（不論 -n 為何，CPU/wall 皆為 1.01）。
        let pool: FileWriterPool? = options.extract
            ? FileWriterPool(backend: options.writeBackend, inflight: options.inflight,
                             restoreMtime: options.restoreMtime) : nil
        var submitted = Set<String>()

        func skipData(_ size: UInt64) throws {
            var remaining = Int((size + UInt64(TAR_BLOCK) - 1) / UInt64(TAR_BLOCK)) * TAR_BLOCK
            while remaining > 0 {
                let n = min(remaining, DECODE_CHUNK)
                guard readExactly(n) != nil else {
                    throw TarError.format("truncated archive / 檔案不完整")
                }
                remaining -= n
            }
        }

        while let block = readExactly(TAR_BLOCK) {
            if block.allSatisfy({ $0 == 0 }) {
                zeroBlocks += 1
                if zeroBlocks >= 2 { break }
                continue
            }
            zeroBlocks = 0
            let h = [UInt8](block)

            // checksum verify / 校驗和驗證
            var sum: UInt64 = 0
            for i in 0..<TAR_BLOCK { sum += UInt64(i >= 148 && i < 156 ? UInt8(ascii: " ") : h[i]) }
            let stored = parseTarNumber(h[148..<156])
            guard sum == stored else {
                throw TarError.format("header checksum mismatch / 標頭校驗和不符")
            }

            func str(_ range: Range<Int>) -> String {
                let slice = h[range]
                let end = slice.firstIndex(of: 0) ?? range.upperBound
                return String(decoding: slice[range.lowerBound..<end], as: UTF8.self)
            }
            var name = str(0..<100)
            let prefix = str(345..<500)
            if !prefix.isEmpty { name = prefix + "/" + name }
            let mode = UInt32(parseTarNumber(h[100..<108]))
            var size = parseTarNumber(h[124..<136])
            let mtime = parseTarNumber(h[136..<148])
            let typeflag = h[156]
            var linkname = str(157..<257)

            switch typeflag {
            case UInt8(ascii: "x"):     // pax extended header / pax 擴充標頭
                guard let data = readExactly(Int((size + 511) / 512) * 512) else {
                    throw TarError.format("truncated pax header / pax 標頭不完整")
                }
                let records = data.prefix(Int(size))
                var pos = records.startIndex
                while pos < records.endIndex {
                    guard let sp = records[pos...].firstIndex(of: UInt8(ascii: " ")),
                          let len = Int(String(decoding: records[pos..<sp], as: UTF8.self)),
                          len > 0, pos + len <= records.endIndex else { break }
                    let rec = records[sp + 1..<pos + len - 1]   // strip trailing "\n"
                    if let eq = rec.firstIndex(of: UInt8(ascii: "=")) {
                        let key = String(decoding: rec[rec.startIndex..<eq], as: UTF8.self)
                        let val = String(decoding: rec[rec.index(after: eq)...], as: UTF8.self)
                        switch key {
                        case "path":     paxPath = val
                        case "linkpath": paxLink = val
                        case "size":     paxSize = UInt64(val)
                        default:         break
                        }
                    }
                    pos += len
                }
                continue
            case UInt8(ascii: "g"):     // pax global header: skip / 全域標頭：略過
                try skipData(size)
                continue
            case UInt8(ascii: "L"):     // GNU long name / GNU 長檔名
                guard let data = readExactly(Int((size + 511) / 512) * 512) else {
                    throw TarError.format("truncated GNU longname / GNU 長檔名不完整")
                }
                gnuLongName = String(decoding: data.prefix(Int(size)), as: UTF8.self)
                    .trimmingCharacters(in: CharacterSet(["\0"]))
                continue
            case UInt8(ascii: "K"):     // GNU long linkname / GNU 長連結名
                guard let data = readExactly(Int((size + 511) / 512) * 512) else {
                    throw TarError.format("truncated GNU longlink / GNU 長連結名不完整")
                }
                gnuLongLink = String(decoding: data.prefix(Int(size)), as: UTF8.self)
                    .trimmingCharacters(in: CharacterSet(["\0"]))
                continue
            default:
                break
            }

            // apply pax / GNU overrides, then reset them / 套用 pax 與 GNU 覆寫後歸零
            if let p = paxPath { name = p }
            if let l = paxLink { linkname = l }
            if let s = paxSize { size = s }
            paxPath = nil; paxLink = nil; paxSize = nil
            if let n = gnuLongName { name = n; gnuLongName = nil }
            if let l = gnuLongLink { linkname = l; gnuLongLink = nil }

            let isDir = typeflag == UInt8(ascii: "5") || name.hasSuffix("/")
            guard options.extract else {
                print(name)
                if typeflag == UInt8(ascii: "0") || typeflag == 0 || typeflag == UInt8(ascii: "7") {
                    try skipData(size)
                }
                continue
            }

            guard let safeRel = TarReader.safeRelativePath(name), !safeRel.isEmpty else {
                eprint("swift_tar: skipping unsafe path '\(name)' / 略過不安全路徑 '\(name)'")
                if !isDir { try skipData(size) }
                continue
            }
            guard let rel = TarReader.stripComponents(safeRel, count: options.stripComponents),
                  !rel.isEmpty else {
                if !isDir { try skipData(size) }
                continue
            }
            if options.verbose {
                print("x \(rel)")
            }
            let dest = options.destDir.isEmpty ? rel : options.destDir + "/" + rel
            let parent = (dest as NSString).deletingLastPathComponent
            if !parent.isEmpty {
                try? fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
            }

            switch typeflag {
            case UInt8(ascii: "5"):
                try? fm.createDirectory(atPath: dest, withIntermediateDirectories: true)
#if !os(Windows)
                chmod(dest, mode_t(mode))
#endif
                dirTimes.append((dest, mtime))
            case UInt8(ascii: "2"):
                // A queued write to the same name must land before removeItem,
                // or the worker would recreate the file after the symlink was
                // put there. Platform-independent: the hazard is the queue, not
                // the filesystem.
                // 同名寫入若仍在佇列，須先落地才能 removeItem，否則 worker 會在
                // 符號連結建立之後又把檔案寫回去。與平台無關：危險來自佇列本身，
                // 不是檔案系統。
                if submitted.contains(dest) { pool?.drain() }
                try? fm.removeItem(atPath: dest)
#if os(Windows)
                winCreateSymlink(dest: dest, target: linkname)
#else
                if symlink(linkname, dest) != 0 {
                    throw TarError.io("symlink failed for '\(dest)' / 建立符號連結失敗")
                }
#endif
            case UInt8(ascii: "1"):
                guard let safeLink = TarReader.safeRelativePath(linkname),
                      let strippedLink = TarReader.stripComponents(safeLink, count: options.stripComponents),
                      !strippedLink.isEmpty else {
                    continue
                }
                let target = options.destDir.isEmpty ? strippedLink : options.destDir + "/" + strippedLink
                // The link target may still be queued in the pool -- barrier
                // before linking, or link(2) fails with ENOENT on a target that
                // is about to exist. Hardlinks are rare, so the drain is cheap.
                // 連結目標可能仍在寫入池佇列——建連結前先屏障，否則 link(2) 會對
                // 一個「即將存在」的目標回 ENOENT。硬連結稀少，drain 成本低。
                pool?.drain()
                try? fm.removeItem(atPath: dest)
#if os(Windows)
                winCreateHardlink(dest: dest, target: target)
#else
                if link(target, dest) != 0 {
                    throw TarError.io("hardlink failed for '\(dest)' / 建立硬連結失敗")
                }
#endif
            case UInt8(ascii: "0"), 0, UInt8(ascii: "7"):
                if isDir {   // some writers mark dirs with '0' + trailing "/" / 某些工具以 '0'+尾斜線表目錄
                    try? fm.createDirectory(atPath: dest, withIntermediateDirectories: true)
                    dirTimes.append((dest, mtime))
                    continue
                }
                // Small files go to the pool, large ones stream inline. The
                // split is not about speed alone: the pool buffers each file
                // whole, so its memory ceiling is inflight × smallFileMax and a
                // multi-gigabyte member must not go through it.
                // 小檔交給寫入池，大檔 inline 串流。這個分界不只為了速度：池會把
                // 每個檔案整份緩衝，記憶體上限為 inflight × smallFileMax，因此
                // 數 GB 的成員絕不能走它。
                var wroteViaPool = false
                if let pool = pool, size <= UInt64(FileWriterPool.smallFileMax) {
                    var data = Data()
                    if size > 0 {
                        guard let d = readExactly(Int(size)) else {
                            throw TarError.format("truncated file data / 檔案資料不完整")
                        }
                        data = d
                    }
                    if let f = pool.failure { throw TarError.io(f) }
                    if !submitted.insert(dest).inserted {
                        // Duplicate path: earlier queued write must land first
                        // so the later entry wins (tar overwrite semantics).
                        // 重複路徑：先前佇列中的寫入須先落地，後者才能覆蓋
                        // （tar 的覆蓋語意）。
                        pool.drain()
                    }
                    pool.submit(dest: dest, data: data, mtime: mtime, mode: mode)
                    wroteViaPool = true
                } else {
                    // Large file (or list mode): inline streaming. A queued
                    // write to this same name must land first, otherwise the
                    // worker overwrites what is streamed here.
                    // 大檔（或列出模式）：inline 串流。同名的佇列中寫入必須先落地，
                    // 否則 worker 會覆蓋掉此處串流出來的內容。
                    if submitted.contains(dest) { pool?.drain() }
                    _ = fm.createFile(atPath: dest, contents: nil)
                    guard let out = FileHandle(forWritingAtPath: dest) else {
                        throw TarError.io("cannot create '\(dest)' / 無法建立 '\(dest)'")
                    }
                    var remaining = size
                    while remaining > 0 {
                        // autoreleasepool: per-chunk extract writes are autoreleased.
                        // autoreleasepool：逐塊解壓寫出為 autoreleased。
                        try autoreleasepool {
                            let n = Int(min(remaining, UInt64(DECODE_CHUNK)))
                            guard let part = readExactly(n) else {
                                throw TarError.format("truncated file data / 檔案資料不完整")
                            }
                            try out.write(contentsOf: part)
                            remaining -= UInt64(n)
                        }
                    }
                    try? out.close()
#if os(Windows)
                    if options.restoreMtime {
                        try? fm.setAttributes([.modificationDate:
                            Date(timeIntervalSince1970: TimeInterval(mtime))], ofItemAtPath: dest)
                    }
#endif
                }
                let rem = Int(size % UInt64(TAR_BLOCK))
                if rem != 0 { _ = readExactly(TAR_BLOCK - rem) }
#if !os(Windows)
                // Only for the inline path. Applying these here for a pooled
                // file would be both redundant and WRONG: the write may not
                // have happened yet, and by the time it does these path-based
                // calls could be acting on a different file.
                // 僅適用於 inline 路徑。對已入池的檔案在此套用不只多餘，而且是
                // 錯的：該寫入可能尚未發生，而等它發生時，這些以路徑為準的呼叫
                // 可能已作用在另一個檔案上。
                if !wroteViaPool {
                    chmod(dest, mode_t(mode))
                    if options.restoreMtime {
                        try? fm.setAttributes([.modificationDate:
                            Date(timeIntervalSince1970: TimeInterval(mtime))], ofItemAtPath: dest)
                    }
                }
#endif
            default:
                eprint("swift_tar: skipping type '\(Character(UnicodeScalar(typeflag)))' entry '\(name)' / 略過未支援型別")
                try skipData(size)
            }
        }

        // Drain remainder so upstream decoder threads can finish cleanly.
        // 把殘餘輸入讀完，讓上游解碼執行緒能正常收尾。
        while autoreleasepool(invoking: {
            ((try? input.read(upToCount: DECODE_CHUNK))?.isEmpty == false)
        }) {}

        // All file writes must land before directory mtimes are applied
        // (each write bumps its parent directory's mtime). This drain is also
        // what surfaces a worker failure: without it, extraction could return
        // success while a write was still in flight or had already failed.
        // 所有檔案寫入須先完成，才能套用目錄 mtime（寫檔會更動父目錄 mtime）。
        // 這個 drain 同時是 worker 失敗的浮現點：少了它，解壓可能在寫入仍在途中
        // 或早已失敗的情況下回報成功。
        if let pool = pool {
            pool.drain()
            if let f = pool.failure { throw TarError.io(f) }
        }

        // Directory mtimes last, deepest first / 目錄 mtime 最後套用、先深後淺
        if options.restoreMtime {
            for (path, mtime) in dirTimes.sorted(by: { $0.path.count > $1.path.count }) {
                try? fm.setAttributes([.modificationDate:
                    Date(timeIntervalSince1970: TimeInterval(mtime))], ofItemAtPath: path)
            }
        }
    }
}

// =================================================================
// MARK: - CLI / 命令列介面
// =================================================================

private func printTarUsage() {
    // The usage is assembled from segments so the LZFSE-family lines can be
    // excluded from the string literal at COMPILE time under --no-lzfse — a
    // runtime filter would still leave "bvx3" text in the binary.
    // 說明文字以分段組裝，讓 LZFSE 家族說明行在 --no-lzfse 時於「編譯期」自字串
    // 常數排除——僅靠執行期過濾仍會把 "bvx3" 文字留在 binary 內。
    let head = """
    Usage: swift_tar -c|-x|-t|-r|-u|--delete|--identify|--cat [-f <archive>] [codec] [-C <dir>] [-n N] [-v] [files...]
           swift_tar --rgb1-pack --width <W> --height <H> --lat <deg> --lng <deg> --height-m <m> --title <text> --country <text> --creator-email <email> --right <text> --created-ms <unix_ms> -f <out.rgb1> <raw.rgb>
           swift_tar --rgb1-info -f <image.rgb1>
           swift_tar --rgb1-raw -f <image.rgb1> > image.rgb

    Commands:
      -c              : Create an archive / 建立封存檔
      -x              : Extract an archive / 解出封存檔
      -t              : List archive contents / 列出封存內容
      -r              : Append files to the end of an archive (uncompressed
                        tar only; needs a seekable -f archive)
                        將檔案追加到封存檔尾端（僅未壓縮 tar，需可定位的 -f）
      -u              : Append files that are newer than the archived copy
                        (or not yet present); uncompressed tar only
                        僅追加比封存副本新（或尚不存在）的檔案；僅未壓縮 tar
      --delete        : Remove named members from an archive in place
                        (swift_tar-only; BSD tar has no --delete); uncompressed
                        tar only, needs a seekable -f archive
                        就地從封存移除指定項目（swift_tar 獨有，BSD tar 無此
                        功能）；僅未壓縮 tar，需可定位的 -f
      --identify      : Detect the compression format by magic bytes and print
                        the filter chain (e.g. "gzip → tar"), then stop — no
                        extraction. Works on any filename; codec is auto-detected.
                        依 magic 位元組偵測壓縮格式並印出 filter 鏈（例如
                        「gzip → tar」）後即停，不解壓。任何檔名皆可，格式自動偵測。
      --cat           : Decompress filter chain only, raw payload to stdout
                        (bsdcat equivalent; use for RPM payloads etc.)
                        僅解壓 filter 鏈、原始內容輸出至 stdout（等同 bsdcat；
                        RPM payload 等非 tar 內容可用此模式取出）
      --encrypt-only  : Encrypt the -f file as-is (no tar, no codec) to stdout
                        原樣加密 -f 指定的檔案（不做 tar、不壓縮）並輸出至 stdout
      --decrypt-only  : Strip ONLY the encryption layer from -f to stdout; a
                        compressed payload stays compressed (an encrypted
                        .tar.gz comes back as .tar.gz). Use --cat instead to
                        also undo the compression.
                        僅剝除 -f 的加密層並輸出至 stdout；壓縮內容維持壓縮
                        （加密的 .tar.gz 會還原成 .tar.gz）。若連壓縮也要解開，
                        請改用 --cat。
      --rgb1-pack     : Wrap raw RGB bytes with an RGB1 header
                        將 raw RGB bytes 包成 RGB1 標頭格式
      --rgb1-info     : Print RGB1 width, height, geo, and payload size
                        輸出 RGB1 寬、高、地理資訊與 payload 大小
      --rgb1-raw      : Strip RGB1 header and write raw RGB payload to stdout
                        移除 RGB1 標頭，將 raw RGB payload 輸出至 stdout

    Codec (create only; reading auto-detects, see below):
    壓縮引擎（僅建立時指定；讀取自動偵測，見下）:
    """
#if !EXCLUDE_LZFSE
    let lzfseCodecs = "\n" + """
      --other3-fast    : LZFSE other3, multi-core (standard bvx2, Apple-decodable)
                         等同 lzfse -algo other3 / 多核心，輸出標準 bvx2
      --other3-optimal : other3 + optimal parsing (= lzfse -algo other3 -optimal3)
                         other3 + 最優解析（DP），仍是標準 bvx2
      --bvx3-fast      : Private bvx3 blocks, multi-core (= lzfse -algo bvx3)
                         私有 bvx3 區塊／多核心（僅本工具可解）
      --bvx3-optimal   : bvx3 + optimal parsing (= lzfse -algo bvx3 -optimal)
                         bvx3 + 最優解析（壓縮率最高、最慢）
    """
#else
    let lzfseCodecs = ""
#endif
    let externalCodecs = "\n" + """
      --zip            : True ZIP container via libarchive (Deflate; auto ZIP64)
                         透過 libarchive 建立真實 ZIP 容器（Deflate；需要時自動 ZIP64）
      --zip64          : True ZIP container with ZIP64 records forced
                         建立真實 ZIP 容器並強制寫入 ZIP64 記錄
      --gzip, -z       : zlib, one gzip member per 4MiB chunk (pigz-style .tar.gz)
                         每 4MiB 分塊一個 gzip 成員（pigz 式標準 .tar.gz）
      --bzip2, -j      : libbz2, one stream per chunk (pbzip2-style .tar.bz2)
                         每分塊一個 bzip2 串流（pbzip2 式標準 .tar.bz2）
      --xz, -J         : liblzma, one xz stream per chunk (xz multi-stream)
                         每分塊一個 xz 串流（標準 xz 多串流）
      --lzip           : lzip CLI, one lzip stream per chunk
                         每分塊一個 lzip 串流（需 lzip CLI）
      --zstd           : libzstd, one frame per chunk / 每分塊一個 zstd frame
      --lz4            : liblz4 standard frames / 標準 LZ4 frame
      (none)           : Plain uncompressed tar / 不壓縮的純 tar

    Read filters (auto-detected by magic, stackable like libarchive):
    讀取端 filter（依 magic 自動偵測，可如 libarchive 疊層）:
      uuencoded files (uu & base64)  / uuencode（uu 與 base64 變體）
      files with RPM wrapper         / RPM 外包裝（payload 通常為 cpio，用 --cat）
      gzip, bzip2, compress/LZW, lzma, lzip, xz, lz4, zstandard,
    """
#if !EXCLUDE_LZFSE
    let lzfseReadFilter = "\n" + "      LZFSE family (bvx2/bvx3 multi-core parallel decode)"
#else
    let lzfseReadFilter = ""
#endif
    let tail = "\n" + """
      lzop: detected, needs liblzo2 (not bundled) / lzop：可偵測，需另裝 liblzo2

    Options:
      -f <path>       : Archive file ("-" = stdin/stdout; default "-")
                        封存檔路徑（"-" 表標準輸入／輸出；預設 "-"）
                        RGB1 modes use -f as the RGB1 input/output path.
                        RGB1 模式以 -f 作為 RGB1 輸入／輸出路徑。
      -C <dir>        : Change directory before create, or extract into <dir>
                        建立封存前切換目錄，或解出至 <dir>
      --strip-components <N>
                      : (-x only) strip N leading path components from member
                        names before extraction, matching standard tar
                        （僅 -x）解出前移除成員路徑前 N 層，語意同標準 tar
      -n <N>          : In-flight parallel chunks (default 2×cores)
                        平行在途分塊數（預設 2×核心數）
      --encrypt       : (-c only) encrypt the archive with ChaCha20-Poly1305.
                        The passphrase is read from the terminal without echo;
                        reading auto-detects encryption, so no flag is needed
                        to extract. Encryption wraps the codec, so any codec
                        (or plain tar) can be encrypted.
                        （僅 -c）以 ChaCha20-Poly1305 加密封存。密語自終端機
                        讀取且不回顯；讀取時自動偵測加密，解開無須旗標。加密
                        包在 codec 之外，故任何 codec（或純 tar）皆可加密。
      --keyfile <path>: Use the file's bytes as key material instead of a
                        passphrase (works for both create and read; required
                        when stdin is not a terminal, e.g. in pipelines)
                        以檔案內容作為金鑰材料取代密語（建立與讀取皆適用；
                        stdin 非終端機時（如管線中）必須使用）
      --width <W>     : RGB1 pack width, UInt32 pixels
                        RGB1 pack 的寬度，UInt32 像素
      --height <H>    : RGB1 pack height, UInt32 pixels
                        RGB1 pack 的高度，UInt32 像素
      --lat <deg>     : RGB1 latitude in WGS84 degrees (-90...90)
                        RGB1 WGS84 緯度，單位度（-90...90）
      --lng <deg>     : RGB1 longitude in WGS84 degrees (-180...180)
                        RGB1 WGS84 經度，單位度（-180...180）
      --height-m <m>  : RGB1 WGS84 ellipsoid height, meters stored as millimeters
                        RGB1 WGS84 ellipsoid height，輸入公尺、header 儲存毫米
      --title <text>  : RGB1 ASCII title, less than 64 bytes
                        RGB1 ASCII 標題，小於 64 bytes
      --country <text>: RGB1 ASCII country, less than 512 bytes
                        RGB1 ASCII 國家，小於 512 bytes
      --creator-email <email>:
                        RGB1 creator email, ASCII, at most 254 bytes
                        RGB1 建立者 email，ASCII，最多 254 bytes
      --right <text>  : RGB1 rights code, 1 to 4 English letters
                        RGB1 權利代碼，1 到 4 個英文字母
      --created-ms <unix_ms>:
                        RGB1 created timestamp, Int64 UTC Unix milliseconds
                        RGB1 建立時間戳，Int64 UTC Unix milliseconds
      --tz-offset-min <minutes>:
                        RGB1 timezone offset minutes, Int16; default 480 (TW)
                        RGB1 時區 offset 分鐘，Int16；預設 480（台灣）
      -v              : Verbose; on read also prints the detected compression
                        format ("none" if uncompressed)
                        詳細輸出；讀取時另印出偵測到的壓縮格式（未壓縮則印 none）
      --touch         : (-x only) do not restore archive mtimes; extracted
                        entries keep the current time (GNU tar semantics)
                        （僅 -x）不還原封存的 mtime，解出項目維持目前時間
                        （GNU tar 語意）
      -h              : Show this help / 顯示說明
      --version       : Show build date version / 顯示建置日期版本
      -write_foundation / -write_ucrt :
                        (Windows -x only) extraction write backend: Foundation
                        Data.write + setAttributes, or CRT single-open
                        (_wsopen_s + _futime64). Default: ucrt.
                        （僅 Windows -x）解壓寫檔後端：Foundation 或 CRT 單次
                        開檔。預設 ucrt。
      -test           : Self test: round-trip tar, .tar.gz, ZIP and ZIP64 against the
                        platform's standard tar (create with one, extract with
                        the other, both directions), then exit
                        自我測試：與平台標準 tar 做雙向 round-trip（純 tar、
                        .tar.gz、ZIP 與 ZIP64），完成後結束
      -debug          : With -test, print which standard-tar candidates were
                        found/skipped while searching / 搭配 -test 使用，印出
                        搜尋標準 tar 過程中找到／略過的候選項目

    Notes / 注意:
      - Tar-filter model: 4MiB chunks compressed concurrently, written in order.
        Those codecs emit concatenatable streams, so stock tools decode them.
        tar filter 模式：4MiB 分塊併發壓縮、按序寫出；這些引擎輸出皆可串接，
        原生工具可直接解開。
      - ZIP/ZIP64 container handling uses the bundled libarchive backend.
        Other C libraries provide tar-filter compression primitives; framing
        is assembled here. compress/LZW, uu and RPM are pure-Swift ports.
        ZIP/ZIP64 容器由內附 libarchive 後端處理；其他 C 庫提供 tar filter
        壓縮原語、框架由本工具自組；LZW/uu/RPM 為純 Swift 移植。
    """
    print(head + lzfseCodecs + externalCodecs + lzfseReadFilter + tail)
}

// =================================================================
// MARK: - Self test (-test): round-trip vs. the platform's standard tar
// MARK: - 自我測試（-test）：與平台標準 tar 的 round-trip
// =================================================================
// Goal: prove swift_tar's tar and ZIP-family output is
// interchangeable with the platform's real tar (bsdtar on macOS/Windows 10+,
// GNU tar on Linux) -- not swift_tar tested against itself.
// 目標：證明 swift_tar 的 tar 與 ZIP 家族輸出跟平台的真實 tar（macOS/
// Windows 10+ 為 bsdtar，Linux 為 GNU tar）位元組級互通——不是拿 swift_tar
// 跟自己比。

/// Search PATH for the platform's standard tar ("tar" / "tar.exe"), skipping
/// any candidate whose file size matches this running swift_tar binary --
/// guards against comparing against a PATH shim that points back at
/// swift_tar itself (e.g. run_round.bat's -swift_tar shim, which is a real
/// file copy named tar.exe, not a symlink a naive "which tar" could see
/// through).
/// 在 PATH 中搜尋平台的標準 tar（"tar" / "tar.exe"），跳過檔案大小與目前執行
/// 中的 swift_tar 本身相符的候選——防止比對到指回 swift_tar 自己的 PATH shim
/// （例如 run_round.bat 的 -swift_tar shim，是真正的檔案複本、檔名 tar.exe，
/// 不是符號連結，單純的 "which tar" 看不穿）。
func findStandardTar(debug: Bool = false) -> String? {
    // -debug prints go to stdout, not stderr: stderr writes via
    // FileHandle.standardError were observed to go missing when this binary
    // is spawned through Bash/MSYS or piped through PowerShell's `2>&1` in
    // this environment (print() to stdout was reliable in both).
    // -debug 訊息走 stdout、不走 stderr：實測發現這個環境下，透過 Bash/MSYS
    // 執行或用 PowerShell 的 `2>&1` 時，FileHandle.standardError 寫入的內容
    // 會遺失；print() 走 stdout 在兩種呼叫方式下都可靠。
    func dprint(_ msg: String) { if debug { print("[debug] \(msg)") } }

    dprint("findStandardTar: argv0=\(CommandLine.arguments[0])")
    let ownSize = (try? FileManager.default.attributesOfItem(atPath: CommandLine.arguments[0])[.size] as? Int) ?? nil
    dprint("findStandardTar: ownSize=\(String(describing: ownSize))")
#if os(Windows)
    // Windows 10 1803+ ships a genuine bsdtar at System32\tar.exe -- prefer
    // it explicitly over whatever a dev-tool PATH turns up first (e.g. Git's
    // bundled MSYS tar.exe, which has its own POSIX-path-translation
    // semantics for "/..."-style paths and isn't representative of "the
    // standard tar on Windows" for a typical user).
    // Windows 10 1803+ 內建 System32\tar.exe 是貨真價實的 bsdtar——明確優先
    // 用它，而非開發工具 PATH 上先找到的其他版本（例如 Git 內附的 MSYS
    // tar.exe，對 "/..."-style 路徑有自己的一套 POSIX 路徑轉換語意，不能代表
    // 一般使用者認知的「Windows 標準 tar」）。
    let systemRoot = ProcessInfo.processInfo.environment["SystemRoot"] ?? "C:\\Windows"
    let system32Tar = "\(systemRoot)\\System32\\tar.exe"
    dprint("findStandardTar: system32Tar=\(system32Tar) isExec=\(FileManager.default.isExecutableFile(atPath: system32Tar))")
    if FileManager.default.isExecutableFile(atPath: system32Tar) {
        let candSize = (try? FileManager.default.attributesOfItem(atPath: system32Tar)[.size] as? Int) ?? nil
        dprint("findStandardTar: candSize=\(String(describing: candSize)) ownSize=\(String(describing: ownSize))")
        if !(ownSize != nil && candSize == ownSize) {
            dprint("findStandardTar: returning system32Tar")
            return system32Tar
        }
        dprint("findStandardTar: NOT returning system32Tar (size matched own)")
    }
#endif
    dprint("findStandardTar: fell through to PATH search")
    let env = ProcessInfo.processInfo.environment
    let pathVar = env["Path"] ?? env["PATH"] ?? env["path"] ?? ""
    let sep: Character = pathVar.contains(";") ? ";" : ":"
    for dir in pathVar.split(separator: sep) {
        for name in ["tar.exe", "tar"] {
            let candidate = "\(dir)/\(name)"
            guard FileManager.default.isExecutableFile(atPath: candidate) else { continue }
            let candSize = (try? FileManager.default.attributesOfItem(atPath: candidate)[.size] as? Int) ?? nil
            dprint("findStandardTar: candidate=\(candidate) size=\(String(describing: candSize))")
            if let ownSize, let candSize, candSize == ownSize { continue }   // looks like a copy of ourselves
            return candidate
        }
    }
    return nil
}

/// Recursively compare two directory trees for identical relative paths and
/// file contents (symlinks compared by target, not followed).
/// 遞迴比較兩個目錄樹的相對路徑與檔案內容是否一致（symlink 比對目標本身，不
/// 追隨）。
func compareTrees(_ a: String, _ b: String) -> Bool {
    let fm = FileManager.default
    guard let aItems = try? fm.subpathsOfDirectory(atPath: a) else { return false }
    guard let bItems = try? fm.subpathsOfDirectory(atPath: b) else { return false }
    guard Set(aItems) == Set(bItems) else { return false }
    for rel in aItems {
        let pa = "\(a)/\(rel)", pb = "\(b)/\(rel)"
        let ta = (try? fm.attributesOfItem(atPath: pa)[.type] as? FileAttributeType) ?? nil
        let tb = (try? fm.attributesOfItem(atPath: pb)[.type] as? FileAttributeType) ?? nil
        guard ta == tb else { return false }
        switch ta {
        case .typeDirectory:
            continue
        case .typeSymbolicLink:
            guard let da = try? fm.destinationOfSymbolicLink(atPath: pa),
                  let db = try? fm.destinationOfSymbolicLink(atPath: pb), da == db else { return false }
        default:
            guard let da = fm.contents(atPath: pa), let db = fm.contents(atPath: pb), da == db else { return false }
        }
    }
    return true
}

/// Run a tar binary (self or the standard tar) as a subprocess and wait for
/// exit; returns true on exit code 0. `cwd`, when given, matches "-C dir"
/// for create so both sides always archive the same relative "src/..."
/// entry names -- an absolute Windows path (with a drive letter and
/// backslashes) is not a portable tar member name, so the create side never
/// passes one.
/// 以子行程執行一個 tar 執行檔（自己或標準 tar），等待結束；exit code 0 回傳
/// true。給了 `cwd` 時等同 "-C dir"，讓兩邊建檔時都用同樣的相對路徑
/// "src/..." 當項目名稱——Windows 絕對路徑（含磁碟機代號與反斜線）不是可攜的
/// tar 項目名稱，所以建檔這一側絕不傳絕對路徑進去。
@discardableResult
func runTarProcess(_ exePath: String, _ args: [String], cwd: String? = nil) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: exePath)
    process.arguments = args
    if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
    var env = ProcessInfo.processInfo.environment
    // macOS /usr/bin/tar can emit AppleDouble "._*" metadata entries unless
    // COPYFILE_DISABLE is set, which makes self-test compare tar semantics
    // instead of platform metadata side effects.
    // macOS /usr/bin/tar 未設定 COPYFILE_DISABLE 時可能輸出 AppleDouble
    // "._*" metadata 項目；self-test 應比較 tar 語意，而非平台 metadata 副作用。
    env["COPYFILE_DISABLE"] = "1"
    process.environment = env
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return false }
    process.waitUntilExit()
    return process.terminationStatus == 0
}

func runSelfTest(debug: Bool = false) {
    // CommandLine.arguments[0] can be relative (e.g. invoked as `..\swift_tar\
    // release\swift_tar.exe`) or a bare name with no path component at all
    // (e.g. plain "tar" -- cmd.exe resolves it via PATH before exec but can
    // still hand the child just the bare name as argv[0]; reproduced via
    // run_round.bat's actual `tar -test > file 2>&1`, which is exactly how
    // the -swift_tar PATH shim gets invoked). Combined with setting
    // currentDirectoryURL on the nested Process() calls below, an
    // unqualified executable path resolves against the wrong directory (or
    // doesn't exist at all) and subprocess launch fails ("cannot find drive
    // specified" / garbled output / silent failure). Resolve to a real
    // absolute path up front: try standardizing CommandLine.arguments[0]
    // first, and if that file doesn't actually exist (the bare-name case),
    // fall back to a PATH search for the same name.
    // CommandLine.arguments[0] 可能是相對路徑（例如以 `..\swift_tar\release\
    // swift_tar.exe` 呼叫），也可能完全沒有路徑成分、只是個裸名稱（例如單純
    // "tar"——cmd.exe 執行前會用 PATH 解析，但傳給子行程的 argv[0] 仍可能只
    // 是裸名稱；已用 run_round.bat 實際的 `tar -test > file 2>&1` 重現，這正
    // 是 -swift_tar PATH shim 被呼叫的方式）。搭配下面 Process() 有設定
    // currentDirectoryURL，沒有完整路徑的執行檔會解析到錯誤目錄（或根本不存
    // 在），導致子行程啟動失敗（"cannot find drive specified" ／輸出亂碼／
    // 靜默失敗）。改成一開始就解析成真正存在的絕對路徑：先嘗試把
    // CommandLine.arguments[0] 正規化，若那個檔案其實不存在（裸名稱的情
    // 況），再退回用 PATH 搜尋同一個名稱。
    var selfExe = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
    if !FileManager.default.isExecutableFile(atPath: selfExe) {
        let bareName = (CommandLine.arguments[0] as NSString).lastPathComponent
            .replacingOccurrences(of: ".exe", with: "")
#if os(Windows)
        if let resolved = resolveExecutable(bareName) { selfExe = resolved }
#endif
    }
    var allOK = true
    func check(_ label: String, _ ok: Bool) {
        print("       \(label): \(ok ? "✓" : "✗ 失敗 / FAILED")")
        if !ok { allOK = false }
    }

    guard let stdTar = findStandardTar(debug: debug) else {
        print("[swift_tar -test] standard tar not found on PATH, skipping cross-compat round-trip / 在 PATH 中找不到標準 tar，略過互通性測試")
        exit(0)
    }
    print("[swift_tar -test] standard tar (which tar): \(stdTar)")

    let tmp = NSTemporaryDirectory() + "swift_tar_selftest_\(ProcessInfo.processInfo.processIdentifier)"
    let fm = FileManager.default
    try? fm.removeItem(atPath: tmp)
    defer { try? fm.removeItem(atPath: tmp) }

    let srcDir = "\(tmp)/src"
    try? fm.createDirectory(atPath: "\(srcDir)/sub", withIntermediateDirectories: true)
    _ = fm.createFile(atPath: "\(srcDir)/root.txt", contents: Data("swift_tar self-test root file\n".utf8))
    _ = fm.createFile(atPath: "\(srcDir)/sub/nested.txt",
                  contents: Data(String(repeating: "nested content line\n", count: 200).utf8))

    // Both create sides run with cwd=tmp and archive the relative name
    // "src", so extraction on either side always lands at "<out>/src".
    // 兩邊建檔都以 cwd=tmp、封存相對名稱 "src"，解壓後統一落在 "<out>/src"。

    // ---- plain tar ----
    let plainA = "\(tmp)/plain_by_swift_tar.tar"
    let plainB = "\(tmp)/plain_by_std_tar.tar"
    if runTarProcess(selfExe, ["-c", "-f", plainA, "-C", tmp, "src"]) {
        let out = "\(tmp)/plain_out_std"
        try? fm.createDirectory(atPath: out, withIntermediateDirectories: true)
        let extracted = runTarProcess(stdTar, ["-x", "-f", plainA, "-C", out])
        check("plain tar: swift_tar create → std tar extract", extracted && compareTrees(srcDir, "\(out)/src"))
    } else {
        check("plain tar: swift_tar create → std tar extract", false)
    }
    if runTarProcess(stdTar, ["-c", "-f", plainB, "-C", tmp, "src"]) {
        let out = "\(tmp)/plain_out_swift"
        try? fm.createDirectory(atPath: out, withIntermediateDirectories: true)
        let extracted = runTarProcess(selfExe, ["-x", "-f", plainB, "-C", out])
        check("plain tar: std tar create → swift_tar extract", extracted && compareTrees(srcDir, "\(out)/src"))
    } else {
        check("plain tar: std tar create → swift_tar extract", false)
    }

    // ---- .tar.gz ----
    let gzA = "\(tmp)/gz_by_swift_tar.tar.gz"
    let gzB = "\(tmp)/gz_by_std_tar.tar.gz"
    if runTarProcess(selfExe, ["-c", "--gzip", "-f", gzA, "-C", tmp, "src"]) {
        let out = "\(tmp)/gz_out_std"
        try? fm.createDirectory(atPath: out, withIntermediateDirectories: true)
        let extracted = runTarProcess(stdTar, ["-x", "-z", "-f", gzA, "-C", out])
        check(".tar.gz: swift_tar create → std tar extract", extracted && compareTrees(srcDir, "\(out)/src"))
    } else {
        check(".tar.gz: swift_tar create → std tar extract", false)
    }
    if runTarProcess(stdTar, ["-c", "-z", "-f", gzB, "-C", tmp, "src"]) {
        let out = "\(tmp)/gz_out_swift"
        try? fm.createDirectory(atPath: out, withIntermediateDirectories: true)
        let extracted = runTarProcess(selfExe, ["-x", "-f", gzB, "-C", out])
        check(".tar.gz: std tar create → swift_tar extract", extracted && compareTrees(srcDir, "\(out)/src"))
    } else {
        check(".tar.gz: std tar create → swift_tar extract", false)
    }

    // ---- true ZIP / ZIP64 via bundled libarchive ----
    // The platform bsdtar is the independent compatibility peer. ZIP reads do
    // not need an explicit flag because swift_tar dispatches on PK magic.
    // ---- 透過內附 libarchive 建立真實 ZIP / ZIP64 ----
    // 以平台 bsdtar 作為獨立互通對象；swift_tar 讀取時依 PK magic 自動分派，
    // 不需明確指定旗標。
    let zipA = "\(tmp)/zip_by_swift_tar.zip"
    let zipB = "\(tmp)/zip_by_std_tar.zip"
    if runTarProcess(selfExe, ["-c", "--zip", "-f", zipA, "-C", tmp, "src"]) {
        let out = "\(tmp)/zip_out_std"
        try? fm.createDirectory(atPath: out, withIntermediateDirectories: true)
        let extracted = runTarProcess(stdTar, ["-x", "-f", zipA, "-C", out])
        check("ZIP: swift_tar create → std tar extract",
              extracted && compareTrees(srcDir, "\(out)/src"))
    } else {
        check("ZIP: swift_tar create → std tar extract", false)
    }
    if runTarProcess(stdTar, ["-c", "--format", "zip", "-f", zipB, "-C", tmp, "src"]) {
        let out = "\(tmp)/zip_out_swift"
        try? fm.createDirectory(atPath: out, withIntermediateDirectories: true)
        let extracted = runTarProcess(selfExe, ["-x", "-f", zipB, "-C", out])
        check("ZIP: std tar create → swift_tar extract",
              extracted && compareTrees(srcDir, "\(out)/src"))
    } else {
        check("ZIP: std tar create → swift_tar extract", false)
    }

    let zip64 = "\(tmp)/zip64_by_swift_tar.zip"
    if runTarProcess(selfExe, ["-c", "--zip64", "-f", zip64, "-C", tmp, "src"]),
       let zip64Data = fm.contents(atPath: zip64) {
        let signature = Data([0x50, 0x4b, 0x06, 0x06])
        let hasZip64Record = zip64Data.range(of: signature) != nil
        let out = "\(tmp)/zip64_out_std"
        try? fm.createDirectory(atPath: out, withIntermediateDirectories: true)
        let extracted = runTarProcess(stdTar, ["-x", "-f", zip64, "-C", out])
        check("ZIP64: record + std tar extract",
              hasZip64Record && extracted && compareTrees(srcDir, "\(out)/src"))
    } else {
        check("ZIP64: record + std tar extract", false)
    }

    // ---- create-side -C plus native ZSTD ----
    // Use a relative archive path from a separate invocation directory. This
    // verifies that -f remains relative to the caller while leaf inputs are
    // resolved after -C, and that archive entries contain no parent or '..'.
    // ---- 建立端 -C 與原生 ZSTD ----
    // 從另一個呼叫目錄使用相對封存路徑，驗證 -f 仍相對於呼叫端，而 leaf
    // 輸入在 -C 後解析，且封存項目不含 parent 或 '..'。
    let invokeDir = "\(tmp)/invoke"
    try? fm.createDirectory(atPath: invokeDir, withIntermediateDirectories: true)
    let zstdC = "\(invokeDir)/zstd_create_c.tar.zst"
    if runTarProcess(selfExe, ["-c", "--zstd", "-f", "zstd_create_c.tar.zst",
                               "-C", tmp, "src"], cwd: invokeDir) {
        let out = "\(tmp)/zstd_create_c_out"
        try? fm.createDirectory(atPath: out, withIntermediateDirectories: true)
        let extracted = runTarProcess(selfExe, ["-x", "-f", zstdC, "-C", out])
        check("create-side -C: native ZSTD round-trip",
              fm.fileExists(atPath: zstdC) && extracted && compareTrees(srcDir, "\(out)/src"))
    } else {
        check("create-side -C: native ZSTD round-trip", false)
    }

#if os(Windows)
    // ---- extraction write backends: -write_foundation vs -write_ucrt ----
    // Correctness on both backends plus a timing comparison on a many-small-
    // files tree, to guide the choice of the default backend.
    // 兩種解壓寫檔後端的正確性驗證＋多小檔樹計時對比，供選定預設後端參考。
    let manySrc = "\(tmp)/many/src"
    for i in 0..<40 {
        try? fm.createDirectory(atPath: "\(manySrc)/d\(i)", withIntermediateDirectories: true)
        for j in 0..<10 {
            _ = fm.createFile(atPath: "\(manySrc)/d\(i)/f\(j).txt",
                              contents: Data("backend test payload \(i)/\(j)\n".utf8))
        }
    }
    let manyTar = "\(tmp)/many.tar"
    if runTarProcess(selfExe, ["-c", "-f", manyTar, "src"], cwd: "\(tmp)/many") {
        var elapsed: [String: Double] = [:]
        for backend in ["-write_foundation", "-write_ucrt"] {
            let out = "\(tmp)/many_out_\(backend.dropFirst())"
            try? fm.createDirectory(atPath: out, withIntermediateDirectories: true)
            let t0 = Date()
            let ok = runTarProcess(selfExe, ["-x", backend, "-f", manyTar, "-C", out])
            elapsed[backend] = Date().timeIntervalSince(t0)
            check("write backend \(backend): extract → compare", ok && compareTrees(manySrc, "\(out)/src"))
        }
        if let tf = elapsed["-write_foundation"], let tu = elapsed["-write_ucrt"] {
            print(String(format: "       timing, 400 small files / 計時（400 小檔）: foundation %.2fs / ucrt %.2fs", tf, tu))
        }
    } else {
        check("write backend comparison: create archive", false)
    }
#endif

    exit(allOK ? 0 : 1)
}

@main
struct SwiftTarMain {
    static func main() {
#if !os(Windows)
        signal(SIGPIPE, SIG_IGN)   // no SIGPIPE on Windows / Windows 無 SIGPIPE
#endif
        // -test 要在 combined short flag 展開之前攔截：展開邏輯會把它拆成
        // -t -e -s -t（長度 5、以 "-" 開頭、非 "--"）。
        // -test must be caught before combined-short-flag expansion below,
        // which would otherwise split it into -t -e -s -t (length 5, starts
        // with "-", not "--").
        if CommandLine.arguments.contains("-test") {
            runSelfTest(debug: CommandLine.arguments.contains("-debug"))
        }
        if CommandLine.arguments.contains("--version") {
            print("swift_tar \(swiftTarBuildVersion)")
            exit(0)
        }
        // Hand-rolled crypto must be checkable against the specs' own vectors.
        // 自行實作的密碼學必須能對規範自帶向量驗證。
        if CommandLine.arguments.contains("--crypto-selftest") {
            exit(cryptoSelfTest() ? 0 : 1)
        }
        // 展開 combined short flags，相容標準 tar 用法的兩種形式：
        //   帶 dash：-czf → -c -z -f
        //   傳統形式（第一個位置參數全是字母，無 dash）：czf → -c -z -f
        // Expand combined short flags for standard tar compatibility:
        //   dash form: -czf → -c -z -f
        //   traditional POSIX form (first operand, all letters, no dash): czf → -c -z -f
        let args: [String] = {
            var out: [String] = [CommandLine.arguments[0]]
            for (idx, a) in CommandLine.arguments.dropFirst().enumerated() {
                // Long single-dash flags with "_" (-write_ucrt, -write_foundation)
                // must not be split into single letters.
                // 含底線的單槓長旗標（-write_ucrt、-write_foundation）不可拆成單字母。
                if a.hasPrefix("-") && !a.hasPrefix("--") && a.count > 2 && !a.contains("_") {
                    for ch in a.dropFirst() { out.append("-\(ch)") }
                } else if idx == 0 && !a.hasPrefix("-") && a.count > 1 && a.allSatisfy({ $0.isLetter }) {
                    for ch in a { out.append("-\(ch)") }
                } else {
                    out.append(a)
                }
            }
            return out
        }()
        if args.contains("-h") || args.count < 2 {
            printTarUsage()
            exit(args.count < 2 ? 1 : 0)
        }

        // RGB1 raw-image container modes (self-contained, see rgb1.swift). Handled
        // before the tar mode guard because they use neither -c/-x/-t nor a codec.
        // RGB1 原始影像容器模式（自足，見 rgb1.swift）。在 tar 模式守衛前處理，
        // 因為它們不使用 -c/-x/-t 也不使用 codec。
        let rgb1Pack = args.contains("--rgb1-pack")
        let rgb1Info = args.contains("--rgb1-info")
        let rgb1Raw = args.contains("--rgb1-raw")
        if [rgb1Pack, rgb1Info, rgb1Raw].filter({ $0 }).count > 0 {
            guard [rgb1Pack, rgb1Info, rgb1Raw].filter({ $0 }).count == 1 else {
                eprint("Error: specify exactly one RGB1 command. / 錯誤：RGB1 命令只能指定一個。")
                exit(1)
            }
            do {
                let rgb1Path = optValue("-f") ?? "-"
                if rgb1Pack {
                    guard let widthRaw = optValue("--width"),
                          let width = UInt32(widthRaw),
                          let heightRaw = optValue("--height"),
                          let height = UInt32(heightRaw),
                          let latitudeRaw = optValue("--lat"),
                          let latitude = Double(latitudeRaw),
                          let longitudeRaw = optValue("--lng"),
                          let longitude = Double(longitudeRaw),
                          let heightMetersRaw = optValue("--height-m"),
                          let heightMeters = Double(heightMetersRaw),
                          let title = optValue("--title"),
                          let country = optValue("--country"),
                          let creatorEmail = optValue("--creator-email"),
                          let right = optValue("--right"),
                          let createdRaw = optValue("--created-ms"),
                          let createdUnixMilliseconds = Int64(createdRaw)
                    else {
                        throw RGB1Error.missingArgument("--width/--height/--lat/--lng/--height-m/--title/--country/--creator-email/--right/--created-ms")
                    }
                    let timezoneOffsetMinutes: Int16
                    if let timezoneRaw = optValue("--tz-offset-min") {
                        guard let parsed = Int16(timezoneRaw) else {
                            throw RGB1Error.badText("tz_offset_min")
                        }
                        timezoneOffsetMinutes = parsed
                    } else {
                        timezoneOffsetMinutes = RGB1Image.taiwanTimezoneOffsetMinutes
                    }

                    let inputPath = args.last { candidate in
                        !candidate.hasPrefix("-")
                        && candidate != args[0]
                        && candidate != rgb1Path
                        && candidate != widthRaw
                        && candidate != heightRaw
                        && candidate != latitudeRaw
                        && candidate != longitudeRaw
                        && candidate != heightMetersRaw
                        && candidate != title
                        && candidate != country
                        && candidate != creatorEmail
                        && candidate != right
                        && candidate != createdRaw
                        && candidate != optValue("--tz-offset-min")
                    } ?? "-"
                    try runRGB1Pack(
                        inputPath: inputPath,
                        outputPath: rgb1Path,
                        width: width,
                        height: height,
                        latitude: latitude,
                        longitude: longitude,
                        heightMeters: heightMeters,
                        title: title,
                        country: country,
                        creatorEmail: creatorEmail,
                        right: right,
                        createdUnixMilliseconds: createdUnixMilliseconds,
                        timezoneOffsetMinutes: timezoneOffsetMinutes
                    )
                } else if rgb1Info {
                    if rgb1Path == "-" { throw RGB1Error.missingArgument("-f <image.rgb1>") }
                    try runRGB1Info(inputPath: rgb1Path)
                } else {
                    if rgb1Path == "-" { throw RGB1Error.missingArgument("-f <image.rgb1>") }
                    try runRGB1Raw(inputPath: rgb1Path)
                }
                exit(0)
            } catch {
                eprint("swift_tar RGB1 error: \(error.localizedDescription)")
                exit(1)
            }
        }

        let doCreate = args.contains("-c")
        let doExtract = args.contains("-x")
        let doList = args.contains("-t")
        let doCat = args.contains("--cat")
        let doAppend = args.contains("-r")
        let doUpdate = args.contains("-u")
        let doDelete = args.contains("--delete")
        let doIdentify = args.contains("--identify")
        // Raw crypto filters: -f is the input and the result goes to stdout,
        // the same shape as --cat. They touch only the encryption layer, so a
        // compressed payload stays compressed.
        // 純加解密 filter：-f 為輸入、結果寫到 stdout，形狀與 --cat 相同。兩者只
        // 處理加密層，壓縮過的內容仍維持壓縮。
        let doEncryptOnly = args.contains("--encrypt-only")
        let doDecryptOnly = args.contains("--decrypt-only")
        guard [doCreate, doExtract, doList, doCat, doAppend, doUpdate, doDelete, doIdentify,
               doEncryptOnly, doDecryptOnly].filter({ $0 }).count == 1 else {
            eprint("Error: specify exactly one of -c, -x, -t, --cat, -r, -u, --delete, --identify, --encrypt-only, --decrypt-only. / 錯誤：請指定 -c、-x、-t、--cat、-r、-u、--delete、--identify、--encrypt-only、--decrypt-only 其中之一。")
            exit(1)
        }

        // codec flags / 壓縮引擎旗標
        var codec: TarCodec = .none
        var codecCount = 0
#if !EXCLUDE_LZFSE
        if args.contains("--other3-fast")    { codec = .other3(optimal: false); codecCount += 1 }
        if args.contains("--other3-optimal") { codec = .other3(optimal: true);  codecCount += 1 }
        if args.contains("--bvx3-fast")      { codec = .bvx3(optimal: false);   codecCount += 1 }
        if args.contains("--bvx3-optimal")   { codec = .bvx3(optimal: true);    codecCount += 1 }
#endif
        if args.contains("--gzip") || args.contains("-z")  { codec = .gzip;  codecCount += 1 }
        if args.contains("--bzip2") || args.contains("-j") { codec = .bzip2; codecCount += 1 }
        if args.contains("--xz") || args.contains("-J")    { codec = .xz;    codecCount += 1 }
        if args.contains("--lzip")           { codec = .lzip;                  codecCount += 1 }
        if args.contains("--zstd")           { codec = .zstd;                  codecCount += 1 }
        if args.contains("--lz4")            { codec = .lz4;                   codecCount += 1 }
        let explicitZip = args.contains("--zip")
        let forceZip64 = args.contains("--zip64")
        let zipFlagCount = (explicitZip ? 1 : 0) + (forceZip64 ? 1 : 0)
        guard codecCount + zipFlagCount <= 1 else {
            eprint("Error: at most one codec flag. / 錯誤：壓縮引擎旗標至多一個。")
            exit(1)
        }
        if codecCount + zipFlagCount > 0 && (doAppend || doUpdate || doDelete) {
            eprint("Error: -r/-u work on uncompressed tar only; drop the codec flag. / 錯誤：-r/-u 僅支援未壓縮 tar，請移除引擎旗標。")
            exit(1)
        }
        if codecCount > 0 && !doCreate && !doAppend && !doUpdate {
            eprint("Note: codec flags only affect -c; reading auto-detects. / 提示：引擎旗標僅影響 -c，讀取自動偵測。")
        }
        if forceZip64 && !doCreate {
            eprint("Error: --zip64 is a create-only option. / 錯誤：--zip64 僅能用於建立封存。")
            exit(1)
        }

        let verbose = args.contains("-v")

        func optValue(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        func optValueLong(_ flag: String) -> String? {
            if let exact = optValue(flag) { return exact }
            let prefix = flag + "="
            return args.first(where: { $0.hasPrefix(prefix) }).map { String($0.dropFirst(prefix.count)) }
        }
        let archivePath = optValue("-f") ?? "-"
        let destDir = optValue("-C") ?? ""

        // ---- encryption wiring / 加密接線 ----
        // --encrypt turns on encryption for -c; --keyfile supplies key material
        // for either direction. Reading auto-detects the magic and asks for a
        // passphrase only when no --keyfile was given.
        // --encrypt 讓 -c 加密；--keyfile 於讀寫兩端提供金鑰材料。讀取時自動偵測
        // magic，僅在未給 --keyfile 時才詢問密語。
        let keyfilePath = optValue("--keyfile")
        let wantEncrypt = args.contains("--encrypt")
        if wantEncrypt && !doCreate {
            eprint("Error: --encrypt applies to -c; use --encrypt-only to encrypt an existing file, and reading auto-detects encryption. / 錯誤：--encrypt 僅用於 -c；加密既有檔案請用 --encrypt-only，讀取時則自動偵測。")
            exit(1)
        }
        if (wantEncrypt || keyfilePath != nil) && (doAppend || doUpdate || doDelete) {
            eprint("Error: -r/-u/--delete work on plain uncompressed tar only. / 錯誤：-r/-u/--delete 僅支援未加密的純 tar。")
            exit(1)
        }
        if wantEncrypt || doEncryptOnly || (keyfilePath != nil && doCreate) {
            do {
                if let path = keyfilePath {
                    tarEncryptionSecret = .keyfile(try KeyInput.keyfileMaterial(path: path))
                } else {
                    tarEncryptionSecret = .passphrase(
                        try KeyInput.promptPassphrase("Passphrase / 密語: ", confirm: true))
                }
            } catch {
                eprint("Error: \(error.localizedDescription)")
                exit(1)
            }
        }
        // Reader-side provider; only consulted when an encrypted magic is found.
        // 讀取端金鑰提供者；僅在偵測到加密 magic 時才會被呼叫。
        tarDecryptionSecretProvider = {
            if let path = keyfilePath { return .keyfile(try KeyInput.keyfileMaterial(path: path)) }
            return .passphrase(try KeyInput.promptPassphrase("Passphrase / 密語: "))
        }

        // in-flight chunk budget, same policy as lzfse CLI / 在途分塊數，政策同 lzfse CLI
        let inflightN: Int = {
            let cores = max(1, ProcessInfo.processInfo.activeProcessorCount)
            var n = cores * 2
            if let raw = optValue("-n") {          // reject non-integer, same as lzfse2 CLI / 非整數報錯，同 lzfse2 CLI
                guard let v = Int(raw) else {
                    eprint("Error: -n expects an integer. / 錯誤：-n 需要整數。")
                    exit(1)
                }
                n = v
            }
            return min(max(1, n), cores * 4)
        }()

        // extraction write backend (Windows-only effect) / 解壓寫檔後端（僅影響 Windows）
        let writeBackend: WriteBackend = {
            let wantUcrt = args.contains("-write_ucrt") || args.contains("--write_ucrt")
            let wantFoundation = args.contains("-write_foundation") || args.contains("--write_foundation")
            if wantUcrt && wantFoundation {
                eprint("Error: -write_ucrt and -write_foundation are mutually exclusive. / 錯誤：-write_ucrt 與 -write_foundation 互斥。")
                exit(1)
            }
            // Default: ucrt — measured 25–35% faster than foundation across
            // the R45-Win matrix (one open per file vs two).
            // 預設 ucrt——R45-Win 矩陣實測比 foundation 快 25–35%（每檔 1 次
            // 開檔 vs 2 次）。
            return wantFoundation ? .foundation : .ucrt
        }()

        // --touch: leave extracted entries at the current time (GNU tar
        // semantics). / --touch：解出項目維持目前時間（GNU tar 語意）。
        let restoreMtime = !args.contains("--touch")

        let hasStripComponents = args.contains("--strip-components")
            || args.contains(where: { $0.hasPrefix("--strip-components=") })
        let stripComponents: Int = {
            guard hasStripComponents else { return 0 }
            guard let raw = optValueLong("--strip-components") else {
                eprint("Error: --strip-components expects a non-negative integer. / 錯誤：--strip-components 需要非負整數。")
                exit(1)
            }
            guard doExtract else {
                eprint("Error: --strip-components applies to -x only. / 錯誤：--strip-components 僅能用於 -x。")
                exit(1)
            }
            guard let v = Int(raw), v >= 0 else {
                eprint("Error: --strip-components expects a non-negative integer. / 錯誤：--strip-components 需要非負整數。")
                exit(1)
            }
            return v
        }()

        // positional file args (skip flags and their values) / 位置參數（略過旗標與其值）
        var files: [String] = []
        var skipNext = true   // args[0] is the binary path / args[0] 是執行檔路徑
        for a in args {
            if skipNext { skipNext = false; continue }
            if a == "-f" || a == "-C" || a == "-n" || a == "--keyfile" || a == "--strip-components" { skipNext = true; continue }
            if a.hasPrefix("-") { continue }
            files.append(a)
        }

        do {
            if doCreate {
                if explicitZip || forceZip64 {
                    try runZipCreate(archivePath: archivePath, files: files,
                                     changeDir: destDir, forceZip64: forceZip64,
                                     verbose: verbose)
                } else {
                    try runCreate(archivePath: archivePath, files: files, codec: codec,
                                  changeDir: destDir, inflight: inflightN, verbose: verbose)
                }
            } else if doAppend || doUpdate {
                try runAppend(archivePath: archivePath, files: files, update: doUpdate,
                              changeDir: destDir, inflight: inflightN, verbose: verbose)
            } else if doDelete {
                try runDelete(archivePath: archivePath, names: files, verbose: verbose)
            } else if doIdentify {
                if explicitZip || isZipMagic(archivePath) {
                    let label = archivePath == "-" ? "<stdin>" : archivePath
                    print("\(label): zip")
                } else {
                    try runIdentify(archivePath: archivePath, inflight: inflightN)
                }
            } else if doEncryptOnly {
                try runEncryptOnly(inputPath: archivePath, secret: tarEncryptionSecret!,
                                   inflight: inflightN)
            } else if doDecryptOnly {
                try runDecryptOnly(inputPath: archivePath, inflight: inflightN)
            } else if doCat {
                if explicitZip || isZipMagic(archivePath) {
                    throw TarError.io("--cat does not apply to ZIP containers / --cat 不適用於 ZIP 容器")
                }
                try runCat(archivePath: archivePath, inflight: inflightN, verbose: verbose)
            } else {
                if explicitZip || isZipMagic(archivePath) {
                    if stripComponents != 0 {
                        throw TarError.io("--strip-components is not supported for ZIP extraction / ZIP 解出不支援 --strip-components")
                    }
                    try runZipRead(archivePath: archivePath, extract: doExtract,
                                   destDir: destDir, verbose: verbose,
                                   restoreMtime: restoreMtime)
                } else {
                    try runRead(archivePath: archivePath, extract: doExtract,
                                destDir: destDir, inflight: inflightN, verbose: verbose,
                                writeBackend: writeBackend, restoreMtime: restoreMtime,
                                stripComponents: stripComponents)
                }
            }
        } catch {
            eprint("swift_tar: \(error.localizedDescription)")
            exit(1)
        }
    }

    // ---- create / 建立 ----

    static func runCreate(archivePath: String, files: [String], codec: TarCodec,
                          changeDir: String, inflight: Int, verbose: Bool) throws {
        guard !files.isEmpty else {
            throw TarError.io("no files to archive / 未指定要打包的檔案")
        }
        let output: FileHandle
        if archivePath == "-" {
            output = .standardOutput
        } else {
            _ = FileManager.default.createFile(atPath: archivePath, contents: nil)
            guard let fh = FileHandle(forWritingAtPath: archivePath) else {
                throw TarError.io("cannot create '\(archivePath)' / 無法建立 '\(archivePath)'")
            }
            output = fh
        }
        defer { if archivePath != "-" { try? output.close() } }

        // Open the archive before applying create-side -C, matching system
        // tar: a relative -f path stays relative to the invocation directory,
        // while input paths are resolved from the requested directory.
        // 先開啟封存輸出再套用建立端 -C，與系統 tar 一致：相對 -f 路徑仍以
        // 呼叫時目錄為基準，輸入路徑則改由指定目錄解析。
        let originalDir = FileManager.default.currentDirectoryPath
        if !changeDir.isEmpty && !FileManager.default.changeCurrentDirectoryPath(changeDir) {
            throw TarError.io("cannot chdir to '\(changeDir)' / 無法切換至 '\(changeDir)'")
        }
        defer {
            if !changeDir.isEmpty {
                _ = FileManager.default.changeCurrentDirectoryPath(originalDir)
            }
        }

        // Encryption wraps the codec: the sink compresses into a pipe and this
        // thread encrypts the compressed bytes on the way to the archive.
        // 加密包在 codec 之外：sink 將壓縮結果寫入 pipe，本執行緒再將壓縮後的
        // 位元組加密寫入封存。
        var sinkOutput = output
        var encryptPipe: Pipe? = nil
        let encryptGroup = DispatchGroup()
        let encryptError = ChainResult()
        if let secret = tarEncryptionSecret {
            let pipe = Pipe()
            encryptPipe = pipe
            sinkOutput = pipe.fileHandleForWriting
            encryptGroup.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { encryptGroup.leave() }
                do {
                    try TarCrypto.encryptStream(input: pipe.fileHandleForReading,
                                                output: output, secret: secret,
                                                inflight: inflight)
                } catch {
                    encryptError.fail(error.localizedDescription)
                }
            }
        }

        let sink = ParallelChunkSink(codec: codec, output: sinkOutput, inflight: inflight)
        let writer = TarWriter(sink: sink, verbose: verbose)
        for f in files {
            try writer.add(path: f)
        }
        try writer.finish()

        if encryptPipe != nil {
            try? sinkOutput.close()          // EOF for the encrypting thread / 讓加密執行緒讀到 EOF
            encryptGroup.wait()
            if let message = encryptError.message { throw TarError.io(message) }
        }
    }

    // ---- append / update (-r / -u) / 追加、更新 ----

    /// Report the codec name if `head` starts with a known compression magic,
    /// else nil. Used to reject -r/-u on compressed archives (matching GNU/BSD
    /// tar, which only append to uncompressed tar).
    /// 若 `head` 以已知壓縮 magic 開頭則回傳 codec 名稱，否則 nil。用於拒絕對
    /// 壓縮封存做 -r/-u（與 GNU/BSD tar 一致，僅未壓縮 tar 可追加）。
    static func compressedMagicName(_ head: Data) -> String? {
        let b = [UInt8](head)
        func has(_ magic: [UInt8]) -> Bool { b.count >= magic.count && Array(b.prefix(magic.count)) == magic }
        if has([0x1f, 0x8b]) { return "gzip" }
        if has([0x28, 0xb5, 0x2f, 0xfd]) { return "zstd" }
        if has([0xfd, 0x37, 0x7a, 0x58, 0x5a, 0x00]) { return "xz" }
        if has([0x42, 0x5a, 0x68]) { return "bzip2" }          // "BZh"
        if has([0x04, 0x22, 0x4d, 0x18]) { return "lz4" }
        if has([0x4c, 0x5a, 0x49, 0x50]) { return "lzip" }     // "LZIP"
        if has([0x1f, 0x9d]) { return "compress" }             // .Z
        if has([0x62, 0x76, 0x78]) { return "lzfse" }          // "bvx" (bvx2/bvx3/...)
        return nil
    }

    /// Scan an uncompressed tar to find (a) the logical EOF offset — the start
    /// of the first zero-block terminator — and (b) an archived name → mtime
    /// baseline for -u. Only 512-byte headers are read; entry data is skipped
    /// by seeking, so this is cheap on large archives. Extended headers
    /// (pax x/g, GNU L/K) are skipped by size like any entry, so the EOF offset
    /// stays correct even though their long names are not resolved into the
    /// baseline (an unresolved long-name entry simply gets re-added by -u).
    /// 掃描未壓縮 tar，取得 (a) 邏輯 EOF 位移——第一個零塊結尾的起點——與 (b)
    /// 供 -u 用的「檔內名稱 → mtime」基準。只讀 512-byte 標頭，資料以 seek 跳過，
    /// 故對大型封存很省。擴充標頭（pax x/g、GNU L/K）與一般項目一樣依 size 跳過，
    /// 因此即使未解析其長檔名，EOF 位移仍正確（未解析的長檔名項目只會被 -u 重新追加）。
    static func scanTarEntries(path: String) throws -> (eofOffset: UInt64, baseline: [String: UInt64]) {
        guard let fh = FileHandle(forReadingAtPath: path) else {
            throw TarError.io("cannot open '\(path)' / 無法開啟 '\(path)'")
        }
        defer { try? fh.close() }

        let head = (try? fh.read(upToCount: 8)) ?? Data()
        if let codecName = compressedMagicName(head) {
            throw TarError.io("cannot append to a \(codecName)-compressed archive; -r/-u work on uncompressed tar only / 無法對 \(codecName) 壓縮封存做 -r/-u；僅支援未壓縮 tar")
        }

        var offset: UInt64 = 0
        var baseline: [String: UInt64] = [:]
        while true {
            try fh.seek(toOffset: offset)
            guard let block = try fh.read(upToCount: TAR_BLOCK), block.count == TAR_BLOCK else {
                break   // no zero-block terminator; append at current end / 無零塊結尾，於目前末端接續
            }
            if block.allSatisfy({ $0 == 0 }) { break }   // logical EOF / 邏輯 EOF
            let h = [UInt8](block)
            func str(_ range: Range<Int>) -> String {
                let slice = h[range]
                let end = slice.firstIndex(of: 0) ?? range.upperBound
                return String(decoding: slice[range.lowerBound..<end], as: UTF8.self)
            }
            var name = str(0..<100)
            let prefix = str(345..<500)
            if !prefix.isEmpty { name = prefix + "/" + name }
            let size = parseTarNumber(h[124..<136])
            let mtime = parseTarNumber(h[136..<148])
            let typeflag = h[156]
            if typeflag != UInt8(ascii: "x") && typeflag != UInt8(ascii: "g")
                && typeflag != UInt8(ascii: "L") && typeflag != UInt8(ascii: "K") {
                // Directory names are stored with a trailing "/"; strip it so the
                // key matches TarWriter.archiveName for dirs (though dirs are not
                // gated by -u). / 目錄名以 "/" 結尾，去除以對齊 archiveName。
                var key = name
                if key.hasSuffix("/") { key.removeLast() }
                baseline[key] = mtime
            }
            let dataBlocks = (size + UInt64(TAR_BLOCK) - 1) / UInt64(TAR_BLOCK) * UInt64(TAR_BLOCK)
            offset += UInt64(TAR_BLOCK) + dataBlocks
        }
        return (offset, baseline)
    }

    static func runAppend(archivePath: String, files: [String], update: Bool,
                          changeDir: String, inflight: Int, verbose: Bool) throws {
        guard !files.isEmpty else {
            throw TarError.io("no files to append / 未指定要追加的檔案")
        }
        guard archivePath != "-" else {
            throw TarError.io("-r/-u need a seekable -f archive (not stdin/stdout) / -r/-u 需可定位的 -f 封存檔（不可用 stdin/stdout）")
        }
        let fm = FileManager.default
        // Missing archive: create it, matching GNU tar's -r/-u semantics.
        // 封存檔不存在：直接建立，與 GNU tar 的 -r/-u 語意一致。
        if !fm.fileExists(atPath: archivePath) {
            try runCreate(archivePath: archivePath, files: files, codec: .none,
                          changeDir: changeDir, inflight: inflight, verbose: verbose)
            return
        }

        let (eofOffset, baseline) = try scanTarEntries(path: archivePath)

        guard let output = FileHandle(forWritingAtPath: archivePath) else {
            throw TarError.io("cannot open '\(archivePath)' for append / 無法開啟 '\(archivePath)' 以追加")
        }
        defer { try? output.close() }
        try output.truncate(atOffset: eofOffset)   // drop the old zero-block terminator / 移除舊的零塊結尾
        try output.seek(toOffset: eofOffset)

        // Apply create-side -C after opening the archive, same as runCreate.
        // 開啟封存後再套用建立端 -C，與 runCreate 一致。
        let originalDir = fm.currentDirectoryPath
        if !changeDir.isEmpty && !fm.changeCurrentDirectoryPath(changeDir) {
            throw TarError.io("cannot chdir to '\(changeDir)' / 無法切換至 '\(changeDir)'")
        }
        defer {
            if !changeDir.isEmpty { _ = fm.changeCurrentDirectoryPath(originalDir) }
        }

        let sink = ParallelChunkSink(codec: .none, output: output, inflight: inflight)
        let writer = TarWriter(sink: sink, verbose: verbose,
                               updateBaseline: update ? baseline : nil)
        for f in files {
            try writer.add(path: f)
        }
        try writer.finish()
    }

    // ---- delete (swift_tar-only; BSD tar has no --delete) / 刪除（swift_tar 獨有，BSD tar 無此功能）----

    /// Remove named members from an uncompressed tar in place (≈ GNU tar
    /// --delete, which BSD tar lacks). Entries are streamed to a temp file:
    /// kept ones (with any preceding pax/GNU extended headers) are copied
    /// byte-for-byte, deleted ones — and their extended headers — are dropped.
    /// Large entry data is skipped by seeking, never buffered. The temp file
    /// then atomically replaces the original.
    /// 就地從未壓縮 tar 移除指定項目（≈ GNU tar --delete，BSD tar 沒有）。項目
    /// 串流至暫存檔：保留者（含其前置 pax/GNU 擴充標頭）逐位元組複製，刪除者
    /// （連同其擴充標頭）丟棄。大型項目資料以 seek 略過、不進記憶體。最後以暫存檔
    /// 原子替換原檔。
    static func runDelete(archivePath: String, names: [String], verbose: Bool) throws {
        guard !names.isEmpty else {
            throw TarError.io("no members to delete / 未指定要刪除的項目")
        }
        guard archivePath != "-" else {
            throw TarError.io("--delete needs a seekable -f archive (not stdin/stdout) / --delete 需可定位的 -f 封存檔（不可用 stdin/stdout）")
        }
        let fm = FileManager.default
        guard fm.fileExists(atPath: archivePath) else {
            throw TarError.io("cannot open '\(archivePath)' / 無法開啟 '\(archivePath)'")
        }
        guard let input = FileHandle(forReadingAtPath: archivePath) else {
            throw TarError.io("cannot open '\(archivePath)' / 無法開啟 '\(archivePath)'")
        }
        defer { try? input.close() }

        let head = (try? input.read(upToCount: 8)) ?? Data()
        if let codecName = compressedMagicName(head) {
            throw TarError.io("cannot delete from a \(codecName)-compressed archive; --delete works on uncompressed tar only / 無法從 \(codecName) 壓縮封存刪除；--delete 僅支援未壓縮 tar")
        }
        try input.seek(toOffset: 0)

        func norm(_ s: String) -> String {
            var t = s
            while t.hasSuffix("/") { t.removeLast() }
            return t
        }
        let wanted = Set(names.map { norm($0) })
        var matched = Set<String>()

        let tmpPath = archivePath + ".swifttar-del.tmp"
        _ = fm.createFile(atPath: tmpPath, contents: nil)
        guard let output = FileHandle(forWritingAtPath: tmpPath) else {
            throw TarError.io("cannot create temp '\(tmpPath)' / 無法建立暫存 '\(tmpPath)'")
        }
        var outputClosed = false
        func closeOutput() { if !outputClosed { try? output.close(); outputClosed = true } }
        // On any thrown error, drop the half-written temp file.
        // 若中途拋錯，清掉寫到一半的暫存檔。
        defer { closeOutput(); try? fm.removeItem(atPath: tmpPath) }

        func readFull(_ n: Int) throws -> Data? {
            var buf = Data(); buf.reserveCapacity(n)
            while buf.count < n {
                guard let part = try input.read(upToCount: n - buf.count), !part.isEmpty else {
                    return buf.isEmpty ? nil : buf
                }
                buf.append(part)
            }
            return buf
        }
        func str(_ h: [UInt8], _ range: Range<Int>) -> String {
            let slice = h[range]
            let end = slice.firstIndex(of: 0) ?? range.upperBound
            return String(decoding: slice[range.lowerBound..<end], as: UTF8.self)
        }

        var pending = Data()          // buffered pre-headers (pax x, GNU L/K) for the next entry
        var pendingName: String? = nil // effective name override from those pre-headers
        var removed = 0

        entries: while true {
            guard let block = try readFull(TAR_BLOCK), block.count == TAR_BLOCK else { break }
            if block.allSatisfy({ $0 == 0 }) { break }   // logical EOF / 邏輯 EOF
            let h = [UInt8](block)
            let size = parseTarNumber(h[124..<136])
            let typeflag = h[156]
            let dataLen = Int((size + UInt64(TAR_BLOCK) - 1) / UInt64(TAR_BLOCK)) * TAR_BLOCK

            switch typeflag {
            case UInt8(ascii: "x"), UInt8(ascii: "L"), UInt8(ascii: "K"):
                // Per-entry extended header: buffer header + data, decode name.
                // 逐項目擴充標頭：緩衝標頭＋資料，並解出名稱。
                guard let data = try readFull(dataLen), data.count == dataLen else {
                    throw TarError.format("truncated extended header / 擴充標頭不完整")
                }
                if typeflag == UInt8(ascii: "x") {
                    let records = data.prefix(Int(size))
                    var pos = records.startIndex
                    while pos < records.endIndex {
                        guard let sp = records[pos...].firstIndex(of: UInt8(ascii: " ")),
                              let len = Int(String(decoding: records[pos..<sp], as: UTF8.self)),
                              len > 0, pos + len <= records.endIndex else { break }
                        let kv = records[(sp + 1)..<(pos + len)]
                        if let eq = kv.firstIndex(of: UInt8(ascii: "=")) {
                            let key = String(decoding: kv[kv.startIndex..<eq], as: UTF8.self)
                            if key == "path" {
                                var v = kv[(eq + 1)...]
                                if v.last == UInt8(ascii: "\n") { v = v.dropLast() }
                                pendingName = String(decoding: v, as: UTF8.self)
                            }
                        }
                        pos += len
                    }
                } else if typeflag == UInt8(ascii: "L") {   // GNU long name
                    let raw = data.prefix(Int(size))
                    let end = raw.firstIndex(of: 0) ?? raw.endIndex
                    pendingName = String(decoding: raw[raw.startIndex..<end], as: UTF8.self)
                }
                pending.append(block)
                pending.append(data)
                continue

            case UInt8(ascii: "g"):
                // Global pax header: applies to all following entries, always keep.
                // 全域 pax 標頭：作用於後續所有項目，一律保留。
                guard let data = try readFull(dataLen), data.count == dataLen else {
                    throw TarError.format("truncated global header / 全域標頭不完整")
                }
                try output.write(contentsOf: block)
                try output.write(contentsOf: data)
                continue

            default:
                var name = str(h, 0..<100)
                let prefix = str(h, 345..<500)
                if !prefix.isEmpty { name = prefix + "/" + name }
                let effName = pendingName ?? name
                if wanted.contains(norm(effName)) {
                    matched.insert(norm(effName))
                    removed += 1
                    if verbose { eprint("d \(effName)") }
                    // drop pending pre-headers + this entry's data / 丟棄前置標頭與本項目資料
                    pending.removeAll(keepingCapacity: true)
                    pendingName = nil
                    try input.seek(toOffset: try input.offset() + UInt64(dataLen))
                } else {
                    // keep: write pre-headers + header, then stream the data
                    // 保留：寫出前置標頭與標頭，再串流資料
                    if !pending.isEmpty { try output.write(contentsOf: pending) }
                    pending.removeAll(keepingCapacity: true)
                    pendingName = nil
                    try output.write(contentsOf: block)
                    var remaining = dataLen
                    while remaining > 0 {
                        let want = min(remaining, DECODE_CHUNK)
                        guard let part = try readFull(want), part.count == want else {
                            throw TarError.format("truncated file data / 檔案資料不完整")
                        }
                        try output.write(contentsOf: part)
                        remaining -= want
                    }
                }
            }
        }
        // Terminate with two zero blocks (standard tar EOF).
        // 以兩個全零區塊作結尾（標準 tar EOF）。
        try output.write(contentsOf: Data(count: TAR_BLOCK * 2))
        closeOutput()
        try? input.close()

        for miss in wanted.subtracting(matched).sorted() {
            eprint("swift_tar: '\(miss)': not found in archive / 封存中找不到 '\(miss)'")
        }
        guard removed > 0 else {
            // Nothing removed: leave the original untouched, discard temp.
            // 未刪除任何項目：原檔不動，丟棄暫存。
            try? fm.removeItem(atPath: tmpPath)
            throw TarError.io("no matching members deleted / 未刪除任何符合的項目")
        }
        // Atomically replace the original with the rewritten archive.
        // 以重寫後的封存原子替換原檔。
        _ = try? fm.removeItem(atPath: archivePath)
        try fm.moveItem(atPath: tmpPath, toPath: archivePath)
        if verbose { eprint("swift_tar: deleted \(removed) member(s) / 已刪除 \(removed) 個項目") }
    }

    // ---- shared input opening / 共用輸入開啟 ----

    static func openInput(_ archivePath: String) throws -> FileHandle {
        if archivePath == "-" { return .standardInput }
        guard let fh = FileHandle(forReadingAtPath: archivePath) else {
            throw TarError.io("cannot open '\(archivePath)' / 無法開啟 '\(archivePath)'")
        }
        return fh
    }

    // ---- list / extract / 列出、解出 ----

    static func runRead(archivePath: String, extract: Bool, destDir: String,
                        inflight: Int, verbose: Bool,
                        writeBackend: WriteBackend = .ucrt,
                        restoreMtime: Bool = true,
                        stripComponents: Int = 0) throws {
        let input = try openInput(archivePath)
        defer { if archivePath != "-" { try? input.close() } }

        let group = DispatchGroup()
        let result = ChainResult()
        let stream = resolveFilterChain(input: input, prefix: Data(),
                                        filePath: archivePath, inflight: inflight,
                                        group: group, result: result)
        if verbose {
            let fmt = stream.names.isEmpty ? "none" : stream.names.joined(separator: " → ")
            eprint("swift_tar: compression format / 壓縮格式：\(fmt)")
        }
        guard result.ok else {
            throw TarError.io(result.message ?? "filter chain failed / filter 鏈失敗")
        }
        let options = TarReader.Options(extract: extract, destDir: destDir, verbose: verbose,
                                        inflight: inflight, writeBackend: writeBackend,
                                        stripComponents: stripComponents,
                                        restoreMtime: restoreMtime)
        try TarReader(input: stream.handle, prefix: stream.prefix).run(options: options)
        group.wait()
        guard result.ok else {
            throw TarError.io(result.message ?? "decompression failed / 解壓失敗")
        }
    }

    // ---- cat (bsdcat equivalent) / cat 模式（等同 bsdcat）----

    /// Encrypt a file as-is, without tar or a codec: `-f` is the input, the
    /// encrypted result goes to stdout. Useful for encrypting an archive that
    /// already exists. / 原樣加密一個檔案，不做 tar 也不壓縮：`-f` 為輸入，加密
    /// 結果寫到 stdout。適合加密既有的封存。
    static func runEncryptOnly(inputPath: String, secret: TarCrypto.KeySecret,
                               inflight: Int) throws {
        let input = try openInput(inputPath)
        defer { if inputPath != "-" { try? input.close() } }
        try TarCrypto.encryptStream(input: input, output: .standardOutput, secret: secret,
                                    inflight: inflight)
    }

    /// Strip only the encryption layer: `-f` is the encrypted input and the
    /// still-compressed payload goes to stdout, so an encrypted .tar.gz comes
    /// back as a plain .tar.gz. Unlike --cat, the codec is left untouched.
    /// 只剝除加密層：`-f` 為加密輸入，仍為壓縮狀態的內容寫到 stdout，因此加密的
    /// .tar.gz 會還原成一般 .tar.gz。與 --cat 不同，壓縮層不會被拆掉。
    static func runDecryptOnly(inputPath: String, inflight: Int) throws {
        let input = try openInput(inputPath)
        defer { if inputPath != "-" { try? input.close() } }

        var head = Data()
        while head.count < TarCrypto.magic.count,
              let part = try input.read(upToCount: TarCrypto.magic.count - head.count),
              !part.isEmpty {
            head.append(part)
        }
        guard [UInt8](head) == TarCrypto.magic else {
            throw TarError.io("not an encrypted archive (no swift_tar encryption header)"
                              + " / 不是加密封存（沒有 swift_tar 加密標頭）")
        }
        guard let provider = tarDecryptionSecretProvider else {
            throw TarError.io("no key available / 無可用金鑰")
        }
        try TarCrypto.decryptStream(input: input, prefix: head, output: .standardOutput,
                                    secret: try provider(), inflight: inflight)
    }

    static func runCat(archivePath: String, inflight: Int, verbose: Bool) throws {
        let input = try openInput(archivePath)
        defer { if archivePath != "-" { try? input.close() } }

        let group = DispatchGroup()
        let result = ChainResult()
        let stream = resolveFilterChain(input: input, prefix: Data(),
                                        filePath: archivePath, inflight: inflight,
                                        group: group, result: result)
        if verbose {
            let fmt = stream.names.isEmpty ? "none" : stream.names.joined(separator: " → ")
            eprint("swift_tar: compression format / 壓縮格式：\(fmt)")
        }
        guard result.ok else {
            throw TarError.io(result.message ?? "filter chain failed / filter 鏈失敗")
        }
        let out = FileHandle.standardOutput
        if !stream.prefix.isEmpty { try out.write(contentsOf: stream.prefix) }
        while let part = try? stream.handle.read(upToCount: DECODE_CHUNK), !part.isEmpty {
            try out.write(contentsOf: part)
        }
        group.wait()
        guard result.ok else {
            throw TarError.io(result.message ?? "decompression failed / 解壓失敗")
        }
    }

    // ---- identify (magic detection only, like `file`) / 辨識（只做 magic 偵測，類似 file）----

    /// Detect the compression/filter chain of `archivePath` by magic bytes,
    /// classify the decoded payload as tar or raw, print the result and stop —
    /// no extraction, nothing written to disk. Reuses the same libarchive-style
    /// bidder chain the read path uses, so detection is identical. Only enough
    /// bytes are read to identify (one tar block past the last filter); the
    /// decoder threads unwind on process exit.
    /// 依 magic 位元組偵測 `archivePath` 的壓縮／filter 鏈，判定解出的 payload 是 tar
    /// 或原始內容，印出後即停——不解壓、不落地。重用讀取端相同的 libarchive bidder
    /// 鏈，偵測結果一致。只讀到足以辨識（最後一層 filter 後一個 tar 區塊）；解碼
    /// 執行緒在行程結束時收束。
    static func runIdentify(archivePath: String, inflight: Int) throws {
        // Deliberately do not close `input`: the decoder threads may still be
        // reading it, and this is a one-shot command — the OS reclaims the fd
        // on exit. / 刻意不關閉 `input`：解碼執行緒可能仍在讀，且這是一次性指令，
        // fd 由行程結束時回收。
        let input = try openInput(archivePath)
        let group = DispatchGroup()
        let result = ChainResult()
        let stream = resolveFilterChain(input: input, prefix: Data(),
                                        filePath: archivePath, inflight: inflight,
                                        group: group, result: result)
        let label = archivePath == "-" ? "<stdin>" : archivePath

        // A bidder claimed the stream but it could not be decoded (e.g. lzop
        // without liblzo2): report the detected filter without probing further.
        // 有 bidder 認領但無法解碼（例如缺 liblzo2 的 lzop）：只回報偵測到的 filter。
        guard result.ok else {
            let chain = stream.names.isEmpty ? "unknown" : stream.names.joined(separator: " → ")
            print("\(label): \(chain) — \(result.message ?? "cannot decode / 無法解碼")")
            return
        }

        // Peek the decoded payload's first tar block to classify tar vs raw.
        // 探解出 payload 的第一個 tar 區塊，判定 tar 或原始內容。
        var head = Data(stream.prefix)
        while head.count < TAR_BLOCK,
              let part = try? stream.handle.read(upToCount: TAR_BLOCK - head.count), !part.isEmpty {
            head.append(part)
        }
        let h = [UInt8](head)
        let isTar = h.count >= 262 && Array(h[257..<262]) == Array("ustar".utf8)

        var chain = stream.names
        if isTar {
            chain.append("tar")
        } else if stream.names.isEmpty {
            chain.append("unrecognized (not tar) / 無法辨識（非 tar）")
        } else {
            chain.append("raw payload / 原始內容")
        }
        print("\(label): \(chain.joined(separator: " → "))")
    }
}
