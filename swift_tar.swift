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
// =====================================================================

import Foundation
import zlib

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

// =================================================================
// MARK: - libzstd API (silgen; homebrew zstd)
// MARK: - libzstd API（silgen；homebrew zstd）
// =================================================================

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

// =================================================================
// MARK: - Codec selection (write side) / 壓縮引擎選擇（寫入端）
// =================================================================

enum TarCodec {
    case none                       // plain tar / 純 tar
    case other3(optimal: Bool)      // standard bvx2 blocks / 標準 bvx2 區塊
    case bvx3(optimal: Bool)        // private big-alphabet blocks / 私有大字母表區塊
    case gzip                       // zlib, gzip members / gzip 成員
    case bzip2                      // libbz2 streams / bzip2 串流
    case xz                         // liblzma xz streams / xz 串流
    case zstd                       // libzstd frames / zstd frame
    case lz4                        // liblz4 standard frames / 標準 LZ4 frame

    var isLZFSEFamily: Bool {
        switch self { case .other3, .bvx3: return true; default: return false }
    }

    /// Compress one chunk into an independent, self-contained unit.
    /// All non-LZFSE outputs are standard concatenatable streams.
    /// 將一個分塊壓成獨立自足的單元；非 LZFSE 輸出皆為可串接的標準串流。
    func compressChunk(_ chunk: Data) -> Data? {
        switch self {
        case .none:
            return chunk
        case .other3(let opt):
            return LZFSEv1.compressBody(chunk, strong: true, optimal3: opt)
        case .bvx3(let opt):
            return LZFSEv1.compressBody(chunk, strong: true, bvx3: true, optimal: opt)
        case .gzip:
            return gzipCompressMember(chunk)
        case .bzip2:
            return bzip2CompressStream(chunk)
        case .xz:
            return xzCompressStream(chunk)
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
}

/// One complete xz stream per chunk (xz multi-stream concatenation).
/// 每分塊一個完整 xz 串流（xz 多串流串接）。
func xzCompressStream(_ input: Data, preset: UInt32 = 6) -> Data? {
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
    let bound = LZ4F_compressFrameBound(input.count, nil)
    var out = Data(count: bound)
    let n: Int = input.withUnsafeBytes { src in
        out.withUnsafeMutableBytes { dst in
            LZ4F_compressFrame(dst.baseAddress!, bound, src.baseAddress!, input.count, nil)
        }
    }
    guard LZ4F_isError(n) == 0 else { return nil }
    return out.prefix(n)
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
    var outBuf = [UInt8](repeating: 0, count: 1 << 20)
    var atBoundary = true
    let reader = ByteReader(input, prefix: prefix)
    while var inBuf = reader.readSome(1 << 20).map({ [UInt8]($0) }) {
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
        if !ok { return false }
    }
    return atBoundary
}

/// Sequential multi-stream bzip2 decode (pbzip2-style concatenation).
/// 循序解多串流 bzip2（pbzip2 式串接）。
func bzip2DecodeStream(input: FileHandle, prefix: Data, output: FileHandle) -> Bool {
    var strm = BZStream()
    guard withUnsafeMutablePointer(to: &strm, { BZ2_bzDecompressInit($0, 0, 0) }) == BZ_OK
    else { return false }
    var open = true
    defer { if open { _ = withUnsafeMutablePointer(to: &strm) { BZ2_bzDecompressEnd($0) } } }
    var outBuf = [UInt8](repeating: 0, count: 1 << 20)
    var atBoundary = true
    let reader = ByteReader(input, prefix: prefix)
    while var inBuf = reader.readSome(1 << 20).map({ [UInt8]($0) }) {
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
}

/// liblzma-family decode: .xz / .lzma (alone) / .lz (lzip).
/// liblzma 家族解碼：.xz／.lzma（alone）／.lz（lzip）。
enum LZMAKind { case xz, alone, lzip }
func lzmaDecodeStream(kind: LZMAKind, input: FileHandle, prefix: Data, output: FileHandle) -> Bool {
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
    var outBuf = [UInt8](repeating: 0, count: 1 << 20)
    var ended = false
    let reader = ByteReader(input, prefix: prefix)
    var pending: [UInt8]? = reader.readSome(1 << 20).map { [UInt8]($0) }
    while let inBuf = pending {
        let next = reader.readSome(1 << 20).map { [UInt8]($0) }
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
}

/// zstd streaming decode (handles back-to-back frames).
/// zstd 串流解碼（自動處理背靠背 frame）。
func zstdDecodeStream(input: FileHandle, prefix: Data, output: FileHandle) -> Bool {
    guard let zds = ZSTD_createDStream() else { return false }
    defer { _ = ZSTD_freeDStream(zds) }
    var outBuf = [UInt8](repeating: 0, count: 1 << 20)
    var lastRet = 0
    let reader = ByteReader(input, prefix: prefix)
    while let chunk = reader.readSome(1 << 20).map({ [UInt8]($0) }) {
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
    var ctx: OpaquePointer? = nil
    guard LZ4F_isError(LZ4F_createDecompressionContext(&ctx, LZ4F_VERSION)) == 0 else { return false }
    defer { _ = LZ4F_freeDecompressionContext(ctx) }
    var outBuf = [UInt8](repeating: 0, count: 1 << 20)
    var lastHint = 0
    let reader = ByteReader(input, prefix: prefix)
    while let chunk = reader.readSome(1 << 20).map({ [UInt8]($0) }) {
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
    var outBuf = Data(); outBuf.reserveCapacity(1 << 20)

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
            if outBuf.count >= (1 << 20) { if !flushOut() { return false } }
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
    while let part = reader.readSome(1 << 20) {
        if (try? output.write(contentsOf: part)) == nil { return false }
    }
    return true
}

// =================================================================
// MARK: - Filter sniffing & chain (libarchive bidder model)
// MARK: - Filter 嗅探與鏈式解包（仿 libarchive bidder 機制）
// =================================================================

enum ReadFilter {
    case gzip, bzip2, xz, lzmaAlone, lzip, lz4, zstd, compressLZW, uu, rpm, lzfse, lzop

    var name: String {
        switch self {
        case .gzip: return "gzip";        case .bzip2: return "bzip2"
        case .xz: return "xz";            case .lzmaAlone: return "lzma"
        case .lzip: return "lzip";        case .lz4: return "lz4"
        case .zstd: return "zstd";        case .compressLZW: return "compress (.Z)"
        case .uu: return "uudecode";      case .rpm: return "rpm"
        case .lzfse: return "lzfse";      case .lzop: return "lzop"
        }
    }
}

/// Magic-based detection over the first 16 bytes. / 依前 16 位元組 magic 偵測。
func sniffFilter(_ head: [UInt8]) -> ReadFilter? {
    let b = head + [UInt8](repeating: 0, count: max(0, 16 - head.count))
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
    if b[0] == UInt8(ascii: "b") && b[1] == UInt8(ascii: "v") && b[2] == UInt8(ascii: "x") { return .lzfse }
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
    let pipe = Pipe()
    let w = pipe.fileHandleForWriting
    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
        let ok: Bool
        switch filter {
        case .gzip:        ok = gzipDecodeStream(input: input, prefix: head, output: w)
        case .bzip2:       ok = bzip2DecodeStream(input: input, prefix: head, output: w)
        case .xz:          ok = lzmaDecodeStream(kind: .xz, input: input, prefix: head, output: w)
        case .lzmaAlone:   ok = lzmaDecodeStream(kind: .alone, input: input, prefix: head, output: w)
        case .lzip:        ok = lzmaDecodeStream(kind: .lzip, input: input, prefix: head, output: w)
        case .lz4:         ok = lz4DecodeStream(input: input, prefix: head, output: w)
        case .zstd:        ok = zstdDecodeStream(input: input, prefix: head, output: w)
        case .compressLZW: ok = lzwDecodeStream(input: input, prefix: head, output: w)
        case .uu:          ok = uuDecodeStream(input: input, prefix: head, output: w)
        case .rpm:         ok = rpmUnwrapStream(input: input, prefix: head, output: w)
        case .lzfse:
            // Top layer + real file → multi-core chunk-parallel file decoder.
            // 最外層且輸入為檔案 → 多核心分塊平行檔案解碼。
            if depth == 0, let p = filePath, p != "-" {
                switch LZFSEv1.decodeStreamFromFile(path: p, chunkRaw: LZFSEv1.parallelChunkSize,
                                                    inflight: inflight, output: w) {
                case .ok:       ok = true
                case .error:    ok = false
                case .fallback: ok = wholeBufferLZFSEDecode(input: input, head: head,
                                                            filePath: p, inflight: inflight, output: w)
                }
            } else {
                ok = wholeBufferLZFSEDecode(input: input, head: head, filePath: nil,
                                            inflight: inflight, output: w)
            }
        case .lzop:
            ok = false
        }
        if !ok { result.fail("\(filter.name) decode failed / \(filter.name) 解碼失敗") }
        try? w.close()
        group.leave()
    }
    return resolveFilterChain(input: pipe.fileHandleForReading, prefix: Data(),
                              filePath: nil, inflight: inflight, group: group,
                              result: result, depth: depth + 1, names: names + [filter.name])
}

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
        while let part = try? fh.read(upToCount: 1 << 20), !part.isEmpty {
            src.append(contentsOf: part)
        }
    } else {
        src = [UInt8](head)
        while let part = try? input.read(upToCount: 1 << 20), !part.isEmpty {
            src.append(contentsOf: part)
        }
    }
    return LZFSEv1.decodeStreamToHandle(src, parallel: true,
                                        chunkRaw: LZFSEv1.parallelChunkSize,
                                        inflight: inflight, output: output)
}

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
         chunkSize: Int = LZFSEv1.parallelChunkSize) {
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
        buffer.append(data)
        while buffer.count >= chunkSize {
            let chunk = Data(buffer.prefix(chunkSize))
            buffer.removeFirst(chunkSize)
            dispatch(chunk)
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
// MARK: - Tar writer (ustar + pax) / Tar 寫入端（ustar + pax）
// =================================================================

final class TarWriter {
    private let sink: ParallelChunkSink
    private let verbose: Bool
    /// Hardlink tracking: (dev, ino) → archived name, for st_nlink > 1 files.
    /// 硬連結追蹤：(dev, ino) → 已入檔名稱，用於 st_nlink > 1 的檔案。
    private var seenInodes: [String: String] = [:]

    init(sink: ParallelChunkSink, verbose: Bool) {
        self.sink = sink
        self.verbose = verbose
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

    /// Archive-internal name: strip leading "/" and "./".
    /// 檔內名稱：去除開頭的 "/" 與 "./"。
    private static func archiveName(_ path: String) -> String {
        var p = path
        while p.hasPrefix("/") { p.removeFirst() }
        while p.hasPrefix("./") && p.count > 2 { p.removeFirst(2) }
        return p
    }

    func add(path: String) throws {
        var st = stat()
        guard lstat(path, &st) == 0 else {
            throw TarError.io("cannot stat '\(path)' / 無法讀取 '\(path)' 的檔案資訊")
        }
        let name = TarWriter.archiveName(path)
        let mode = UInt32(st.st_mode & 0o7777)
        let uid = UInt32(st.st_uid), gid = UInt32(st.st_gid)
        let mtime = UInt64(max(0, st.st_mtimespec.tv_sec))

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
                let want = Int(min(remaining, UInt64(LZFSEv1.parallelChunkSize)))
                guard let part = try fh.read(upToCount: want), !part.isEmpty else {
                    throw TarError.io("short read on '\(path)' / 讀取 '\(path)' 時提前結束")
                }
                try sink.write(part)
                remaining -= UInt64(part.count)
            }
            let rem = Int(size % UInt64(TAR_BLOCK))
            if rem != 0 { try sink.write(Data(count: TAR_BLOCK - rem)) }
        default:
            eprint("swift_tar: skipping special file '\(path)' / 略過特殊檔案 '\(path)'")
        }
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

    init(input: FileHandle, prefix: Data = Data()) {
        self.input = input
        self.pending = prefix
    }

    private func readExactly(_ n: Int) -> Data? {
        while pending.count < n {
            guard let part = try? input.read(upToCount: max(n - pending.count, 1 << 16)),
                  !part.isEmpty else { return nil }
            pending.append(part)
        }
        let out = pending.prefix(n)
        pending.removeFirst(n)
        return Data(out)
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

    struct Options {
        var extract: Bool          // false = list only / false 表僅列出
        var destDir: String        // -C target / -C 目的地
        var verbose: Bool
    }

    func run(options: Options) throws {
        var zeroBlocks = 0
        var paxPath: String? = nil, paxLink: String? = nil, paxSize: UInt64? = nil
        var gnuLongName: String? = nil, gnuLongLink: String? = nil
        // Deferred directory mtimes (children would bump them) / 目錄 mtime 延後套用
        var dirTimes: [(path: String, mtime: UInt64)] = []
        let fm = FileManager.default

        func skipData(_ size: UInt64) throws {
            var remaining = Int((size + UInt64(TAR_BLOCK) - 1) / UInt64(TAR_BLOCK)) * TAR_BLOCK
            while remaining > 0 {
                let n = min(remaining, 1 << 20)
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
            if options.verbose || !options.extract {
                print(options.extract ? "x \(name)" : name)
            }

            guard options.extract else {
                if typeflag == UInt8(ascii: "0") || typeflag == 0 || typeflag == UInt8(ascii: "7") {
                    try skipData(size)
                }
                continue
            }

            guard let rel = TarReader.safeRelativePath(name), !rel.isEmpty else {
                eprint("swift_tar: skipping unsafe path '\(name)' / 略過不安全路徑 '\(name)'")
                if !isDir { try skipData(size) }
                continue
            }
            let dest = options.destDir.isEmpty ? rel : options.destDir + "/" + rel
            let parent = (dest as NSString).deletingLastPathComponent
            if !parent.isEmpty {
                try? fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
            }

            switch typeflag {
            case UInt8(ascii: "5"):
                try? fm.createDirectory(atPath: dest, withIntermediateDirectories: true)
                chmod(dest, mode_t(mode))
                dirTimes.append((dest, mtime))
            case UInt8(ascii: "2"):
                try? fm.removeItem(atPath: dest)
                if symlink(linkname, dest) != 0 {
                    throw TarError.io("symlink failed for '\(dest)' / 建立符號連結失敗")
                }
            case UInt8(ascii: "1"):
                let target = options.destDir.isEmpty ? linkname : options.destDir + "/" + linkname
                try? fm.removeItem(atPath: dest)
                if link(target, dest) != 0 {
                    throw TarError.io("hardlink failed for '\(dest)' / 建立硬連結失敗")
                }
            case UInt8(ascii: "0"), 0, UInt8(ascii: "7"):
                if isDir {   // some writers mark dirs with '0' + trailing "/" / 某些工具以 '0'+尾斜線表目錄
                    try? fm.createDirectory(atPath: dest, withIntermediateDirectories: true)
                    dirTimes.append((dest, mtime))
                    continue
                }
                fm.createFile(atPath: dest, contents: nil)
                guard let out = FileHandle(forWritingAtPath: dest) else {
                    throw TarError.io("cannot create '\(dest)' / 無法建立 '\(dest)'")
                }
                var remaining = size
                while remaining > 0 {
                    let n = Int(min(remaining, UInt64(1 << 20)))
                    guard let part = readExactly(n) else {
                        throw TarError.format("truncated file data / 檔案資料不完整")
                    }
                    try out.write(contentsOf: part)
                    remaining -= UInt64(n)
                }
                try? out.close()
                let rem = Int(size % UInt64(TAR_BLOCK))
                if rem != 0 { _ = readExactly(TAR_BLOCK - rem) }
                chmod(dest, mode_t(mode))
                try? fm.setAttributes([.modificationDate:
                    Date(timeIntervalSince1970: TimeInterval(mtime))], ofItemAtPath: dest)
            default:
                eprint("swift_tar: skipping type '\(Character(UnicodeScalar(typeflag)))' entry '\(name)' / 略過未支援型別")
                try skipData(size)
            }
        }

        // Drain remainder so upstream decoder threads can finish cleanly.
        // 把殘餘輸入讀完，讓上游解碼執行緒能正常收尾。
        while let part = try? input.read(upToCount: 1 << 20), !part.isEmpty { _ = part }

        // Directory mtimes last, deepest first / 目錄 mtime 最後套用、先深後淺
        for (path, mtime) in dirTimes.sorted(by: { $0.path.count > $1.path.count }) {
            try? fm.setAttributes([.modificationDate:
                Date(timeIntervalSince1970: TimeInterval(mtime))], ofItemAtPath: path)
        }
    }
}

// =================================================================
// MARK: - CLI / 命令列介面
// =================================================================

private func printTarUsage() {
    print("""
    Usage: swift_tar -c|-x|-t|--cat [-f <archive>] [codec] [-C <dir>] [-n N] [-v] [files...]

    Commands:
      -c              : Create an archive / 建立封存檔
      -x              : Extract an archive / 解出封存檔
      -t              : List archive contents / 列出封存內容
      --cat           : Decompress filter chain only, raw payload to stdout
                        (bsdcat equivalent; use for RPM payloads etc.)
                        僅解壓 filter 鏈、原始內容輸出至 stdout（等同 bsdcat；
                        RPM payload 等非 tar 內容可用此模式取出）

    Codec (create only; reading auto-detects, see below):
    壓縮引擎（僅建立時指定；讀取自動偵測，見下）:
      --other3-fast    : LZFSE other3, multi-core (standard bvx2, Apple-decodable)
                         等同 lzfse -algo other3 / 多核心，輸出標準 bvx2
      --other3-optimal : other3 + optimal parsing (= lzfse -algo other3 -optimal3)
                         other3 + 最優解析（DP），仍是標準 bvx2
      --bvx3-fast      : Private bvx3 blocks, multi-core (= lzfse -algo bvx3)
                         私有 bvx3 區塊／多核心（僅本工具可解）
      --bvx3-optimal   : bvx3 + optimal parsing (= lzfse -algo bvx3 -optimal)
                         bvx3 + 最優解析（壓縮率最高、最慢）
      --gzip, -z       : zlib, one gzip member per 4MiB chunk (pigz-style .tar.gz)
                         每 4MiB 分塊一個 gzip 成員（pigz 式標準 .tar.gz）
      --bzip2, -j      : libbz2, one stream per chunk (pbzip2-style .tar.bz2)
                         每分塊一個 bzip2 串流（pbzip2 式標準 .tar.bz2）
      --xz, -J         : liblzma, one xz stream per chunk (xz multi-stream)
                         每分塊一個 xz 串流（標準 xz 多串流）
      --zstd           : libzstd, one frame per chunk / 每分塊一個 zstd frame
      --lz4            : liblz4 standard frames / 標準 LZ4 frame
      (none)           : Plain uncompressed tar / 不壓縮的純 tar

    Read filters (auto-detected by magic, stackable like libarchive):
    讀取端 filter（依 magic 自動偵測，可如 libarchive 疊層）:
      uuencoded files (uu & base64)  / uuencode（uu 與 base64 變體）
      files with RPM wrapper         / RPM 外包裝（payload 通常為 cpio，用 --cat）
      gzip, bzip2, compress/LZW, lzma, lzip, xz, lz4, zstandard,
      LZFSE family (bvx2/bvx3 multi-core parallel decode)
      lzop: detected, needs liblzo2 (not bundled) / lzop：可偵測，需另裝 liblzo2

    Options:
      -f <path>       : Archive file ("-" = stdin/stdout; default "-")
                        封存檔路徑（"-" 表標準輸入／輸出；預設 "-"）
      -C <dir>        : Extract into <dir> / 解出至 <dir>
      -n <N>          : In-flight parallel chunks (default 2×cores)
                        平行在途分塊數（預設 2×核心數）
      -v              : Verbose / 顯示處理中的項目
      -h              : Show this help / 顯示說明

    Notes / 注意:
      - Multi-core model is identical to lzfse2's runParallelEncode: 4MiB chunks
        compressed concurrently, written in order. All standard codecs emit
        concatenatable streams, so stock tools decode the output directly.
        多核心模式與 lzfse2 的 runParallelEncode 相同：4MiB 分塊併發壓縮、按序
        寫出；標準引擎輸出皆可串接，原生工具可直接解開。
      - C libraries are used the way libarchive uses them: zlib/libbz2/liblzma/
        libzstd/liblz4 provide the primitives; framing is assembled here.
        compress/LZW, uu and RPM are pure-Swift ports of libarchive filters.
        C 庫用法仿 libarchive：僅取壓縮原語，框架自組；LZW/uu/RPM 為純 Swift 移植。
    """)
}

@main
struct SwiftTarMain {
    static func main() {
        signal(SIGPIPE, SIG_IGN)
        let args = CommandLine.arguments
        if args.contains("-h") || args.count < 2 {
            printTarUsage()
            exit(args.count < 2 ? 1 : 0)
        }

        let doCreate = args.contains("-c")
        let doExtract = args.contains("-x")
        let doList = args.contains("-t")
        let doCat = args.contains("--cat")
        guard [doCreate, doExtract, doList, doCat].filter({ $0 }).count == 1 else {
            eprint("Error: specify exactly one of -c, -x, -t, --cat. / 錯誤：請指定 -c、-x、-t、--cat 其中之一。")
            exit(1)
        }

        // codec flags / 壓縮引擎旗標
        var codec: TarCodec = .none
        var codecCount = 0
        if args.contains("--other3-fast")    { codec = .other3(optimal: false); codecCount += 1 }
        if args.contains("--other3-optimal") { codec = .other3(optimal: true);  codecCount += 1 }
        if args.contains("--bvx3-fast")      { codec = .bvx3(optimal: false);   codecCount += 1 }
        if args.contains("--bvx3-optimal")   { codec = .bvx3(optimal: true);    codecCount += 1 }
        if args.contains("--gzip") || args.contains("-z")  { codec = .gzip;  codecCount += 1 }
        if args.contains("--bzip2") || args.contains("-j") { codec = .bzip2; codecCount += 1 }
        if args.contains("--xz") || args.contains("-J")    { codec = .xz;    codecCount += 1 }
        if args.contains("--zstd")           { codec = .zstd;                  codecCount += 1 }
        if args.contains("--lz4")            { codec = .lz4;                   codecCount += 1 }
        guard codecCount <= 1 else {
            eprint("Error: at most one codec flag. / 錯誤：壓縮引擎旗標至多一個。")
            exit(1)
        }
        if codecCount > 0 && !doCreate {
            eprint("Note: codec flags only affect -c; reading auto-detects. / 提示：引擎旗標僅影響 -c，讀取自動偵測。")
        }

        let verbose = args.contains("-v")

        func optValue(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        let archivePath = optValue("-f") ?? "-"
        let destDir = optValue("-C") ?? ""

        // in-flight chunk budget, same policy as lzfse CLI / 在途分塊數，政策同 lzfse CLI
        let inflightN: Int = {
            let cores = max(1, ProcessInfo.processInfo.activeProcessorCount)
            var n = cores * 2
            if let v = optValue("-n").flatMap(Int.init) { n = v }
            return min(max(1, n), cores * 4)
        }()

        // positional file args (skip flags and their values) / 位置參數（略過旗標與其值）
        var files: [String] = []
        var skipNext = true   // args[0] is the binary path / args[0] 是執行檔路徑
        for a in args {
            if skipNext { skipNext = false; continue }
            if a == "-f" || a == "-C" || a == "-n" { skipNext = true; continue }
            if a.hasPrefix("-") { continue }
            files.append(a)
        }

        do {
            if doCreate {
                try runCreate(archivePath: archivePath, files: files, codec: codec,
                              inflight: inflightN, verbose: verbose)
            } else if doCat {
                try runCat(archivePath: archivePath, inflight: inflightN, verbose: verbose)
            } else {
                try runRead(archivePath: archivePath, extract: doExtract,
                            destDir: destDir, inflight: inflightN, verbose: verbose)
            }
        } catch {
            eprint("swift_tar: \(error.localizedDescription)")
            exit(1)
        }
    }

    // ---- create / 建立 ----

    static func runCreate(archivePath: String, files: [String], codec: TarCodec,
                          inflight: Int, verbose: Bool) throws {
        guard !files.isEmpty else {
            throw TarError.io("no files to archive / 未指定要打包的檔案")
        }
        let output: FileHandle
        if archivePath == "-" {
            output = .standardOutput
        } else {
            FileManager.default.createFile(atPath: archivePath, contents: nil)
            guard let fh = FileHandle(forWritingAtPath: archivePath) else {
                throw TarError.io("cannot create '\(archivePath)' / 無法建立 '\(archivePath)'")
            }
            output = fh
        }
        defer { if archivePath != "-" { try? output.close() } }

        let sink = ParallelChunkSink(codec: codec, output: output, inflight: inflight)
        let writer = TarWriter(sink: sink, verbose: verbose)
        for f in files {
            try writer.add(path: f)
        }
        try writer.finish()
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
                        inflight: Int, verbose: Bool) throws {
        let input = try openInput(archivePath)
        defer { if archivePath != "-" { try? input.close() } }

        let group = DispatchGroup()
        let result = ChainResult()
        let stream = resolveFilterChain(input: input, prefix: Data(),
                                        filePath: archivePath, inflight: inflight,
                                        group: group, result: result)
        if verbose && !stream.names.isEmpty {
            eprint("swift_tar: filter chain: \(stream.names.joined(separator: " → ")) / 已套用 filter 鏈")
        }
        guard result.ok else {
            throw TarError.io(result.message ?? "filter chain failed / filter 鏈失敗")
        }
        let options = TarReader.Options(extract: extract, destDir: destDir, verbose: verbose)
        try TarReader(input: stream.handle, prefix: stream.prefix).run(options: options)
        group.wait()
        guard result.ok else {
            throw TarError.io(result.message ?? "decompression failed / 解壓失敗")
        }
    }

    // ---- cat (bsdcat equivalent) / cat 模式（等同 bsdcat）----

    static func runCat(archivePath: String, inflight: Int, verbose: Bool) throws {
        let input = try openInput(archivePath)
        defer { if archivePath != "-" { try? input.close() } }

        let group = DispatchGroup()
        let result = ChainResult()
        let stream = resolveFilterChain(input: input, prefix: Data(),
                                        filePath: archivePath, inflight: inflight,
                                        group: group, result: result)
        if verbose && !stream.names.isEmpty {
            eprint("swift_tar: filter chain: \(stream.names.joined(separator: " → ")) / 已套用 filter 鏈")
        }
        guard result.ok else {
            throw TarError.io(result.message ?? "filter chain failed / filter 鏈失敗")
        }
        let out = FileHandle.standardOutput
        if !stream.prefix.isEmpty { try out.write(contentsOf: stream.prefix) }
        while let part = try? stream.handle.read(upToCount: 1 << 20), !part.isEmpty {
            try out.write(contentsOf: part)
        }
        group.wait()
        guard result.ok else {
            throw TarError.io(result.message ?? "decompression failed / 解壓失敗")
        }
    }
}
