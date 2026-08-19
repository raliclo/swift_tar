// =====================================================================
//  swift_tar.swift — Multi-core tar archiver in Swift
//  swift_tar.swift — Swift 多核心 tar 打包工具
//
//  Compile: ./compile_tar.zsh   (pairs with lzfse-cli.swift, runCLI() stripped)
//  編譯：./compile_tar.zsh（與剝除 runCLI() 的 lzfse-cli.swift 一起編譯）
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
// WinSDK on top of it, for GetFileAttributesW/DeleteFileW/RemoveDirectoryW.
// It was dropped in R44-Win when the ucrt backend replaced the WinSDK file
// I/O, not because it is unwelcome -- crypto.swift imports it in this same
// binary. The CRT has no lstat, so detecting a reparse point at a destination
// (see clearNonRegular) cannot be done without it.
// 在其之上再加 WinSDK，供 GetFileAttributesW/DeleteFileW/RemoveDirectoryW 使用。
// R44-Win 移除它是因為 ucrt 後端取代了 WinSDK 的檔案 I/O，並非不歡迎它——
// crypto.swift 在同一個 binary 中就有 import。CRT 沒有 lstat，因此若不引入它，
// 就無法偵測目的地上的 reparse point（見 clearNonRegular）。
import WinSDK
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
    // Create -C's target first. The tar extract path reaches its destination by
    // joining -C into each entry's path, so the directory-creation step makes
    // the whole chain on the way; the ZIP path hands -C to libarchive, which
    // chdir()s into it and fails outright if it is not already there. Same flag,
    // same command shape, opposite outcome -- and the README documents the
    // auto-creating one without scoping it to tar. Creating it here makes the
    // behaviour match the documentation rather than narrowing the documentation
    // to match one backend.
    // 先建立 -C 的目標。tar 解出路徑是把 -C 併入每個項目的路徑，故建立目錄那一步
    // 會沿途把整條路徑建出來；ZIP 路徑則是把 -C 交給 libarchive，由它 chdir() 進去，
    // 目錄不存在便直接失敗。同一個旗標、同樣的指令形狀，結果卻相反——而 README 記載
    // 的是會自動建立的那一種，且未限定只適用 tar。在此建立目錄，是讓行為符合文件，
    // 而非把文件縮限成只描述其中一個後端。
    if extract && !destDir.isEmpty && destDir != "." {
#if os(Windows)
        guard winMakeDirectories(destDir) else {
            throw TarError.io("cannot create directory '\(destDir)' / 無法建立目錄 '\(destDir)'")
        }
#else
        try? FileManager.default.createDirectory(atPath: destDir,
                                                 withIntermediateDirectories: true)
#endif
    }
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
// submodule (see build_zstd-win.zsh) instead of spawning one zstd.exe per chunk.
// zstd 在所有平台皆 in-process——Windows 連結靜態 libzstd submodule
// （見 build_zstd-win.zsh），不再每個 chunk 生一個 zstd.exe。

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

@_silgen_name("ZSTD_maxCLevel")
private func ZSTD_maxCLevel() -> Int32
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
/// zstd compression level, set once by `--zstd-level` during CLI parsing and
/// read-only from then on, so the concurrent chunk compressors all see the same
/// value. Default 9 rather than zstd's own default of 3: this tool is compared
/// against `zstd -9` throughout, and while the level was silently pinned at 3
/// those comparisons measured a level gap and were read as an implementation
/// gap. Matching the level the comparisons assume makes the default honest; use
/// `--zstd-level 3` for zstd CLI parity. The upper bound comes from
/// `ZSTD_maxCLevel()` (22 with libzstd 1.5.x) rather than a literal, so it
/// tracks the linked library. Note the zstd CLI silently caps at 19 unless
/// `--ultra` is passed; the C API has no such gate, so `--zstd-level 22` here
/// really is 22.
/// zstd 壓縮等級，於 CLI 解析時由 `--zstd-level` 設定一次，其後唯讀，因此並發的
/// 分塊壓縮器都看到同一個值。預設為 9 而非 zstd 自身的 3：本工具全程與 `zstd -9`
/// 對照，而等級被靜默固定在 3 的那段期間，這些對照量到的其實是等級差異，卻被解讀
/// 為實作差異。讓預設值符合對照所假設的等級才誠實；若需與 zstd CLI 一致請用
/// `--zstd-level 3`。上限取自 `ZSTD_maxCLevel()`（libzstd 1.5.x 為 22）而非寫死的
/// 常數，以隨連結的函式庫變動。注意 zstd CLI 未加 `--ultra` 時會靜默降到 19；
/// C API 無此限制，故此處的 `--zstd-level 22` 確實是 22。
var zstdCompressionLevel: Int32 = 9

func zstdCompressFrame(_ input: Data, level: Int32 = zstdCompressionLevel) -> Data? {
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
    // Always prefix, not only past MAX_PATH. The `\\?\` form does two jobs: it
    // lifts the length limit, and it turns off DOS path parsing -- including the
    // reserved device namespace. Applied by length alone, a member named `nul`
    // (or con, aux, prn, com1, lpt1) resolved to the device instead of a file:
    // extracting a Linux-made archive holding all seven names wrote six files,
    // silently dropped `nul` into the null device, and exited 0. GNU tar and
    // bsdtar both produced seven from the same archive, so this was never a
    // Windows limitation -- bsdtar is a native Windows binary too.
    // 一律加上前綴，而非僅在超過 MAX_PATH 時。`\\?\` 形式有兩個作用：解除長度限制，
    // 以及關閉 DOS 路徑解析——其中包含保留裝置名稱空間。若僅依長度套用，名為 `nul`
    // 的成員（或 con、aux、prn、com1、lpt1）會解析為裝置而非檔案：解出一個含這七個
    // 名稱、於 Linux 建立的封存時，只寫出六個檔案，`nul` 被無聲地丟進空裝置，且離開碼
    // 為 0。GNU tar 與 bsdtar 對同一封存都產出七個，故此非 Windows 的限制——bsdtar
    // 同樣是原生 Windows 程式。
    if !p.hasPrefix("\\\\?\\") {
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

/// Create `path` and every missing parent, one component at a time, each call
/// made on a `\\?\`-prefixed absolute path so no single call is bound by
/// MAX_PATH. Returns whether the directory exists afterwards.
///
/// Foundation cannot do this job: measured on Windows,
/// `createDirectory(atPath:withIntermediateDirectories: true)` fails on a
/// 503-character target **with or without** the prefix ("The file name is
/// invalid"). Extraction used it anyway, through `try?`, so a directory that
/// could not be created failed silently and the first visible symptom was the
/// *file* write reporting errno 2 (ENOENT) for a parent that had never been
/// made. swift_tar could therefore write archives it could not extract, while
/// GNU tar read the very same archives without trouble.
///
/// 逐一建立 `path` 及其所有缺失的父層，每次呼叫都用 `\\?\` 前綴的絕對路徑，
/// 因此沒有任何一次呼叫受 MAX_PATH 限制。回傳該目錄事後是否存在。
///
/// Foundation 做不到這件事：Windows 上實測，
/// `createDirectory(atPath:withIntermediateDirectories: true)` 對 503 字元的
/// 目標**無論加不加前綴**都失敗（「檔案名稱無效」）。解壓端卻仍使用它，且包在
/// `try?` 中，於是建不出來的目錄無聲失敗，最先看得見的症狀是**檔案**寫入回報
/// errno 2（ENOENT）——父層根本不存在。swift_tar 因此會寫出自己解不開的封存，
/// 而 GNU tar 讀同一批封存卻毫無問題。
private func winMakeDirectories(_ path: String) -> Bool {
    var abs = path.replacingOccurrences(of: "/", with: "\\")
    let u = Array(abs.utf16)
    let hasDrive = u.count >= 2 && u[1] == UInt16(UInt8(ascii: ":"))
    if !hasDrive && !abs.hasPrefix("\\\\") { abs = winProcessCwd + "\\" + abs }
    var comps: [Substring] = []
    for c in abs.split(separator: "\\", omittingEmptySubsequences: false) {
        if c == "." || c.isEmpty { continue }
        if c == ".." { if comps.count > 1 { comps.removeLast() }; continue }
        comps.append(c)
    }
    guard !comps.isEmpty else { return false }
    var built = String(comps[0])            // drive letter or UNC root
    for c in comps.dropFirst() {
        built += "\\" + c
        // Ignore the return: EEXIST is the common and correct outcome, and the
        // one answer that matters is the _waccess check below.
        // 忽略回傳值：EEXIST 是常見且正確的結果，真正算數的是下方的 _waccess。
        _ = ("\\\\?\\" + built).withCString(encodedAs: UTF16.self) { _wmkdir($0) }
    }
    return ("\\\\?\\" + built).withCString(encodedAs: UTF16.self) { _waccess($0, 0) == 0 }
}

/// Write one extracted regular file with the selected backend; returns an
/// error message on failure, nil on success. Called from FileWriterPool
/// workers (distinct paths only, no shared state).
/// 以選定後端寫出一個解壓檔案；失敗回傳錯誤訊息，成功回傳 nil。由
/// FileWriterPool 的 worker 呼叫（路徑各自獨立，無共享狀態）。
private func winWriteFile(dest: String, data: Data, mtime: UInt64,
                          backend: WriteBackend, restoreMtime: Bool = true) -> String? {
    clearNonRegular(dest)
    switch backend {
    case .foundation:
        // Single-call create+write+close (ONE open), then mtime via
        // setAttributes (second open). Current inline path costs three opens.
        // 一次呼叫完成建檔＋寫入＋關檔（單次開檔），再以 setAttributes 設
        // mtime（第二次開檔）。原 inline 路徑每檔要開三次。
        do {
            try data.write(to: URL(fileURLWithPath: dest), options: [])
        } catch {
            // A read-only destination is replaceable; retry once with the
            // attribute cleared before treating this as a real failure.
            // 唯讀目的地是可取代的；在視為真正失敗之前，清除屬性後重試一次。
            winClearReadOnly(dest)
            do {
                try data.write(to: URL(fileURLWithPath: dest), options: [])
            } catch {
                return createFailureMessage(dest, errnoValue: Int32(errno))
            }
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
        let openIt: () -> Int32 = {
            winUcrtPath(dest).withCString(encodedAs: UTF16.self) { w in
                _wsopen_s(&fd, w, _O_WRONLY | _O_CREAT | _O_TRUNC | _O_BINARY | _O_SEQUENTIAL,
                          _SH_DENYNO, _S_IREAD | _S_IWRITE)
            }
        }
        var openErr = openIt()
        if openErr == EACCES {
            // Found by the round 49 blind test: re-extracting over a tree whose
            // files had been marked read-only stopped at the first such file
            // with errno 13, and every later member was left stale. The POSIX
            // side of this was fixed in 335d20e; this path was missed because
            // the regression test had been grouped behind an mkfifo guard that
            // Windows skips.
            // 由 round 49 盲測發現：重新解出到已被標為唯讀的樹時，會停在第一個
            // 這種檔案並回報 errno 13，其後所有成員維持舊內容。POSIX 端已於
            // 335d20e 修正；此路徑當時被遺漏，因為該回歸測試被歸在 Windows 會
            // 跳過的 mkfifo 守衛之下。
            winClearReadOnly(dest)
            openErr = openIt()
        }
        guard openErr == 0, fd >= 0 else {
            return createFailureMessage(dest, errnoValue: openErr)
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

/// Remove whatever sits at `dest` unless it is a regular file, before a member
/// is written there. Opening a FIFO for writing blocks until a reader appears,
/// so extracting a regular member over an existing pipe hangs forever rather
/// than failing: measured at rc=124 under a 10 s timeout, where GNU tar --
/// which unlinks first -- finished in 110 ms. A pre-existing pipe is enough to
/// trigger it; the archive does not have to be hostile. The same unlink closes
/// a second hole, because a symlink at the *final* component would otherwise
/// be followed by `open` and the member written through it to the target.
/// Directories are left alone: `unlink` refuses them, and an error there is
/// the correct outcome. lstat, never stat -- stat would resolve the symlink
/// this exists to catch. Defined outside the platform conditional because the
/// inline streaming path that calls it is shared; the body is a no-op on
/// Windows, which has no FIFOs.
///
/// 在寫入成員之前，移除 `dest` 上任何非一般檔案的東西。對 FIFO 開啟寫入會阻塞
/// 到有讀者出現，因此在既有管線上解出一般成員不會失敗、而是永久卡住：實測在
/// 10 秒 timeout 下 rc=124，而先 unlink 的 GNU tar 只花 110 ms。觸發它只需要
/// 一個既存的管線，封存本身不必有惡意。同一個 unlink 也堵住第二個洞——否則
/// 位於**最後一段**的 symlink 會被 open 跟隨，成員就穿透寫到目標去。目錄不動：
/// unlink 本來就拒絕目錄，在那裡報錯才是對的結果。用 lstat 而非 stat——stat 會
/// 解析掉這裡正要抓的那個 symlink。定義在平台條件之外，因為呼叫它的 inline 串流
/// 路徑是共用的；在沒有 FIFO 的 Windows 上其內容為空操作。
private func clearNonRegular(_ dest: String) {
#if os(Windows)
    // Windows has no FIFOs, but it does have symlinks, and `_wsopen_s` follows
    // one at the final component exactly as `open` does: found by the test
    // backing the README's "a symlink is removed, not followed" row, which
    // passed on Linux and failed here -- the link's target received the
    // member's bytes while the destination kept a harmless-looking link. A
    // symlink already sitting at the destination is enough; the archive does
    // not have to carry one. A directory symlink needs RemoveDirectoryW, since
    // DeleteFileW refuses it.
    // Windows 沒有 FIFO，但有 symlink，而 `_wsopen_s` 對最後一段的 symlink 會如同
    // `open` 一樣跟隨：由撐住 README「symlink 會被移除而非跟隨」那一列的測試發現，
    // 該測試在 Linux 通過、在此失敗——連結目標收到了成員的內容，而目的地留下一個
    // 看似無害的連結。目的地上已存在的 symlink 就足以觸發，封存不必自帶。目錄
    // symlink 需用 RemoveDirectoryW，因為 DeleteFileW 拒絕它。
    let wide = Array(winUcrtPath(dest).utf16) + [0]
    let attrs = wide.withUnsafeBufferPointer { GetFileAttributesW($0.baseAddress!) }
    guard attrs != INVALID_FILE_ATTRIBUTES,
          attrs & UInt32(FILE_ATTRIBUTE_REPARSE_POINT) != 0 else { return }
    if attrs & UInt32(FILE_ATTRIBUTE_DIRECTORY) != 0 {
        _ = wide.withUnsafeBufferPointer { RemoveDirectoryW($0.baseAddress!) }
    } else {
        _ = wide.withUnsafeBufferPointer { DeleteFileW($0.baseAddress!) }
    }
#else
    var st = stat()
    guard dest.withCString({ lstat($0, &st) }) == 0 else { return }
    if st.st_mode & S_IFMT != S_IFREG { _ = dest.withCString { unlink($0) } }
#endif
}

/// Make sure a directory exists at `path`, removing a non-directory that stands
/// in its way. A project whose `config` file becomes a `config/` directory is an
/// ordinary event, and the archive says plainly which one it holds. Both
/// reference tars replace the file: measured on the same archive, `bsdtar` and
/// GNU `tar` both end 0 with `config` a directory, while this tool ended 1 with
/// the member unwritten and reported `errno 2` -- ENOENT, which names neither
/// the path that was occupied nor the fact that something occupied it.
///
/// Refusing was not a policy, it was an omission: extraction already replaces a
/// read-only file, a FIFO and a symlink at a destination (see `clearNonRegular`),
/// so singling out "a file where a directory is wanted" was the inconsistency.
/// Nothing new is exposed -- only names the archive itself claims, inside the
/// destination, are touched.
///
/// The existence check comes first because it is the common case and costs one
/// stat; the component walk runs only when creation has already failed, so an
/// ordinary extraction never pays for it.
///
/// 確保 `path` 處存在一個目錄，並移除擋在路上的非目錄。一個專案的 `config` 檔案演變成
/// `config/` 目錄是尋常事件，而封存本身已明白指出它持有的是哪一種。兩個參照實作都會
/// 取代該檔案：以同一份封存實測，`bsdtar` 與 GNU `tar` 皆以 0 結束且 `config` 成為
/// 目錄，而本工具以 1 結束、成員未寫入，並回報 `errno 2`——ENOENT，既沒指出被占用的
/// 路徑，也沒說明有東西占用了它。
///
/// 拒絕並非政策，而是遺漏：解出時本就會取代目的地上的唯讀檔案、FIFO 與 symlink（見
/// `clearNonRegular`），因此單獨把「該是目錄之處卻是檔案」挑出來拒絕，才是不一致之處。
/// 這不會擴大任何暴露面——被動到的只有封存自己聲稱的名稱，且都在目的地之內。
///
/// 先做存在性檢查，因為那是常見情形且只花一次 stat；逐段走訪僅在建立已經失敗時才執行，
/// 故尋常的解出永遠不必為它付出代價。
private func ensureDirectory(_ path: String) -> Bool {
    let fm = FileManager.default
    var isDir: ObjCBool = false
    if fm.fileExists(atPath: path, isDirectory: &isDir) {
        if isDir.boolValue { return true }
        winClearReadOnly(path)
        try? fm.removeItem(atPath: path)
    }
    if makeDirectories(path) { return true }

    // An interior component is a non-directory, not the last one. Clear each
    // blocker along the way and try once more.
    // 擋路的是中間某一段而非最後一段。逐段清掉阻礙後再試一次。
    var prefix = ""
    for comp in path.split(separator: "/", omittingEmptySubsequences: false) {
        prefix = prefix.isEmpty ? String(comp) : prefix + "/" + comp
        if prefix.isEmpty { continue }
        var interior: ObjCBool = false
        if fm.fileExists(atPath: prefix, isDirectory: &interior), !interior.boolValue {
            winClearReadOnly(prefix)
            try? fm.removeItem(atPath: prefix)
        }
    }
    return makeDirectories(path)
}

/// Explain why a member could not be written at `dest`. The errno alone
/// misleads when a directory occupies the name: Windows reports EACCES (13) and
/// POSIX EISDIR, and neither number says "something is already there, and it is
/// a directory". Refusing is correct and unanimous -- measured on one archive,
/// bsdtar says `Can't remove already-existing dir: Directory not empty` and GNU
/// tar says `Cannot open: File exists`, both preserving the directory's contents
/// exactly as this tool does -- so the behaviour was never the problem. Only the
/// message was, and it was the least informative of the three.
///
/// This is the third message of the same shape found in one blind-test run: an
/// RGB1 field reported as "invalid" without saying which rule, a blocked parent
/// directory reported as errno 2, and this. A number that names a symptom is
/// worse than no number, because it sends the reader to look at permissions.
///
/// 說明成員為何無法寫到 `dest`。當該名稱被一個目錄占用時，單看 errno 會誤導：Windows
/// 回報 EACCES（13）、POSIX 回報 EISDIR，兩個數字都沒說出「那裡已經有東西，而且是個
/// 目錄」。拒絕本身是正確且三方一致的——以同一份封存實測，bsdtar 說
/// `Can't remove already-existing dir: Directory not empty`、GNU tar 說
/// `Cannot open: File exists`，且都與本工具一樣完整保留該目錄的內容——所以問題從來不在
/// 行為，只在訊息，而它是三者中最不具資訊量的一個。
///
/// 這是同一次盲測中找到的第三則同形狀訊息：RGB1 欄位僅回報「invalid」而不說違反哪條規則、
/// 被擋住的父目錄回報 errno 2，以及本則。一個只點出症狀的數字比沒有數字更糟，因為它會把
/// 讀者引去查權限。
private func createFailureMessage(_ dest: String, errnoValue: Int32) -> String {
    var isDir: ObjCBool = false
    if FileManager.default.fileExists(atPath: dest, isDirectory: &isDir), isDir.boolValue {
        return "cannot write '\(dest)': a directory is already there and this archive "
             + "holds a file of that name; remove the directory if you meant to replace it / "
             + "無法寫入 '\(dest)'：該處已是一個目錄，而本封存持有同名的檔案；"
             + "若確實要取代，請先移除該目錄"
    }
    return "cannot create '\(dest)' (errno \(errnoValue)) / 無法建立 '\(dest)'"
}

/// The platform's "create with intermediates", as one name.
/// 平台各自的「連同中間層一起建立」，收攏為單一名稱。
private func makeDirectories(_ path: String) -> Bool {
#if os(Windows)
    return winMakeDirectories(path)
#else
    return (try? FileManager.default.createDirectory(
        atPath: path, withIntermediateDirectories: true)) != nil
#endif
}

/// Clear the read-only attribute on `dest` so an existing file there can be
/// replaced. Write permission on a file is not needed to replace it -- only on
/// its directory -- but Windows enforces the attribute on open *and* on delete,
/// so the POSIX answer of unlinking first does not work here: that is exactly
/// why bsdtar reports "Can't unlink already-existing object: Permission denied"
/// and leaves the member unwritten. Clearing the attribute is the Windows
/// analogue of that unlink. Called only after a failed open, never before.
/// Outside the platform conditional for the same reason as `clearNonRegular`:
/// the shared inline streaming path calls it, and the body is empty elsewhere.
///
/// 清除 `dest` 的唯讀屬性，使該處既有檔案可被取代。取代一個檔案不需要對該檔有
/// 寫入權——只需要對其目錄有——但 Windows 在開檔**與刪除**兩處都會強制該屬性，
/// 因此 POSIX 那套「先 unlink」在此行不通：這正是 bsdtar 回報
/// "Can't unlink already-existing object: Permission denied" 並讓該成員未被寫入的
/// 原因。清除屬性即為該 unlink 在 Windows 上的對應作法。僅在開檔失敗後呼叫，
/// 絕不預先呼叫。置於平台條件之外的理由與 `clearNonRegular` 相同：共用的 inline
/// 串流路徑會呼叫它，而在其他平台其內容為空。
private func winClearReadOnly(_ dest: String) {
#if os(Windows)
    _ = winUcrtPath(dest).withCString(encodedAs: UTF16.self) { w in
        _wchmod(w, _S_IREAD | _S_IWRITE)
    }
#endif
}

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
    clearNonRegular(dest)
    var fd = dest.withCString { open($0, O_WRONLY | O_CREAT | O_TRUNC, mode_t(mode)) }
    if fd < 0 && (errno == EACCES || errno == EPERM) {
        // The destination exists but its mode forbids writing. Write permission
        // on a file is not needed to replace it -- only on the directory -- so
        // unlink and create anew, which is what GNU tar does. Found against the
        // claw-code corpus: git stores loose objects 0444, so re-extracting any
        // tree containing a .git aborted on the first such object with errno 13
        // while GNU tar completed. Only after a failed open, never before: the
        // unconditional unlink would break a hard-linked member for no reason.
        //
        // 目的地存在但其權限不允許寫入。取代一個檔案不需要對該檔有寫入權——只需要
        // 對其目錄有——所以 unlink 後重建，這也是 GNU tar 的作法。以 claw-code
        // 語料發現：git 的鬆散物件為 0444，因此重新解出任何含 .git 的樹都會在第一個
        // 這種物件上以 errno 13 中止，而 GNU tar 能完成。僅在 open 失敗後才做，
        // 絕不預先做：無條件 unlink 會平白拆掉硬連結成員。
        _ = dest.withCString { unlink($0) }
        fd = dest.withCString { open($0, O_WRONLY | O_CREAT | O_TRUNC, mode_t(mode)) }
    }
    guard fd >= 0 else {
        return createFailureMessage(dest, errnoValue: errno)
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
        // A pax "path" record is required for two separate reasons, and only the
        // first is about length. pax records are defined to be UTF-8, so the
        // record is also what tells a reader the name is UTF-8 rather than bytes
        // in some local code page. Without it a short non-ASCII name travels as
        // bare ustar bytes and each reader guesses: GNU tar passes them through
        // and gets it right, while bsdtar on Windows decodes them through the
        // active code page and extracted "unicode-資料夾/檔案.txt" as
        // "unicode-Φ│çµûÖσñ╛/µ¬öµíê.txt". Measured: the same tree written by
        // GNU tar with --format=pax extracts correctly under bsdtar, and with
        // --format=ustar it does not -- so the pax record is the whole
        // difference, not anything about the bytes themselves.
        // pax 的 "path" 記錄有兩個各自獨立的必要理由，只有第一個與長度有關。pax
        // 記錄依規範即為 UTF-8，故該記錄同時也是「這個名稱是 UTF-8，而非某個本地
        // 碼頁的位元組」的唯一宣告。若缺少它，短的非 ASCII 名稱會以裸 ustar 位元組
        // 傳遞，各家讀取器只能自行猜測：GNU tar 原樣通過因而正確，Windows 上的
        // bsdtar 則以當前碼頁解碼，把 "unicode-資料夾/檔案.txt" 解成
        // "unicode-Φ│çµûÖσñ╛/µ¬öµíê.txt"。實測：同一棵樹由 GNU tar 以
        // --format=pax 寫出時 bsdtar 解得正確，以 --format=ustar 寫出則否——可見
        // 差別全在該 pax 記錄，而不在位元組本身。
        func isPureASCII(_ s: String) -> Bool { !s.utf8.contains { $0 >= 0x80 } }

        var pax = Data()
        var hdrName = name
        var hdrPrefix = ""
        if let split = TarWriter.splitUstarPath(name) {
            hdrPrefix = split.prefix
            hdrName = split.name
            if !isPureASCII(name) { pax.append(TarWriter.paxRecord("path", name)) }
        } else {
            pax.append(TarWriter.paxRecord("path", name))
            hdrName = String(decoding: Array(name.utf8.prefix(100)), as: UTF8.self)
        }
        var hdrLink = linkname
        if linkname.utf8.count > 100 {
            pax.append(TarWriter.paxRecord("linkpath", linkname))
            hdrLink = String(decoding: Array(linkname.utf8.prefix(100)), as: UTF8.self)
        } else if !linkname.isEmpty && !isPureASCII(linkname) {
            pax.append(TarWriter.paxRecord("linkpath", linkname))
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
        // Collapse repeated "/" and drop a trailing one. `tar -c tree/` must
        // store "tree/a.txt" as bsdtar does, but the walker recurses with
        // path + "/" + child on the argument as given, so a trailing slash
        // would reach every entry below as an interior "//" -- stripping only
        // the trailing slash here is therefore not enough. Left unnormalized
        // this is not cosmetic: --delete could not match the name the user
        // types, and -u judged every member absent and doubled the archive.
        // 摺疊重複的 "/" 並去除結尾的 "/"。bsdtar 對 `tar -c tree/` 存的是
        // "tree/a.txt"，但走訪器是以原引數做 path + "/" + child 遞迴，故尾隨
        // 斜線會以中間的 "//" 形式抵達底下每一個項目——因此只去尾隨斜線並不
        // 足夠。若不正規化，這並非外觀問題：--delete 會比對不到使用者鍵入的
        // 名稱，而 -u 會判定所有成員皆不存在，使封存翻倍。
        while p.contains("//") { p = p.replacingOccurrences(of: "//", with: "/") }
        while p.hasSuffix("/") && p.count > 1 { p.removeLast() }
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
        case S_IFIFO:
            // A FIFO carries no data: size 0, no payload, no block padding --
            // the same shape as the symlink case above. It is stored rather
            // than skipped because `mkfifo` needs no privilege on any POSIX
            // system, so the entry can always be restored. Device nodes and
            // sockets stay in `default:` below: the first needs root, and a
            // socket cannot be meaningfully recreated from an archive.
            // FIFO 不帶資料：size 為 0、無內容、無區塊填補——與上方 symlink 相同的
            // 形狀。之所以存下而非略過，是因為任何 POSIX 系統上的 `mkfifo` 都不需
            // 權限，該項目必定還原得回來。裝置節點與 socket 留在下方的 `default:`：
            // 前者需要 root，後者無法由封存有意義地重建。
            if verbose { eprint("a \(name)") }
            try writeEntryHeader(name: name, mode: mode, uid: uid, gid: gid,
                                 size: 0, mtime: mtime, typeflag: UInt8(ascii: "6"), linkname: "")
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

    /// Bytes left over after a read failed to fill its request. readExactly
    /// leaves what it did get in `pending`, so this distinguishes "the source
    /// ended exactly on a boundary" from "the source ended part-way through".
    /// 某次讀取未能填滿其請求後所餘的位元組數。readExactly 會把已取得的部分留在
    /// `pending`，故此值可區分「來源正好在邊界結束」與「來源在中途結束」。
    private var leftover: Int { pending.count - offset }

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
    /// Reduce an archived member name to a path that cannot escape the
    /// extraction directory, or nil if it tries to.
    ///
    /// This must normalise exactly what `archiveName()` normalises on the way in
    /// — backslashes, drive letters, leading separators — because an archive is
    /// not required to have been written by this tool. Splitting on "/" alone
    /// let three shapes through, each writing outside the target with exit 0 and
    /// no message:
    ///
    ///   ..\..\x.txt        one component to a "/"-only split, so the ".." test
    ///                      never saw a ".."; landed two levels above the -C dir
    ///   C:\Windows\...     no "/" at all, so it passed through whole and the
    ///                      Windows layer then honoured the drive letter
    ///   /tmp/x.txt         leading "/" was stripped, but the result still
    ///                      resolved outside the destination
    ///
    /// 將封存中的成員名稱化簡為無法逃出解出目錄的路徑，若其意圖逃逸則回傳 nil。
    ///
    /// 此處必須正規化的項目，與 `archiveName()` 在寫入端所做的完全相同——反斜線、
    /// 磁碟機代號、開頭的分隔符——因為封存不保證是本工具寫出的。僅以 "/" 分割會放行
    /// 三種形態，每一種都會寫到目標之外，且離開碼為 0、毫無訊息：
    ///
    ///   ..\..\x.txt        對「僅以 / 分割」而言是單一組件，".." 的檢查根本沒看到
    ///                      ".."；結果落在 -C 目錄之上兩層
    ///   C:\Windows\...     完全不含 "/"，整段原樣通過，Windows 層隨後採納了磁碟機代號
    ///   /tmp/x.txt         開頭的 "/" 雖被去除，結果仍解析到目的地之外
    private static func safeRelativePath(_ name: String) -> String? {
        var p = name.replacingOccurrences(of: "\\", with: "/")
        // Drive-relative and drive-absolute forms both start "X:"; drop it.
        // "X:" 開頭涵蓋磁碟機相對與絕對兩種形式，一律去除。
        if p.count >= 2, p[p.startIndex].isLetter, p[p.index(after: p.startIndex)] == ":" {
            p.removeFirst(2)
        }
        while p.hasPrefix("/") { p.removeFirst() }
        var comps = p.split(separator: "/")
        if comps.contains("..") { return nil }
        // Drop "." components. They carry no meaning in a path, and keeping them
        // made `./` -- the first entry in every archive written as
        // `tar -C dir .` -- resolve to a destination of exactly ".", which
        // crashed extraction with an illegal instruction whenever -C was absent.
        // `-C anything` masked it, including `-C .`, so the failure only appeared
        // in the plainest possible command: `swift_tar -x -f archive.tar`.
        // Dropping them makes `./` resolve to empty, which the caller's
        // !safeRel.isEmpty guard already skips -- correctly, since that entry
        // names the destination directory itself.
        // 丟棄 "." 組件。它在路徑中不帶任何意義，而保留它會使 `./`——凡是以
        // `tar -C dir .` 寫出的封存，其第一個項目——解析出恰為 "." 的目的地，導致在
        // 未給 -C 時解出以非法指令崩潰。任何 `-C` 都會掩蓋此問題，連 `-C .` 也一樣，
        // 因此該失敗只出現在最單純的指令上：`swift_tar -x -f archive.tar`。
        // 丟棄之後 `./` 解析為空字串，呼叫端既有的 !safeRel.isEmpty 守門便會略過它
        // ——這是正確的，因為該項目指的就是目的地目錄本身。
        comps.removeAll { $0 == "." }
        return comps.joined(separator: "/")
    }

    /// True when any directory on the way to `dest` is a symlink, meaning a
    /// write there would land wherever that link points.
    ///
    /// Sanitising the member's own name is not enough. An archive can carry two
    /// entries — a symlink `portal -> ../../..`, then a regular file
    /// `portal/pwned.txt` — and neither name contains `..` after the link is
    /// resolved, so a name-only check passes both while the write lands three
    /// directories above the destination. Measured on that exact pair: GNU tar
    /// 1.35 refuses with exit 2, bsdtar 3.8.4 lets it through, and swift_tar used
    /// to as well. Matching bsdtar is not a defence when the other reference this
    /// project claims interoperability with declines.
    ///
    /// Only the components below the destination are examined: `-C` itself may
    /// legitimately be reached through a symlink the user chose.
    ///
    /// 當通往 `dest` 路徑上的任一目錄為 symlink 時回傳 true，代表寫入該處會落到該
    /// 連結所指之地。
    ///
    /// 只清理成員自身的名稱並不足夠。封存可攜帶兩個項目——symlink `portal -> ../../..`，
    /// 接著一個一般檔案 `portal/pwned.txt`——在連結解析後兩者的名稱皆不含 `..`，故僅
    /// 檢查名稱會讓兩者都通過，而寫入卻落在目的地之上三層。以該組合實測：GNU tar 1.35
    /// 以離開碼 2 拒絕，bsdtar 3.8.4 放行，swift_tar 過去亦然。當本專案同樣宣稱互通的
    /// 另一個參照拒絕它時，「與 bsdtar 一致」並不構成辯護。
    ///
    /// 僅檢查目的地之下的各層：`-C` 本身可能是使用者自行選擇、經由 symlink 抵達的路徑。
    private static func passesThroughSymlink(dest: String, below root: String) -> Bool {
        let fm = FileManager.default
        let rootPrefix = root.isEmpty ? "" : (root.hasSuffix("/") ? root : root + "/")
        var walked = rootPrefix
        let tail = rootPrefix.isEmpty ? dest : String(dest.dropFirst(rootPrefix.count))
        for comp in tail.split(separator: "/").dropLast() {
            walked += (walked.isEmpty || walked.hasSuffix("/")) ? String(comp) : "/" + String(comp)
            if let attrs = try? fm.attributesOfItem(atPath: walked),
               attrs[.type] as? FileAttributeType == .typeSymbolicLink {
                return true
            }
            walked += "/"
        }
        return false
    }

    /// Return the earlier member this one would destroy, or nil.
    ///
    /// `seen` maps the case-folded destination to the spelling written under it.
    /// A hit with the *same* spelling is an ordinary duplicate name and is not a
    /// clash. A hit with a different spelling is only a clash if the file is
    /// already there, which is asked of the filesystem rather than assumed --
    /// on a case-sensitive volume the two names are separate files and nothing
    /// is lost. `drain` flushes queued writes first, so the existence test sees
    /// what has actually landed.
    ///
    /// 回傳本成員將摧毀的較早成員，若無則回傳 nil。
    ///
    /// `seen` 將摺疊大小寫後的目的地對應到實際寫出的拼法。以「相同」拼法命中者屬一般
    /// 的同名成員，不算碰撞。以不同拼法命中者，唯有該檔案確實已存在時才算碰撞——此點
    /// 詢問檔案系統而非逕行假設：在區分大小寫的卷宗上，那兩個名稱是各自獨立的檔案，
    /// 不會有任何損失。`drain` 先讓佇列中的寫入落地，使存在性檢查看到的是實際已寫出的
    /// 狀態。
    private static func caseClash(dest: String, seen: inout [String: String],
                                  drain: () -> Void) -> String? {
        let folded = dest.lowercased()
        if let previous = seen[folded], previous != dest {
            drain()
            if FileManager.default.fileExists(atPath: dest) {
                seen[folded] = dest
                return previous
            }
        }
        seen[folded] = dest
        return nil
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
        // -so: write each regular member's contents to stdout and touch no
        // filesystem at all -- bsdtar's -O / --to-stdout. Distinct from --cat,
        // which emits the tar stream itself rather than the members' contents.
        // -so：將各一般成員的內容輸出至 stdout，完全不動檔案系統——即 bsdtar 的
        // -O / --to-stdout。與 --cat 不同：後者輸出的是 tar 串流本身，而非成員內容。
        var toStdout: Bool = false
        // -i / --ignore-zeros: keep reading past the two zero blocks that mark
        // end-of-archive, for concatenated archives and for ones truncated mid
        // stream. Same meaning as in bsdtar and GNU tar.
        // -i / --ignore-zeros：略過標示封存結尾的兩個零區塊繼續讀取，用於串接的
        // 封存或中途截斷的封存。語意與 bsdtar、GNU tar 相同。
        var ignoreZeros: Bool = false
        // --force: allow a member to overwrite one written earlier in this same
        // extraction. Only that case; a file already on disk from a previous run
        // is overwritten as usual, which is what every tar does. Declared last so
        // the memberwise initializer's argument order matches the call site.
        // --force：允許某成員覆蓋「同一次解出中較早寫出」的檔案。僅限此情形；先前執行
        // 留下的既有檔案照常覆寫，與所有 tar 的行為一致。宣告於最後，使 memberwise
        // initializer 的引數順序與呼叫端一致。
        var force: Bool = false
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
        // Case-folded path -> the exact spelling written under it. Used to catch
        // two members of one archive landing on the same file because the
        // destination filesystem folds case: an archive from Linux can hold
        // file.txt and File.txt, and on NTFS (or a default macOS volume) the
        // second silently destroys the first, exit 0, no message.
        //
        // Two things this must NOT do. It must not fire on a genuine duplicate
        // name -- the same spelling twice is legal tar and the last copy wins by
        // design. And it must not guess whether the filesystem folds case: on
        // Linux those two names are distinct files and refusing would be wrong.
        // So a folded hit with a different spelling is only a collision if the
        // path we are about to write already exists, which is the filesystem
        // answering the question instead of us assuming it.
        //
        // 大小寫摺疊後的路徑 -> 實際寫出的拼法。用於偵測「同一封存的兩個成員因目的地
        // 檔案系統摺疊大小寫而落到同一個檔案」：來自 Linux 的封存可同時持有 file.txt
        // 與 File.txt，在 NTFS（或預設設定的 macOS 卷宗）上，後者會無聲摧毀前者，
        // 離開碼 0、毫無訊息。
        //
        // 有兩件事它絕不能做。不得對真正的同名成員觸發——相同拼法出現兩次是合法的 tar，
        // 且依設計由最後一份勝出。也不得「猜測」檔案系統是否摺疊大小寫：在 Linux 上那
        // 兩個名稱是相異檔案，擋下它是錯的。故「摺疊後相同但拼法不同」唯有在即將寫入的
        // 路徑已經存在時才算碰撞——那是由檔案系統回答此問題，而非由我們假設。
        var foldedWritten: [String: String] = [:]

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

        // A source shorter than one header block is not an empty archive. Zero
        // bytes is -- that is the convention, and bsdtar agrees -- but 100 bytes
        // of arbitrary data was read the same way: nothing was examined, `-t`
        // printed nothing and exited 0, so an unrecognised file passed for a
        // valid empty one. The boundary was exact at 512, because that is where
        // the first readExactly could finally fail on content rather than on
        // length. bsdtar rejects every size below it with "Unrecognized archive
        // format".
        // 短於一個標頭區塊的來源並不是空封存。零位元組才是——那是慣例，bsdtar 亦同——
        // 但 100 位元組的任意資料先前被以相同方式看待：不檢查任何東西，`-t` 不印任何
        // 內容並以 0 結束，於是一個無法辨識的檔案被當成合法的空封存。分界點精確落在
        // 512，因為那正是第一次 readExactly 得以因「內容」而非因「長度」失敗之處。
        // bsdtar 對其下的每一種大小都以「Unrecognized archive format」拒絕。
        while true {
            guard let block = readExactly(TAR_BLOCK) else {
                // Ran out mid-block. Zero bytes left means the source ended on a
                // clean boundary, which for an empty file is a legal empty
                // archive. Anything left is a partial header: the source is
                // shorter than one block, or ends part-way through one.
                // 在區塊中途耗盡。餘 0 表示來源在乾淨的邊界結束，對空檔案而言即合法的
                // 空封存。有殘餘則代表標頭不完整：來源短於一個區塊，或在區塊中途結束。
                if leftover > 0 {
                    throw TarError.format("not an archive: ends after \(leftover) bytes, mid-header / 並非封存：於第 \(leftover) 位元組處中止，標頭不完整")
                }
                break
            }
            if block.allSatisfy({ $0 == 0 }) {
                zeroBlocks += 1
                if zeroBlocks >= 2 && !options.ignoreZeros { break }
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

            // nil means the name tried to escape; empty means it resolved to the
            // destination itself, which "./" does -- the first entry of every
            // archive written as `tar -C dir .`. Only the first deserves a
            // warning: calling an ordinary "./" entry "unsafe" would put a
            // security-shaped message on almost every archive, which is how
            // people learn to ignore the real ones.
            // nil 代表該名稱意圖逃逸；空字串代表它解析為目的地本身，`./` 即屬此類
            // ——凡是以 `tar -C dir .` 寫出的封存，其第一個項目都是它。只有前者值得
            // 警告：把尋常的 `./` 項目稱為「不安全」，等於在幾乎每個封存上都掛一則
            // 安全性質的訊息，而那正是人們學會忽略真警告的方式。
            guard let safeRel = TarReader.safeRelativePath(name) else {
                eprint("swift_tar: skipping unsafe path '\(name)' / 略過不安全路徑 '\(name)'")
                if !isDir { try skipData(size) }
                continue
            }
            guard !safeRel.isEmpty else {
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

            // Refuse to write through a symlink planted by an earlier entry in
            // this same archive. See passesThroughSymlink for the two-entry
            // attack this stops.
            // 拒絕穿過「同一封存中較早項目所植入的 symlink」寫入。該兩項目攻擊的說明見
            // passesThroughSymlink。
            if TarReader.passesThroughSymlink(dest: dest, below: options.destDir) {
                eprint("swift_tar: skipping '\(rel)': path passes through a symlink / 略過 '\(rel)'：路徑穿過 symlink")
                if !isDir { try skipData(size) }
                continue
            }

            // -so is handled before any filesystem call: no parent directories,
            // no symlinks, no hardlinks, nothing removed. Only the contents of
            // regular members reach stdout; every other entry type is skipped,
            // which is what bsdtar -O does.
            // -so 在任何檔案系統呼叫之前處理：不建上層目錄、不建符號連結與硬連結、
            // 不刪除任何東西。僅一般成員的內容會送到 stdout，其餘型別一律略過，
            // 與 bsdtar -O 的行為相同。
            if options.toStdout {
                switch typeflag {
                case UInt8(ascii: "0"), 0, UInt8(ascii: "7"):
                    if isDir { continue }
                    var remaining = size
                    while remaining > 0 {
                        try autoreleasepool {
                            let want = Int(min(remaining, UInt64(DECODE_CHUNK)))
                            guard let chunk = readExactly(want) else {
                                throw TarError.format("truncated file data / 檔案資料不完整")
                            }
                            try FileHandle.standardOutput.write(contentsOf: chunk)
                            remaining -= UInt64(want)
                        }
                    }
                    let rem = Int(size % UInt64(TAR_BLOCK))
                    if rem != 0 { _ = readExactly(TAR_BLOCK - rem) }
                default:
                    if !isDir { try skipData(size) }
                }
                continue
            }

            let parent = (dest as NSString).deletingLastPathComponent
            if !parent.isEmpty {
                // Skip just this member when its parent cannot be made a
                // directory, rather than aborting: the rest of the archive is
                // unaffected and should still land. The POSIX side used to
                // ignore the failure entirely (`try?`), so the real cause was
                // never reported and the member died later with ENOENT.
                // 父目錄無法建立時只略過此成員而不中止整次執行：封存其餘部分不受影響，
                // 理應照常落地。POSIX 端原本完全忽略該失敗（`try?`），因此真正的原因
                // 從未被回報，而該成員稍後才以 ENOENT 死去。
                guard ensureDirectory(parent) else {
                    eprint("swift_tar: skipping '\(rel)': cannot make '\(parent)' a directory / 略過 '\(rel)'：無法使 '\(parent)' 成為目錄")
                    if !isDir { try skipData(size) }
                    continue
                }
            }

            switch typeflag {
            case UInt8(ascii: "5"):
                guard ensureDirectory(dest) else {
                    eprint("swift_tar: skipping directory '\(rel)': cannot create it / 略過目錄 '\(rel)'：無法建立")
                    continue
                }
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
            case UInt8(ascii: "6"):
#if os(Windows)
                // Windows has no FIFOs at all, so this is reported and skipped
                // rather than failed: an archive holding one is a perfectly
                // ordinary archive, and the rest of it extracts correctly. The
                // exit code is deliberately left alone, matching how a skipped
                // unsupported type has always behaved.
                // Windows 完全沒有 FIFO，故此處回報後略過而非失敗：含有 FIFO 的封存
                // 是再尋常不過的封存，其餘部分都能正確解出。離開碼刻意不變，與一向
                // 略過未支援型別的作法一致。
                eprint("swift_tar: skipping FIFO '\(rel)': Windows has no FIFOs / 略過 FIFO '\(rel)'：Windows 沒有 FIFO")
#else
                // Same queue hazard as the symlink case: a pool write to this
                // name must land first, or the worker recreates a regular file
                // on top of the pipe we are about to make.
                // 與 symlink 相同的佇列風險：同名的寫入池工作須先落地，否則 worker
                // 會在我們即將建立的管線之上又蓋回一個一般檔案。
                if submitted.contains(dest) { pool?.drain() }
                try? fm.removeItem(atPath: dest)
                if mkfifo(dest, mode_t(mode)) != 0 {
                    // Warn and carry on rather than throw. Not every filesystem
                    // has FIFOs -- DrvFs under /mnt/c, FAT and exFAT do not --
                    // and extracting there is a normal thing to do. Aborting the
                    // whole run over one unsupported entry would rebuild exactly
                    // the failure fixed in 1eb21d4, where a single unwritable
                    // member left every later one stale.
                    // 警告後繼續，而非丟出例外。並非每個檔案系統都有 FIFO——/mnt/c 的
                    // DrvFs、FAT 與 exFAT 都沒有——而解出到那些地方是尋常操作。為單一
                    // 不支援的項目中止整次執行，等於重建 1eb21d4 修掉的那個失敗：一個
                    // 寫不進去的成員讓其後每一個都停在舊內容。
                    eprint("swift_tar: cannot create FIFO '\(rel)' (errno \(errno)) / 無法建立 FIFO '\(rel)'")
                    continue
                }
                // mkfifo's mode argument is masked by umask, exactly as open's
                // is (see posixWriteFile). Without this chmod a 0666 pipe comes
                // out 0666 & ~umask, which is a silent difference from what the
                // archive recorded.
                // mkfifo 的 mode 參數會被 umask 遮罩，與 open 完全相同（見
                // posixWriteFile）。少了這個 chmod，0666 的管線會變成 0666 & ~umask，
                // 與封存所記錄的內容產生一個無聲的差異。
                chmod(dest, mode_t(mode))
                if options.restoreMtime {
                    try? fm.setAttributes([.modificationDate:
                        Date(timeIntervalSince1970: TimeInterval(mtime))], ofItemAtPath: dest)
                }
#endif
            case UInt8(ascii: "1"):
                // Say so when the target is refused. This guard used to drop the
                // entry with a bare `continue`: a hardlink aimed at
                // ../../../secret produced no stdout, no stderr and exit 0, so a
                // caller could not tell the archive had been altered at all.
                // The same tool already warns when a hardlink target is merely
                // missing, which made the security-relevant case the quiet one.
                // GNU tar reports both and exits 2.
                // 目標遭拒時要說出來。此守門原本以裸 `continue` 丟棄項目：指向
                // ../../../secret 的硬連結不產生任何 stdout 與 stderr，離開碼為 0，
                // 呼叫端因而完全無從得知封存曾被更動。同一支程式對「目標僅是不存在」
                // 的硬連結早已會發出警告，於是與安全相關的那個案例反而是沉默的那個。
                // GNU tar 兩者皆回報並以 2 結束。
                guard let safeLink = TarReader.safeRelativePath(linkname),
                      let strippedLink = TarReader.stripComponents(safeLink, count: options.stripComponents),
                      !strippedLink.isEmpty else {
                    eprint("swift_tar: skipping hardlink '\(rel)': unsafe target '\(linkname)' / 略過硬連結 '\(rel)'：目標不安全 '\(linkname)'")
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
#if os(Windows)
                    guard winMakeDirectories(dest) else {
                        throw TarError.io("cannot create directory '\(dest)' / 無法建立目錄 '\(dest)'")
                    }
#else
                    try? fm.createDirectory(atPath: dest, withIntermediateDirectories: true)
#endif
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
                    // No mid-loop failure check. There used to be one here, and
                    // because the workers are asynchronous it made the result a
                    // race: whether a member *after* a failing one got written
                    // depended on when that worker's error became visible.
                    // Measured on Windows with a directory blocking one member,
                    // 10 identical runs: the following member landed in 1 of
                    // them. A nondeterministic tree is worse than either policy,
                    // so the failure is now surfaced only by the drain at the
                    // end of the run -- every member is attempted, each failure
                    // is reported, and the run still exits non-zero. That is
                    // also what GNU tar and bsdtar do.
                    // 此處不做迴圈中的失敗檢查。原本有一個，而因為 worker 是非同步的，
                    // 它使結果成為競態：失敗成員**之後**的成員會不會被寫出，取決於該
                    // worker 的錯誤何時變得可見。在 Windows 上以一個目錄擋住某成員實測，
                    // 相同條件跑 10 次：後續成員只有 1 次落地。不確定的結果比任一種
                    // 政策都糟，故失敗改為僅由執行結尾的 drain 浮現——每個成員都會嘗試、
                    // 每個失敗都會回報，且整次執行仍以非 0 結束。GNU tar 與 bsdtar
                    // 亦是如此。
                    if !submitted.insert(dest).inserted {
                        // Duplicate path: earlier queued write must land first
                        // so the later entry wins (tar overwrite semantics).
                        // 重複路徑：先前佇列中的寫入須先落地，後者才能覆蓋
                        // （tar 的覆蓋語意）。
                        pool.drain()
                    }
                    if let clash = TarReader.caseClash(dest: dest, seen: &foldedWritten,
                                                       drain: { pool.drain() }) {
                        guard options.force else {
                            throw TarError.io(
                                "'\(rel)' would overwrite '\(clash)', written earlier in this archive "
                                + "(the destination does not distinguish case); pass --force to allow it / "
                                + "'\(rel)' 會覆蓋本封存稍早寫出的 '\(clash)'（目的地不區分大小寫）；"
                                + "如要允許請加上 --force")
                        }
                        eprint("swift_tar: warning: '\(rel)' overwrites '\(clash)' (case-insensitive destination) / 警告：'\(rel)' 覆蓋了 '\(clash)'（目的地不區分大小寫）")
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
                    clearNonRegular(dest)
                    _ = fm.createFile(atPath: dest, contents: nil)
                    var handle = FileHandle(forWritingAtPath: dest)
                    if handle == nil {
                        // Same read-only destination as posixWriteFile: remove
                        // it and create anew rather than failing the extract.
                        // The attribute has to be cleared first on Windows,
                        // where it blocks the delete as well as the open.
                        // 與 posixWriteFile 相同的唯讀目的地情形：移除後重建，
                        // 而不是讓整個解壓失敗。在 Windows 上必須先清除該屬性，
                        // 因為它同時擋住開檔與刪除。
                        winClearReadOnly(dest)
                        try? fm.removeItem(atPath: dest)
                        _ = fm.createFile(atPath: dest, contents: nil)
                        handle = FileHandle(forWritingAtPath: dest)
                    }
                    guard let out = handle else {
                        throw TarError.io(createFailureMessage(dest, errnoValue: Int32(errno)))
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
      --zstd-level <N> : zstd level, 1 to ZSTD_maxCLevel; default 9
                         zstd 等級，1 至 ZSTD_maxCLevel；預設 9
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
      -O, --to-stdout : (-x) members' contents to stdout, nothing written to
                        disk; the bsdtar / GNU tar spelling
                        （-x）將成員內容輸出至 stdout，不寫入任何檔案；
                        此為 bsdtar／GNU tar 的寫法
      -stream-in      : Read the archive from stdin, same as -f -
                        自 stdin 讀入封存，等同 -f -
      -stream-out     : Write the archive to stdout, same as -f -; with -x it
                        instead writes members' contents to stdout, as -O does.
                        Spelled out because GNU tar's -s is --same-order, so
                        -si / -so would mean something else there.
                        將封存輸出至 stdout，等同 -f -；搭配 -x 時改為輸出成員
                        內容，同 -O。使用完整字樣是因 GNU tar 的 -s 為
                        --same-order，故 -si / -so 在該處另有他意。
      -i              : Ignore the end-of-archive zero blocks and keep reading
                        略過封存結尾的零區塊繼續讀取（同 --ignore-zeros）
      -o              : Do not restore ownership; already the behaviour here,
                        accepted for tar compatibility
                        不還原擁有者；本工具本就如此，接受此旗標僅為相容 tar
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

/// Same as `runTarProcess`, but sends the child's stdout to `toFile`. Needed to
/// check the flags whose whole purpose is what lands on stdout.
/// 同 `runTarProcess`，但將子行程的 stdout 導向 `toFile`。用於檢查那些「重點就在
/// stdout 輸出什麼」的旗標。
func runTarProcessCapturingStdout(_ exePath: String, _ args: [String],
                                  toFile: String, cwd: String? = nil) -> Bool {
    FileManager.default.createFile(atPath: toFile, contents: nil)
    guard let out = FileHandle(forWritingAtPath: toFile) else { return false }
    defer { try? out.close() }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: exePath)
    process.arguments = args
    if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
    var env = ProcessInfo.processInfo.environment
    env["COPYFILE_DISABLE"] = "1"
    process.environment = env
    process.standardOutput = out
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
    // Deliberately no skip() helper. Every case runs on every platform: where
    // the platform tar cannot do ZIP, the suite falls back to Info-ZIP's unzip
    // and zip, and fails if those are absent too. A skipped case reads like a
    // passing one at a glance, and this suite gates whole benchmark rounds.
    // 刻意不提供 skip() 輔助函式。每個項目在每個平台都會執行：平台 tar 無法處理
    // ZIP 時，改用 Info-ZIP 的 unzip 與 zip 備援，兩者亦不存在才判定失敗。
    // 被跳過的項目乍看與通過無異，而本套測試正是整輪 benchmark 的守門條件。

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

    // The compatibility peer for ZIP differs by platform. bsdtar reads and
    // writes ZIP through libarchive, so on Windows and macOS the platform tar
    // is the peer. GNU tar, which is what Linux ships, has no ZIP support at
    // all -- `tar -tf x.zip` answers "This does not look like a tar archive".
    // Reporting that as a swift_tar failure is wrong twice over: it blames the
    // wrong component, and it makes -test fail on Linux for every run, which
    // matters because run_round.command gates on -test passing. Probe for the
    // capability and fall back to unzip / zip, which Linux does have.
    // ZIP 的互通對象因平台而異。bsdtar 透過 libarchive 可讀寫 ZIP，故 Windows 與
    // macOS 以平台 tar 為對象。Linux 隨附的 GNU tar 則完全不支援 ZIP——
    // `tar -tf x.zip` 會回答「This does not look like a tar archive」。把這回報成
    // swift_tar 失敗有雙重錯誤：歸咎於錯誤的元件，且會使 Linux 上每次 -test 都失敗，
    // 而 run_round.command 正是以 -test 通過與否作為守門條件。因此改為偵測能力，
    // 不足時退回 Linux 本就具備的 unzip / zip。
    func toolPath(_ name: String) -> String? {
#if os(Windows)
        let pathSep: Character = ";"
#else
        let pathSep: Character = ":"
#endif
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: pathSep).map(String.init) {
            let p = dir + "/" + name
            if fm.isExecutableFile(atPath: p) { return p }
#if os(Windows)
            let exe = p + ".exe"
            if fm.isExecutableFile(atPath: exe) { return exe }
#endif
        }
        return nil
    }
    // Probed rather than assumed from the platform: a Linux box may well have
    // bsdtar installed as `tar`, and a probe is right in both cases.
    // 以實測而非平台推定：Linux 機器也可能將 bsdtar 安裝為 `tar`，實測在兩種情況
    // 下都正確。
    let stdTarReadsZip: Bool = {
        guard runTarProcess(selfExe, ["-c", "--zip", "-f", "\(tmp)/zip_probe.zip", "-C", tmp, "src"])
        else { return false }
        return runTarProcess(stdTar, ["-t", "-f", "\(tmp)/zip_probe.zip"])
    }()
    let unzipTool = toolPath("unzip")
    let zipTool = toolPath("zip")

    if runTarProcess(selfExe, ["-c", "--zip", "-f", zipA, "-C", tmp, "src"]) {
        let out = "\(tmp)/zip_out_std"
        try? fm.createDirectory(atPath: out, withIntermediateDirectories: true)
        if stdTarReadsZip {
            let extracted = runTarProcess(stdTar, ["-x", "-f", zipA, "-C", out])
            check("ZIP: swift_tar create → std tar extract",
                  extracted && compareTrees(srcDir, "\(out)/src"))
        } else if let unzipTool {
            let extracted = runTarProcess(unzipTool, ["-q", zipA, "-d", out])
            check("ZIP: swift_tar create → unzip extract",
                  extracted && compareTrees(srcDir, "\(out)/src"))
        } else {
            // Not skipped: without a ZIP-capable peer the environment cannot
            // verify interoperability at all, which is worth failing over
            // rather than passing over in silence. Install unzip.
            // 不跳過：缺少可處理 ZIP 的對象時，此環境根本無法驗證互通性，那應當
            // 失敗而非默默放行。請安裝 unzip。
            check("ZIP: swift_tar create → external extract (install unzip)", false)
        }
    } else {
        check("ZIP: swift_tar create → external extract", false)
    }

    if stdTarReadsZip, runTarProcess(stdTar, ["-c", "--format", "zip", "-f", zipB, "-C", tmp, "src"]) {
        let out = "\(tmp)/zip_out_swift"
        try? fm.createDirectory(atPath: out, withIntermediateDirectories: true)
        let extracted = runTarProcess(selfExe, ["-x", "-f", zipB, "-C", out])
        check("ZIP: std tar create → swift_tar extract",
              extracted && compareTrees(srcDir, "\(out)/src"))
    } else if let zipTool, runTarProcess(zipTool, ["-qr", zipB, "src"], cwd: tmp) {
        let out = "\(tmp)/zip_out_swift"
        try? fm.createDirectory(atPath: out, withIntermediateDirectories: true)
        let extracted = runTarProcess(selfExe, ["-x", "-f", zipB, "-C", out])
        check("ZIP: zip create → swift_tar extract",
              extracted && compareTrees(srcDir, "\(out)/src"))
    } else {
        // Not skipped: reading a ZIP that swift_tar did not write is the whole
        // point of this check, so without a peer that can write one the
        // environment cannot verify interoperability at all. Fail rather than
        // pass in silence. Install zip.
        // 不跳過：讀取非 swift_tar 所寫的 ZIP 正是本檢查的意義，因此缺少能寫 ZIP
        // 的對象時，此環境根本無法驗證互通性。應當失敗而非默默放行。請安裝 zip。
        check("ZIP: external create → swift_tar extract (install zip)", false)
    }

    let zip64 = "\(tmp)/zip64_by_swift_tar.zip"
    if runTarProcess(selfExe, ["-c", "--zip64", "-f", zip64, "-C", tmp, "src"]),
       let zip64Data = fm.contents(atPath: zip64) {
        // The ZIP64 end-of-central-directory record is checked regardless of
        // which peer reads the archive back; only the read side varies.
        // 不論由哪個對象讀回，ZIP64 的 end-of-central-directory 記錄都會被檢查；
        // 僅讀取端會因平台而異。
        let signature = Data([0x50, 0x4b, 0x06, 0x06])
        let hasZip64Record = zip64Data.range(of: signature) != nil
        let out = "\(tmp)/zip64_out_std"
        try? fm.createDirectory(atPath: out, withIntermediateDirectories: true)
        if stdTarReadsZip {
            let extracted = runTarProcess(stdTar, ["-x", "-f", zip64, "-C", out])
            check("ZIP64: record + std tar extract",
                  hasZip64Record && extracted && compareTrees(srcDir, "\(out)/src"))
        } else if let unzipTool {
            let extracted = runTarProcess(unzipTool, ["-q", zip64, "-d", out])
            check("ZIP64: record + unzip extract",
                  hasZip64Record && extracted && compareTrees(srcDir, "\(out)/src"))
        } else {
            check("ZIP64: record + external extract (install unzip)", false)
        }
    } else {
        check("ZIP64: record + external extract", false)
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

    // ---- stdout extraction and tar-compatibility flags ----
    // The point of these is that they write nothing. An option this tool does
    // not know used to be skipped in silence, so `-x --to-stdout` extracted the
    // whole archive to the current directory while reading as a stream to
    // nowhere; the Windows benchmark recorded those disk writes as decode
    // timings. Each case below therefore asserts on the directory being empty,
    // not merely on the exit status.
    // ---- 輸出至 stdout 與 tar 相容旗標 ----
    // 這些旗標的重點在於「不寫入任何東西」。本工具過去會靜默略過不認識的選項，
    // 使 `-x --to-stdout` 看似串流至空裝置，實則把整個封存解到當前目錄；Windows
    // benchmark 曾把那些磁碟寫入記為解壓計時。因此以下每項都檢查目錄是否為空，
    // 而不只看結束碼。
    let soDir = "\(tmp)/stdout_flags"
    try? fm.createDirectory(atPath: soDir, withIntermediateDirectories: true)
    let soArchive = "\(soDir)/a.tar.zst"
    if runTarProcess(selfExe, ["-c", "--zstd", "-f", soArchive, "-C", tmp, "src"]) {
        let probeDir = "\(soDir)/probe"
        // Captured to a real file rather than discarded: this asserts both that
        // nothing lands on disk and that the members' bytes actually reach
        // stdout. Discarding via Foundation's nullDevice is not usable here --
        // a FileHandle write to it fails on Windows, which `print()` swallows
        // but `write(contentsOf:)` reports, so the child would exit non-zero
        // for a reason unrelated to what is being tested.
        // 擷取到真實檔案而非丟棄：如此可同時驗證「磁碟上沒有東西」與「成員位元組
        // 確實抵達 stdout」。此處不能用 Foundation 的 nullDevice 丟棄——在 Windows
        // 上對它進行 FileHandle 寫入會失敗，`print()` 會吞掉此錯誤而
        // `write(contentsOf:)` 會回報，使子行程因與待測項無關的原因回傳非零。
        let expected = "swift_tar self-test root file\n"
        for spelling in ["-O", "--to-stdout", "-stream-out"] {
            try? fm.removeItem(atPath: probeDir)
            try? fm.createDirectory(atPath: probeDir, withIntermediateDirectories: true)
            let captured = "\(soDir)/captured\(spelling).bin"
            let ok = runTarProcessCapturingStdout(selfExe, [spelling, "-x", "-f", soArchive],
                                                  toFile: captured, cwd: probeDir)
            let left = (try? fm.contentsOfDirectory(atPath: probeDir))?.count ?? -1
            let body = (try? String(contentsOfFile: captured, encoding: .utf8)) ?? ""
            check("\(spelling) with -x: streams to stdout, writes nothing",
                  ok && left == 0 && body.contains(expected))
        }
        // An unknown option must stop the command rather than be skipped.
        // 未知選項必須中止指令，而非被略過。
        try? fm.removeItem(atPath: probeDir)
        try? fm.createDirectory(atPath: probeDir, withIntermediateDirectories: true)
        let bogusRan = runTarProcess(selfExe, ["--no-such-option", "-x", "-f", soArchive], cwd: probeDir)
        let bogusLeft = (try? fm.contentsOfDirectory(atPath: probeDir))?.count ?? -1
        check("unknown option: rejected, nothing extracted", !bogusRan && bogusLeft == 0)
        // -i and -o exist for tar compatibility and must not break a normal read.
        // -i 與 -o 為相容 tar 而存在，且不得影響正常讀取。
        check("-i / -o accepted on a normal list",
              runTarProcess(selfExe, ["-t", "-i", "-o", "-f", soArchive]))
        // -stream-in feeds the archive through stdin; -stream-out emits it there.
        // -stream-in 以 stdin 餵入封存；-stream-out 由該處輸出。
        let piped = "\(soDir)/piped.tar.zst"
        check("-stream-out with -c: archive on stdout",
              runTarProcessCapturingStdout(selfExe, ["-c", "--zstd", "-stream-out", "-C", tmp, "src"],
                                           toFile: piped)
              && ((try? fm.attributesOfItem(atPath: piped)[.size] as? Int) ?? 0) > 0)
    } else {
        check("stdout flags: create archive", false)
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
#else
        // Windows opens the CRT's stdout in text mode, so every "\n" that
        // print() emits leaves as "\r\n". That silently made -t and --identify
        // disagree with system tar on Windows by one invisible byte per line:
        // the names matched, `diff` against a bsdtar listing still failed
        // everywhere, and CR is exactly the byte grep/sed cannot show you.
        // Archive bytes were never affected -- those go through FileHandle,
        // which bypasses the CRT -- so this switch only touches the textual
        // reports, and it fixes them for every print() rather than one by one.
        // Windows 的 CRT stdout 預設為文字模式，故 print() 送出的每個 "\n" 都會
        // 變成 "\r\n"。這使得 -t 與 --identify 在 Windows 上與系統 tar 相差每行
        // 一個看不見的位元組：名稱明明相同，與 bsdtar 列表做 diff 卻全行不符，
        // 而 CR 正是 grep/sed 無法顯示給你看的那個位元組。封存位元組從未受影響
        // ——它們走 FileHandle，不經 CRT——故此設定只影響文字報告，且是一次修好
        // 所有 print()，而非逐一修補。
        _ = _setmode(_fileno(stdout), _O_BINARY)
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
            // Everything after a bare "--" is an operand, so cluster expansion has
            // to stop there too, not just the option check further down. A file
            // named "-report.csv" would otherwise be shredded into -r -e -p -o -r
            // -t ... before the "--" was ever honoured, and the user would be told
            // "unknown option -e" about a flag that does not exist in this tool.
            // 裸 "--" 之後的一切皆為運算元，故叢集展開也必須在此停止，而不只是下方的
            // 選項檢查。否則名為 "-report.csv" 的檔案會在 "--" 生效之前就被拆成
            // -r -e -p -o -r -t …，而使用者收到的是關於一個本工具根本沒有的旗標
            // 「unknown option -e」。
            var pastEndOfOptions = false
            for (idx, a) in CommandLine.arguments.dropFirst().enumerated() {
                if pastEndOfOptions { out.append(a); continue }
                if a == "--" { pastEndOfOptions = true; out.append(a); continue }
                // Single-dash flags that are words, not clusters of short
                // options, must survive intact: -write_ucrt and -write_foundation
                // carry "_", while -stream-in and -stream-out carry "-", which
                // the rule below does not exempt, so they are named here.
                // 屬於「單字」而非短旗標叢集的單槓旗標必須保持完整：-write_ucrt 與
                // -write_foundation 含底線，-stream-in 與 -stream-out 含連字號，
                // 下方規則並未豁免，故在此列名。
                let singleDashWords: Set<String> = ["-stream-in", "-stream-out"]
                // A negative number is a value, never a cluster of short options.
                // Without this, --lat -33.8688 expanded to -3 -3 -. -8 -6 -8 -8
                // and optValue("--lat") read back "-3": the container was written
                // with latitude -3.0000000 and exited 0. Every negative-valued
                // field was affected -- southern latitudes, western longitudes,
                // below-sea-level heights, pre-1970 timestamps, and the whole of
                // the Americas' timezone offsets -- silently, in a format meant
                // to be archived.
                // 負數是「值」，絕不會是短旗標叢集。若無此判斷，--lat -33.8688 會被展開為
                // -3 -3 -. -8 -6 -8 -8，而 optValue("--lat") 讀回 "-3"：容器就以緯度
                // -3.0000000 寫出並以 0 結束。所有可為負值的欄位皆受影響——南半球緯度、
                // 西經、海平面以下高度、1970 年前的時間戳，以及整個美洲的時區偏移
                // ——而且是靜默發生在一個用於長期保存的格式上。
                //
                // isFinite matters: Double("-inf") and Double("-nan") both parse,
                // and -inf is a legitimate cluster here (-i -n -f). No option
                // value is legitimately infinite, so only finite numbers are
                // treated as values.
                // isFinite 是必要的：Double("-inf") 與 Double("-nan") 都能解析，而 -inf
                // 在此確實是合法叢集（-i -n -f）。沒有任何選項的值會是無限大，故僅有限數
                // 才視為值。
                let isNegativeNumber: Bool = { if let d = Double(a) { return d.isFinite }; return false }()
                if a.hasPrefix("-") && !a.hasPrefix("--") && a.count > 2
                    && !a.contains("_") && !singleDashWords.contains(a)
                    && !isNegativeNumber {
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

        // Validated here, before any command branch, not after them. The RGB1
        // modes below return without reaching the tar path, so while this lived
        // further down they were the one family of commands that never saw it:
        // `--titel WRONG --title ok` wrote a container and exited 0, and so did
        // a wholly invented `--totally-bogus X`. That is the same silent
        // acceptance the check was added to remove, surviving in the corner the
        // check could not reach.
        // 於此驗證——在任何命令分支之前，而非之後。下方的 RGB1 模式會在抵達 tar 路徑前
        // 就返回，故當本檢查位於更下方時，它們正是唯一從未經過檢查的一族命令：
        // `--titel WRONG --title ok` 會寫出容器並以 0 結束，完全虛構的 `--totally-bogus X`
        // 亦然。那正是本檢查所要消除的靜默接受，只是存活在檢查搆不到的角落。

        // Every option this tool accepts. An unrecognised one is an error rather
        // than something to skip past: silently ignoring it means the command
        // does something other than what was asked and says nothing about it.
        // `swift_tar --to-stdout -x -f a.tar.zst > /dev/null` read as a
        // stream-to-nowhere and in fact extracted the whole archive to the
        // current directory, because --to-stdout is bsdtar's spelling and this
        // tool has no such option; the benchmark measured disk writes for
        // months believing it measured decompression. Use --cat for that.
        // 本工具接受的所有選項。無法辨識者視為錯誤而非略過：靜默忽略會使指令做出
        // 與要求不同的事，且毫無提示。`swift_tar --to-stdout -x -f a.tar.zst
        // > /dev/null` 看起來像是串流到空裝置，實際卻把整個封存解到當前目錄——
        // 因為 --to-stdout 是 bsdtar 的寫法，本工具並無此選項；benchmark 因此
        // 長期把磁碟寫入當成解壓縮在量測。該用途請改用 --cat。
        let knownOptions: Set<String> = [
            // commands / 命令
            "-c", "-x", "-t", "-r", "-u", "--delete", "--identify", "--cat",
            "--encrypt-only", "--decrypt-only",
            "--rgb1-pack", "--rgb1-info", "--rgb1-raw",
            // options / 選項
            "-f", "-C", "-n", "-v", "-h", "--touch", "--keyfile", "--encrypt",
            "-stream-in", "-stream-out", "-O", "--to-stdout", "-i", "--ignore-zeros",
            "-o", "--no-same-owner", "--force",
            "--strip-components", "--zstd-level",
            "-write_ucrt", "-write_foundation", "--write_ucrt", "--write_foundation",
            // codecs / 壓縮引擎
            "--gzip", "-z", "--bzip2", "-j", "--xz", "-J", "--lzip", "--zstd",
            "--lz4", "--zip", "--zip64",
            // RGB1 fields / RGB1 欄位
            "--width", "--height", "--lat", "--lng", "--height-m", "--title",
            "--country", "--creator-email", "--right", "--created-ms",
            "--tz-offset-min",
            // handled before this point, listed so they never trip the check
            // 於此之前已處理，列出以免誤判
            "-test", "-debug", "--version", "--crypto-selftest",
        ]
        // The LZFSE flag names are compiled in only when the engine is. Listing
        // them unconditionally put the literal "other3" into the --no-lzfse
        // binary, which test_no_lzfse.zsh checks for with `strings`: the public
        // build is meant to carry no trace of the private engine, and the option
        // table is a trace. Rejecting them there is also the right behaviour --
        // that build genuinely cannot do it, so accepting the flag and ignoring
        // it would be the silent-mismatch this whole check exists to stop.
        // LZFSE 的旗標名稱僅在該引擎被編入時才一併編入。先前無條件列出，會使字串
        // 「other3」出現在 --no-lzfse 的執行檔中，而 test_no_lzfse.zsh 正是以 `strings`
        // 檢查此事：公開版本不應留下私有引擎的任何痕跡，而選項表就是一種痕跡。在該版本
        // 拒絕這些旗標也是正確行為——它確實做不到，接受後忽略正是本檢查要杜絕的靜默不符。
        #if !EXCLUDE_LZFSE
        let lzfseOptions: Set<String> = [
            "--other3-fast", "--other3-optimal", "--bvx3-fast", "--bvx3-optimal",
        ]
        #else
        let lzfseOptions: Set<String> = []
        #endif

        // positional file args (skip flags and their values) / 位置參數（略過旗標與其值）
        // Every option that consumes the argument after it. One list, because the
        // check below inspects anything starting with "-" and a value that is
        // missing from here is examined as if it were an option: with the RGB1
        // fields absent, `--lat -33.8688` reported "unknown option -33.8688".
        // Positive values hid it -- 25.033 does not start with a dash -- so the
        // gap only surfaced for southern latitudes, western longitudes and the
        // other negative-valued fields.
        // 所有會消耗其後一個參數的選項，集中為單一清單。因為下方的檢查會檢視任何以 "-"
        // 開頭的詞元，而未列於此的值就會被當成選項檢查：先前缺少 RGB1 各欄位時，
        // `--lat -33.8688` 會回報「unknown option -33.8688」。正值掩蓋了這個缺口——
        // 25.033 並不以減號開頭——故它只在南半球緯度、西經等負值欄位上現形。
        let valueOptions: Set<String> = [
            "-f", "-C", "-n", "--keyfile", "--strip-components", "--zstd-level",
            "--width", "--height", "--lat", "--lng", "--height-m",
            "--title", "--country", "--creator-email", "--right",
            "--created-ms", "--tz-offset-min",
        ]

        var files: [String] = []
        var skipNext = true   // args[0] is the binary path / args[0] 是執行檔路徑
        // POSIX end-of-options. Without it there is no way to name a file whose
        // name begins with "-" other than by spelling it "./-name", which works
        // but which nobody thinks of first: the conventional escape is "--", every
        // other tar has it, and swift_tar answered "unknown option --". A leading
        // dash is not an exotic filename -- browsers, extractors and report
        // generators all produce them.
        // POSIX 的選項結束標記。若無此支援，要指名以 "-" 開頭的檔案就只剩 "./-name"
        // 這種寫法；它確實可行，但沒有人會先想到：慣用的逃生口是 "--"，其他 tar 都
        // 有，而 swift_tar 回答的是「unknown option --」。開頭是減號並非罕見檔名——
        // 瀏覽器、解壓工具與報表產生器都會產出這種名稱。
        var endOfOptions = false
        for a in args {
            if skipNext { skipNext = false; continue }
            if endOfOptions { files.append(a); continue }
            if a == "--" { endOfOptions = true; continue }
            if valueOptions.contains(a) { skipNext = true; continue }
            if a.hasPrefix("-") {
                // "-" alone is the stdin/stdout archive path, not an option.
                // 單獨的 "-" 是代表 stdin/stdout 的封存路徑，並非選項。
                if a == "-" { files.append(a); continue }
                // A long option may carry its value inline as --opt=value, so
                // validate the name alone -- otherwise --strip-components=1 is
                // rejected while --strip-components 1 is accepted.
                // 長選項可用 --opt=value 夾帶其值，故僅驗證名稱部分——否則
                // --strip-components=1 會被拒絕，而 --strip-components 1 卻可通過。
                let name = a.hasPrefix("--") ? String(a.prefix(while: { $0 != "=" })) : a
                guard knownOptions.contains(name) || lzfseOptions.contains(name) else {
                    eprint("swift_tar: unknown option \(a) / 無法辨識的選項 \(a)")
                    eprint("  run swift_tar -h for the full list / 執行 swift_tar -h 可列出完整選項")
                    exit(1)
                }
                continue
            }
            files.append(a)
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
                            throw RGB1Error.badText("tz_offset_min",
                                "must be a whole number of minutes between "
                                + "\(Int16.min) and \(Int16.max), and '\(timezoneRaw)' is not",
                                "必須是介於 \(Int16.min) 與 \(Int16.max) 之間的整數分鐘數，"
                                + "而 '\(timezoneRaw)' 不是")
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

        // Read a flag's value in either spelling: `--flag value` or
        // `--flag=value`. Validation accepts the inline form by comparing only
        // the name before "=", so every reader has to understand it too --
        // when they did not, `--zstd-level=19` was silently ignored (the
        // archive came out byte-identical to the default) and `--keyfile=PATH`
        // fell through to the interactive prompt and hung an unattended run
        // with no archive to show for it. Declared here rather than further
        // down because the codec block below needs it.
        // 以兩種寫法讀取旗標的值：`--flag value` 或 `--flag=value`。驗證層只比對
        // "=" 之前的名稱，因而接受內聯形式，故每個讀值端都必須同樣認得它——
        // 當它們不認得時，`--zstd-level=19` 會被靜默忽略（產出的封存與預設完全
        // 相同），而 `--keyfile=PATH` 會落到互動式提示並讓無人值守的執行卡死，
        // 且毫無產出。宣告於此而非更下方，因為下方的 codec 區塊需要它。
        func optValue(_ flag: String) -> String? {
            if let i = args.firstIndex(of: flag), i + 1 < args.count { return args[i + 1] }
            let prefix = flag + "="
            return args.first(where: { $0.hasPrefix(prefix) }).map { String($0.dropFirst(prefix.count)) }
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
        if args.contains(where: { $0 == "--zstd-level" || $0.hasPrefix("--zstd-level=") }) {
            guard let raw = optValue("--zstd-level"), let lv = Int32(raw) else {
                FileHandle.standardError.write(Data("swift_tar: --zstd-level needs a number / --zstd-level 需要一個數字\n".utf8))
                exit(1)
            }
            let maxLv = ZSTD_maxCLevel()
            guard lv >= 1 && lv <= maxLv else {
                FileHandle.standardError.write(Data("swift_tar: --zstd-level must be 1...\(maxLv) / --zstd-level 必須介於 1 至 \(maxLv)\n".utf8))
                exit(1)
            }
            zstdCompressionLevel = lv
        }
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

        // -stream-in / -stream-out name the archive's stream ends. They are
        // spelled out rather than -si / -so because GNU tar has a real -s
        // (--same-order), so `-so` there parses as -s -o and `-si` as -s -i:
        // a GNU tar command using either would silently mean something else
        // here. bsdtar has no -s, so only the Linux side collides -- which is
        // reason enough, that being tar's main implementation there.
        // 使用完整字樣而非 -si / -so，因為 GNU tar 有真正的 -s（--same-order），
        // 在該處 `-so` 會被解析為 -s -o、`-si` 為 -s -i：使用其一的 GNU tar 指令
        // 在此會靜默地表示另一件事。bsdtar 無 -s，故只有 Linux 側衝突——而那正是
        // 該平台的主流 tar 實作，已足以構成理由。
        let wantStdin  = args.contains("-stream-in")
        // -O and --to-stdout are how bsdtar and GNU tar spell this; accepting
        // them means a command written for either tool does here what it says.
        // -O 與 --to-stdout 是 bsdtar 與 GNU tar 的寫法；接受它們，為那兩個工具
        // 所寫的指令在此才會如其字面所述地運作。
        let stdoutAlias = args.contains("-O") || args.contains("--to-stdout")
        let wantStdout = args.contains("-stream-out") || stdoutAlias
        let toStdout   = wantStdout && args.contains("-x")
        // -i keeps reading past the end-of-archive marker; -o is accepted for
        // tar compatibility and is already this tool's behaviour, since extract
        // never restores ownership on any platform.
        // -i 會越過封存結尾標記繼續讀取；-o 為相容 tar 而接受，且本工具本就如此，
        // 因為解出時在任何平台都不還原擁有者。
        let ignoreZeros = args.contains("-i") || args.contains("--ignore-zeros")
        // -O / --to-stdout say where the *output* goes, not where the archive
        // comes from, so unlike -so they leave -f alone.
        // -O / --to-stdout 指的是「輸出」去向，而非封存來源，故不像 -so 那樣影響 -f。
        // -so names where the *output* goes, and what that is depends on the
        // operation: creating, the output is the archive, so -so means -f -;
        // extracting, the output is the members' contents, so the archive still
        // comes from -f. Treating -so as -f - in both cases made `-x -so -f a`
        // read an empty stdin and emit nothing.
        // -so 指的是「輸出」去向，而輸出是什麼取決於操作：建立時輸出是封存，故
        // -so 等同 -f -；解出時輸出是成員內容，封存仍來自 -f。若兩種情況都把 -so
        // 當成 -f -，`-x -so -f a` 會去讀空的 stdin 而毫無輸出。
        let archiveFromStream = wantStdin || (args.contains("-stream-out") && !args.contains("-x"))
        let archivePath = archiveFromStream ? "-" : (optValue("-f") ?? "-")
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

        // In-flight chunk budget. One per core, not two: measured on a 4P+6E M4,
        // -n 20 beat -n 10 by 2.7% on the RGB1 bench, which is inside the noise,
        // while doubling the peak memory held by in-flight chunks. The gain from
        // oversubscription flattens once every core has work.
        // 在途分塊數。每核一個而非兩個：於 4P+6E 的 M4 上實測，-n 20 相對 -n 10
        // 僅快 2.7%（在雜訊範圍內），卻使在途分塊佔用的峰值記憶體加倍。核心都有
        // 工作之後，過度訂閱帶來的收益即趨於平坦。
        let inflightN: Int = {
            let cores = max(1, ProcessInfo.processInfo.activeProcessorCount)
            var n = cores
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
            guard let raw = optValue("--strip-components") else {
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

        do {
            if doCreate {
                if explicitZip || forceZip64 {
                    // The ZIP backend writes through libarchive straight to the
                    // archive file; it never passes through the sink that the
                    // encryption layer wraps. So --encrypt and --keyfile were
                    // accepted here and had no effect whatsoever: the command
                    // exited 0 and produced an ordinary ZIP that any unzip reads
                    // without a key. That is precisely the outcome the design
                    // exists to prevent -- "refuse to write an archive it cannot
                    // key rather than silently leave it unencrypted" -- so the
                    // combination has to fail loudly until the ZIP writer can be
                    // routed through the encrypting sink. Refusing is safe;
                    // accepting silently is not.
                    // ZIP 後端經由 libarchive 直接寫入封存檔，完全不會通過加密層所
                    // 包覆的 sink。因此 --encrypt 與 --keyfile 在此被接受卻毫無作用：
                    // 指令以 0 結束，產出的是任何 unzip 都能無金鑰讀取的普通 ZIP。
                    // 這正是本設計要防止的結果——「寧可拒絕，也不默默寫出未加密的
                    // 封存」——故在 ZIP writer 能夠改走加密 sink 之前，此組合必須大聲
                    // 失敗。拒絕是安全的，默默接受不是。
                    if tarEncryptionSecret != nil || args.contains("--encrypt") {
                        eprint("Error: --encrypt is not supported for ZIP output; the ZIP backend cannot be encrypted. Use a tar codec (e.g. --zstd) instead. / 錯誤：ZIP 輸出不支援 --encrypt，ZIP 後端無法加密。請改用 tar 壓縮引擎（例如 --zstd）。")
                        exit(1)
                    }
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
                                stripComponents: stripComponents,
                                toStdout: toStdout, ignoreZeros: ignoreZeros,
                                force: args.contains("--force"))
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
                        stripComponents: Int = 0,
                        toStdout: Bool = false,
                        ignoreZeros: Bool = false,
                        force: Bool = false) throws {
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
                                        restoreMtime: restoreMtime,
                                        toStdout: toStdout,
                                        ignoreZeros: ignoreZeros,
                                        force: force)
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
