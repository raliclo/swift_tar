// =====================================================================
//  crypto.swift — self-contained crypto primitives for swift_tar
//  crypto.swift — swift_tar 自足密碼學原語
//
//  Compiled together with swift_tar.swift, see ./compile_tar.sh /
//  compile_tar-win.bat. Depends only on Foundation: no CryptoKit, no
//  OpenSSL, so the same code builds on macOS, Linux and Windows and is
//  present in both the full and the --no-lzfse public build.
//  與 swift_tar.swift 一起編譯，見 ./compile_tar.sh / compile_tar-win.bat。
//  僅依賴 Foundation：不用 CryptoKit、不用 OpenSSL，因此 macOS、Linux 與
//  Windows 共用同一份程式碼，全功能版與 --no-lzfse 公開版皆包含。
//
//  Contents / 內容：
//    - ChaCha20 (RFC 8439 §2.3) and Poly1305 (§2.5)
//    - ChaCha20-Poly1305 AEAD (§2.8)
//    - SHA-256, HMAC-SHA256, PBKDF2-HMAC-SHA256 (RFC 2898)
//    - Salsa20/8 core and scrypt (RFC 7914)
//
//  These are textbook implementations validated against the official test
//  vectors (see cryptoSelfTest()). They are constant-time with respect to
//  the key in the operations that matter (no key-dependent branching or
//  table lookups), but no attempt is made to defeat a local attacker who
//  can observe memory.
//  以上為教科書式實作，並以官方測試向量驗證（見 cryptoSelfTest()）。關鍵運算
//  不含依金鑰而異的分支或查表，但不防禦可觀察本機記憶體的攻擊者。
// =====================================================================

import Foundation

// ---------------------------------------------------------------------
// MARK: - ChaCha20 (RFC 8439 §2.3)
// ---------------------------------------------------------------------

enum ChaCha20 {
    /// The 64-byte keystream block for `counter`. / `counter` 對應的 64-byte keystream 區塊。
    static func block(key: [UInt8], nonce: [UInt8], counter: UInt32) -> [UInt8] {
        precondition(key.count == 32 && nonce.count == 12)
        // "expand 32-byte k" / 常數 "expand 32-byte k"
        var s: [UInt32] = [0x6170_7865, 0x3320_646e, 0x7962_2d32, 0x6b20_6574]
        for i in 0..<8 { s.append(le32(key, i * 4)) }
        s.append(counter)
        for i in 0..<3 { s.append(le32(nonce, i * 4)) }

        var w = s
        for _ in 0..<10 {                      // 10 double rounds = 20 rounds
            qr(&w, 0, 4,  8, 12); qr(&w, 1, 5,  9, 13)
            qr(&w, 2, 6, 10, 14); qr(&w, 3, 7, 11, 15)
            qr(&w, 0, 5, 10, 15); qr(&w, 1, 6, 11, 12)
            qr(&w, 2, 7,  8, 13); qr(&w, 3, 4,  9, 14)
        }
        var out = [UInt8](repeating: 0, count: 64)
        for i in 0..<16 {
            let v = w[i] &+ s[i]
            out[i * 4]     = UInt8(v & 0xff)
            out[i * 4 + 1] = UInt8((v >> 8) & 0xff)
            out[i * 4 + 2] = UInt8((v >> 16) & 0xff)
            out[i * 4 + 3] = UInt8((v >> 24) & 0xff)
        }
        return out
    }

    /// XOR `data` with the keystream starting at `counter`. / 以 `counter` 起始的 keystream XOR `data`。
    static func xor(_ data: [UInt8], key: [UInt8], nonce: [UInt8], counter: UInt32) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: data.count)
        var offset = 0
        var block = counter
        while offset < data.count {
            let ks = Self.block(key: key, nonce: nonce, counter: block)
            let n = min(64, data.count - offset)
            for i in 0..<n { out[offset + i] = data[offset + i] ^ ks[i] }
            offset += n
            block &+= 1
        }
        return out
    }

    private static func qr(_ x: inout [UInt32], _ a: Int, _ b: Int, _ c: Int, _ d: Int) {
        x[a] = x[a] &+ x[b]; x[d] ^= x[a]; x[d] = rotl(x[d], 16)
        x[c] = x[c] &+ x[d]; x[b] ^= x[c]; x[b] = rotl(x[b], 12)
        x[a] = x[a] &+ x[b]; x[d] ^= x[a]; x[d] = rotl(x[d], 8)
        x[c] = x[c] &+ x[d]; x[b] ^= x[c]; x[b] = rotl(x[b], 7)
    }
    private static func rotl(_ v: UInt32, _ n: UInt32) -> UInt32 { (v << n) | (v >> (32 - n)) }
    private static func le32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | (UInt32(b[i + 1]) << 8) | (UInt32(b[i + 2]) << 16) | (UInt32(b[i + 3]) << 24)
    }
}

// ---------------------------------------------------------------------
// MARK: - Poly1305 (RFC 8439 §2.5)
// ---------------------------------------------------------------------

/// One-time authenticator over a 32-byte key (r ‖ s). 130-bit arithmetic is
/// carried in five 26-bit limbs. / 以 32-byte 金鑰（r ‖ s）計算的一次性驗證碼；
/// 130-bit 運算以五個 26-bit limb 承載。
struct Poly1305 {
    private var r = [UInt32](repeating: 0, count: 5)
    private var h = [UInt32](repeating: 0, count: 5)
    private var pad = [UInt32](repeating: 0, count: 4)
    private var leftover: [UInt8] = []

    init(key: [UInt8]) {
        precondition(key.count == 32)
        // clamp r / 依規範遮罩 r
        let t0 = le32(key, 0), t1 = le32(key, 4), t2 = le32(key, 8), t3 = le32(key, 12)
        r[0] = t0 & 0x3ff_ffff
        r[1] = ((t0 >> 26) | (t1 << 6)) & 0x3ff_ff03
        r[2] = ((t1 >> 20) | (t2 << 12)) & 0x3ff_c0ff
        r[3] = ((t2 >> 14) | (t3 << 18)) & 0x3f0_3fff
        r[4] = (t3 >> 8) & 0x00f_ffff
        for i in 0..<4 { pad[i] = le32(key, 16 + i * 4) }
    }

    mutating func update(_ data: [UInt8]) {
        var input = leftover + data
        leftover = []
        let full = (input.count / 16) * 16
        var i = 0
        while i < full { blocks(Array(input[i..<(i + 16)]), final: false); i += 16 }
        if i < input.count { leftover = Array(input[i...]) }
        input = []
    }

    mutating func finish() -> [UInt8] {
        if !leftover.isEmpty {
            var b = leftover
            b.append(1)
            while b.count < 16 { b.append(0) }
            blocks(b, final: true)
        }
        // full carry / 完整進位
        var c: UInt32 = 0
        for i in 1..<5 { h[i] &+= c; c = h[i] >> 26; h[i] &= 0x3ff_ffff }
        h[0] &+= c &* 5; c = h[0] >> 26; h[0] &= 0x3ff_ffff; h[1] &+= c

        // compute h + -p, select if no borrow / 計算 h + -p，無借位則採用
        var g = [UInt32](repeating: 0, count: 5)
        c = 5
        for i in 0..<5 { let s = h[i] &+ c; c = s >> 26; g[i] = s & 0x3ff_ffff }
        g[4] = g[4] &- (1 << 26)
        let mask: UInt32 = (g[4] >> 31) &- 1     // 0xffffffff if h >= p
        for i in 0..<5 { h[i] = (h[i] & ~mask) | (g[i] & mask) }

        // serialize h + pad / 序列化 h + pad
        var f: UInt64 = 0
        var out = [UInt8](repeating: 0, count: 16)
        let words: [UInt32] = [
            (h[0] | (h[1] << 26)) & 0xffff_ffff,
            ((h[1] >> 6) | (h[2] << 20)) & 0xffff_ffff,
            ((h[2] >> 12) | (h[3] << 14)) & 0xffff_ffff,
            ((h[3] >> 18) | (h[4] << 8)) & 0xffff_ffff,
        ]
        for i in 0..<4 {
            f = UInt64(words[i]) &+ UInt64(pad[i]) &+ (f >> 32)
            let v = UInt32(truncatingIfNeeded: f)
            out[i * 4]     = UInt8(v & 0xff)
            out[i * 4 + 1] = UInt8((v >> 8) & 0xff)
            out[i * 4 + 2] = UInt8((v >> 16) & 0xff)
            out[i * 4 + 3] = UInt8((v >> 24) & 0xff)
        }
        return out
    }

    private mutating func blocks(_ b: [UInt8], final: Bool) {
        let hibit: UInt32 = final ? 0 : (1 << 24)
        let t0 = le32(b, 0), t1 = le32(b, 4), t2 = le32(b, 8), t3 = le32(b, 12)
        h[0] &+= t0 & 0x3ff_ffff
        h[1] &+= ((t0 >> 26) | (t1 << 6)) & 0x3ff_ffff
        h[2] &+= ((t1 >> 20) | (t2 << 12)) & 0x3ff_ffff
        h[3] &+= ((t2 >> 14) | (t3 << 18)) & 0x3ff_ffff
        h[4] &+= (t3 >> 8) | hibit

        // h *= r mod 2^130-5. Terms that wrap past limb 4 fold back multiplied
        // by 5, since 2^130 ≡ 5 (mod 2^130-5).
        // h 乘 r 後模 2^130-5：超出 limb 4 的項乘 5 折回，因 2^130 ≡ 5 (mod 2^130-5)。
        let s1 = r[1] &* 5, s2 = r[2] &* 5, s3 = r[3] &* 5, s4 = r[4] &* 5
        let h0 = UInt64(h[0]), h1 = UInt64(h[1]), h2 = UInt64(h[2])
        let h3 = UInt64(h[3]), h4 = UInt64(h[4])
        let d: [UInt64] = [
            h0 &* UInt64(r[0]) &+ h1 &* UInt64(s4) &+ h2 &* UInt64(s3) &+ h3 &* UInt64(s2) &+ h4 &* UInt64(s1),
            h0 &* UInt64(r[1]) &+ h1 &* UInt64(r[0]) &+ h2 &* UInt64(s4) &+ h3 &* UInt64(s3) &+ h4 &* UInt64(s2),
            h0 &* UInt64(r[2]) &+ h1 &* UInt64(r[1]) &+ h2 &* UInt64(r[0]) &+ h3 &* UInt64(s4) &+ h4 &* UInt64(s3),
            h0 &* UInt64(r[3]) &+ h1 &* UInt64(r[2]) &+ h2 &* UInt64(r[1]) &+ h3 &* UInt64(r[0]) &+ h4 &* UInt64(s4),
            h0 &* UInt64(r[4]) &+ h1 &* UInt64(r[3]) &+ h2 &* UInt64(r[2]) &+ h3 &* UInt64(r[1]) &+ h4 &* UInt64(r[0]),
        ]
        var c: UInt64 = 0
        for i in 0..<5 { let v = d[i] &+ c; h[i] = UInt32(v & 0x3ff_ffff); c = v >> 26 }
        h[0] &+= UInt32(c &* 5); c = UInt64(h[0] >> 26); h[0] &= 0x3ff_ffff
        h[1] &+= UInt32(c)
    }

    private func le32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | (UInt32(b[i + 1]) << 8) | (UInt32(b[i + 2]) << 16) | (UInt32(b[i + 3]) << 24)
    }

    /// Constant-time comparison of two tags. / 兩個 tag 的定時比較。
    static func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }
}

// ---------------------------------------------------------------------
// MARK: - ChaCha20-Poly1305 AEAD (RFC 8439 §2.8)
// ---------------------------------------------------------------------

enum ChaChaPoly {
    static let keySize = 32, nonceSize = 12, tagSize = 16

    static func seal(plaintext: [UInt8], key: [UInt8], nonce: [UInt8], aad: [UInt8]) -> (ciphertext: [UInt8], tag: [UInt8]) {
        let ciphertext = ChaCha20.xor(plaintext, key: key, nonce: nonce, counter: 1)
        return (ciphertext, tag(ciphertext: ciphertext, key: key, nonce: nonce, aad: aad))
    }

    /// Returns nil when the tag does not verify. / tag 驗證失敗時回傳 nil。
    static func open(ciphertext: [UInt8], tag expected: [UInt8], key: [UInt8], nonce: [UInt8], aad: [UInt8]) -> [UInt8]? {
        let actual = tag(ciphertext: ciphertext, key: key, nonce: nonce, aad: aad)
        guard Poly1305.constantTimeEqual(actual, expected) else { return nil }
        return ChaCha20.xor(ciphertext, key: key, nonce: nonce, counter: 1)
    }

    private static func tag(ciphertext: [UInt8], key: [UInt8], nonce: [UInt8], aad: [UInt8]) -> [UInt8] {
        let polyKey = Array(ChaCha20.block(key: key, nonce: nonce, counter: 0)[0..<32])
        var mac = Poly1305(key: polyKey)
        mac.update(aad)
        mac.update([UInt8](repeating: 0, count: (16 - aad.count % 16) % 16))
        mac.update(ciphertext)
        mac.update([UInt8](repeating: 0, count: (16 - ciphertext.count % 16) % 16))
        mac.update(le64(UInt64(aad.count)) + le64(UInt64(ciphertext.count)))
        return mac.finish()
    }

    private static func le64(_ v: UInt64) -> [UInt8] {
        (0..<8).map { UInt8((v >> (8 * UInt64($0))) & 0xff) }
    }
}

// ---------------------------------------------------------------------
// MARK: - SHA-256 / HMAC / PBKDF2 (FIPS 180-4, RFC 2104, RFC 2898)
// ---------------------------------------------------------------------

struct SHA256 {
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    static func hash(_ message: [UInt8]) -> [UInt8] {
        var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                           0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        var m = message
        let bitLen = UInt64(message.count) * 8
        m.append(0x80)
        while m.count % 64 != 56 { m.append(0) }
        for i in (0..<8).reversed() { m.append(UInt8((bitLen >> (8 * UInt64(i))) & 0xff)) }

        var w = [UInt32](repeating: 0, count: 64)
        var block = 0
        while block < m.count {
            for i in 0..<16 {
                let o = block + i * 4
                w[i] = (UInt32(m[o]) << 24) | (UInt32(m[o + 1]) << 16) | (UInt32(m[o + 2]) << 8) | UInt32(m[o + 3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var a = h[0], b = h[1], c = h[2], d = h[3]
            var e = h[4], f = h[5], g = h[6], hh = h[7]
            for i in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = s0 &+ maj
                hh = g; g = f; f = e; e = d &+ t1
                d = c; c = b; b = a; a = t1 &+ t2
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
            h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
            block += 64
        }
        var out = [UInt8]()
        for v in h { for i in (0..<4).reversed() { out.append(UInt8((v >> (8 * UInt32(i))) & 0xff)) } }
        return out
    }

    private static func rotr(_ v: UInt32, _ n: UInt32) -> UInt32 { (v >> n) | (v << (32 - n)) }
}

enum HMACSHA256 {
    static func authenticate(_ message: [UInt8], key: [UInt8]) -> [UInt8] {
        var k = key.count > 64 ? SHA256.hash(key) : key
        while k.count < 64 { k.append(0) }
        let opad = k.map { $0 ^ 0x5c }, ipad = k.map { $0 ^ 0x36 }
        return SHA256.hash(opad + SHA256.hash(ipad + message))
    }
}

enum PBKDF2 {
    /// PBKDF2-HMAC-SHA256. / PBKDF2-HMAC-SHA256。
    static func derive(password: [UInt8], salt: [UInt8], iterations: Int, length: Int) -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(length)
        var index: UInt32 = 1
        while out.count < length {
            let idx: [UInt8] = [UInt8((index >> 24) & 0xff), UInt8((index >> 16) & 0xff),
                                UInt8((index >> 8) & 0xff), UInt8(index & 0xff)]
            var u = HMACSHA256.authenticate(salt + idx, key: password)
            var t = u
            if iterations > 1 {
                for _ in 1..<iterations {
                    u = HMACSHA256.authenticate(u, key: password)
                    for i in 0..<t.count { t[i] ^= u[i] }
                }
            }
            out.append(contentsOf: t)
            index &+= 1
        }
        return Array(out[0..<length])
    }
}

// ---------------------------------------------------------------------
// MARK: - scrypt (RFC 7914)
// ---------------------------------------------------------------------

enum Scrypt {
    /// Memory-hard KDF. `n` must be a power of two. / 記憶體硬化 KDF；`n` 須為 2 的冪。
    static func derive(password: [UInt8], salt: [UInt8], n: Int, r: Int, p: Int, length: Int) -> [UInt8] {
        let blockBytes = 128 * r
        var b = PBKDF2.derive(password: password, salt: salt, iterations: 1, length: p * blockBytes)
        for i in 0..<p {
            var block = Array(b[(i * blockBytes)..<((i + 1) * blockBytes)])
            romix(&block, n: n, r: r)
            b.replaceSubrange((i * blockBytes)..<((i + 1) * blockBytes), with: block)
        }
        return PBKDF2.derive(password: password, salt: b, iterations: 1, length: length)
    }

    private static func romix(_ block: inout [UInt8], n: Int, r: Int) {
        let blockBytes = 128 * r
        var v = [[UInt8]](); v.reserveCapacity(n)
        var x = block
        for _ in 0..<n { v.append(x); blockMix(&x, r: r) }
        for _ in 0..<n {
            // j = integerify(x) mod n — the last 64-byte block's first word
            let offset = blockBytes - 64
            let j = Int(UInt32(x[offset]) | (UInt32(x[offset + 1]) << 8)
                        | (UInt32(x[offset + 2]) << 16) | (UInt32(x[offset + 3]) << 24)) & (n - 1)
            for i in 0..<blockBytes { x[i] ^= v[j][i] }
            blockMix(&x, r: r)
        }
        block = x
    }

    private static func blockMix(_ block: inout [UInt8], r: Int) {
        var x = Array(block[(128 * r - 64)..<(128 * r)])
        var out = [UInt8](repeating: 0, count: 128 * r)
        for i in 0..<(2 * r) {
            for j in 0..<64 { x[j] ^= block[i * 64 + j] }
            salsa20_8(&x)
            // even blocks to the first half, odd to the second / 偶數塊放前半、奇數塊放後半
            let dest = (i % 2 == 0) ? (i / 2) * 64 : (r + i / 2) * 64
            out.replaceSubrange(dest..<(dest + 64), with: x)
        }
        block = out
    }

    private static func salsa20_8(_ b: inout [UInt8]) {
        var x = [UInt32](repeating: 0, count: 16)
        for i in 0..<16 {
            x[i] = UInt32(b[i * 4]) | (UInt32(b[i * 4 + 1]) << 8)
                 | (UInt32(b[i * 4 + 2]) << 16) | (UInt32(b[i * 4 + 3]) << 24)
        }
        let input = x
        for _ in 0..<4 {                       // 4 double rounds = 8 rounds
            x[4]  ^= rotl(x[0]  &+ x[12], 7);  x[8]  ^= rotl(x[4]  &+ x[0],  9)
            x[12] ^= rotl(x[8]  &+ x[4], 13);  x[0]  ^= rotl(x[12] &+ x[8], 18)
            x[9]  ^= rotl(x[5]  &+ x[1],  7);  x[13] ^= rotl(x[9]  &+ x[5],  9)
            x[1]  ^= rotl(x[13] &+ x[9], 13);  x[5]  ^= rotl(x[1]  &+ x[13], 18)
            x[14] ^= rotl(x[10] &+ x[6],  7);  x[2]  ^= rotl(x[14] &+ x[10], 9)
            x[6]  ^= rotl(x[2]  &+ x[14], 13); x[10] ^= rotl(x[6]  &+ x[2], 18)
            x[3]  ^= rotl(x[15] &+ x[11], 7);  x[7]  ^= rotl(x[3]  &+ x[15], 9)
            x[11] ^= rotl(x[7]  &+ x[3], 13);  x[15] ^= rotl(x[11] &+ x[7], 18)
            x[1]  ^= rotl(x[0]  &+ x[3],  7);  x[2]  ^= rotl(x[1]  &+ x[0],  9)
            x[3]  ^= rotl(x[2]  &+ x[1], 13);  x[0]  ^= rotl(x[3]  &+ x[2], 18)
            x[6]  ^= rotl(x[5]  &+ x[4],  7);  x[7]  ^= rotl(x[6]  &+ x[5],  9)
            x[4]  ^= rotl(x[7]  &+ x[6], 13);  x[5]  ^= rotl(x[4]  &+ x[7], 18)
            x[11] ^= rotl(x[10] &+ x[9],  7);  x[8]  ^= rotl(x[11] &+ x[10], 9)
            x[9]  ^= rotl(x[8]  &+ x[11], 13); x[10] ^= rotl(x[9]  &+ x[8], 18)
            x[12] ^= rotl(x[15] &+ x[14], 7);  x[13] ^= rotl(x[12] &+ x[15], 9)
            x[14] ^= rotl(x[13] &+ x[12], 13); x[15] ^= rotl(x[14] &+ x[13], 18)
        }
        for i in 0..<16 {
            let v = x[i] &+ input[i]
            b[i * 4]     = UInt8(v & 0xff)
            b[i * 4 + 1] = UInt8((v >> 8) & 0xff)
            b[i * 4 + 2] = UInt8((v >> 16) & 0xff)
            b[i * 4 + 3] = UInt8((v >> 24) & 0xff)
        }
    }

    private static func rotl(_ v: UInt32, _ n: UInt32) -> UInt32 { (v << n) | (v >> (32 - n)) }
}

// ---------------------------------------------------------------------
// MARK: - Random bytes / 亂數位元組
// ---------------------------------------------------------------------

/// Cryptographically secure random bytes from the system CSPRNG.
/// 取自系統 CSPRNG 的密碼學安全亂數。
func cryptoRandomBytes(_ count: Int) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: count)
    for i in 0..<count { out[i] = UInt8.random(in: 0...255, using: &systemRandom) }
    return out
}
private var systemRandom = SystemRandomNumberGenerator()

// ---------------------------------------------------------------------
// MARK: - Encrypted container / 加密容器
//
// The encryption layer sits OUTSIDE the compression codec: swift_tar builds
// the tar stream, the codec compresses it, and this layer encrypts the result.
// On read the magic is detected first, the stream is decrypted, and the plain
// filter chain then runs on the decrypted bytes — so any codec (including
// plain tar) can be encrypted, and `gzip → tar` still auto-detects inside.
// 加密層位於壓縮 codec 之外：swift_tar 產生 tar 串流，codec 壓縮，本層再加密
// 結果。讀取時先偵測 magic、解密，解密後的位元組再走原本的 filter 鏈——因此
// 任何 codec（含純 tar）都能加密，內層的 `gzip → tar` 仍會自動偵測。
//
// Layout / 佈局:
//   header 48B: magic8 | ver1 | kdf1 | logN1 | r1 | p1 | rsv3 | salt16
//               | nonceSeed8 | chunkSize4(BE) | rsv4
//   chunk:      len4(BE) | flags1 | ciphertext[len] | tag16
//   AAD:        header ‖ chunkIndex4(BE) ‖ flags1
//   nonce:      nonceSeed8 ‖ chunkIndex4(BE)
//
// Binding the whole header into every chunk's AAD makes the KDF parameters and
// salt tamper-evident; including the chunk index stops reordering, and the
// trailing final-marker chunk makes truncation detectable.
// 將整個 header 納入每個 chunk 的 AAD，使 KDF 參數與 salt 一經竄改即被發現；
// 納入 chunk 索引可阻止重排；結尾的 final marker chunk 讓截斷可被偵測。
// ---------------------------------------------------------------------

enum TarCryptoError: LocalizedError {
    case badMagic
    case unsupportedVersion(UInt8)
    case badHeader(String)
    case authenticationFailed(Int)
    case truncated
    case io(String)

    var errorDescription: String? {
        switch self {
        case .badMagic:
            return "not a swift_tar encrypted archive / 不是 swift_tar 加密封存"
        case .unsupportedVersion(let v):
            return "unsupported encryption version \(v) / 不支援的加密版本 \(v)"
        case .badHeader(let why):
            return "bad encryption header: \(why) / 加密標頭無效：\(why)"
        case .authenticationFailed(let i):
            return "authentication failed on chunk \(i) — wrong key or corrupted/tampered data"
                 + " / 第 \(i) 區塊驗證失敗——金鑰錯誤或資料損毀／遭竄改"
        case .truncated:
            return "archive is truncated (final marker missing) / 封存被截斷（缺少結尾標記）"
        case .io(let m): return m
        }
    }
}

enum TarCrypto {
    static let magic: [UInt8] = Array("SWTARC01".utf8)
    static let headerSize = 48
    static let version: UInt8 = 1
    static let kdfScrypt: UInt8 = 1
    static let kdfRawKeyfile: UInt8 = 2
    static let chunkSize = 1 << 22          // 4 MiB, matching the tar chunking

    // Interactive-grade scrypt cost: N=2^15, r=8, p=1 (~32 MiB, ~100 ms).
    // 互動等級 scrypt 成本：N=2^15、r=8、p=1（約 32 MiB、約 100 ms）。
    static let defaultLogN: UInt8 = 15
    static let defaultR: UInt8 = 8
    static let defaultP: UInt8 = 1

    struct Header {
        var kdf: UInt8
        var logN: UInt8, r: UInt8, p: UInt8
        var salt: [UInt8]          // 16
        var nonceSeed: [UInt8]     // 8
        var chunkSize: UInt32

        var bytes: [UInt8] {
            var h = magic
            h += [version, kdf, logN, r, p, 0, 0, 0]
            h += salt
            h += nonceSeed
            h += [UInt8((chunkSize >> 24) & 0xff), UInt8((chunkSize >> 16) & 0xff),
                  UInt8((chunkSize >> 8) & 0xff), UInt8(chunkSize & 0xff)]
            h += [0, 0, 0, 0]
            return h
        }

        static func parse(_ b: [UInt8]) throws -> Header {
            guard b.count >= headerSize else { throw TarCryptoError.badHeader("short") }
            guard Array(b[0..<8]) == magic else { throw TarCryptoError.badMagic }
            guard b[8] == version else { throw TarCryptoError.unsupportedVersion(b[8]) }
            let kdf = b[9]
            guard kdf == kdfScrypt || kdf == kdfRawKeyfile else {
                throw TarCryptoError.badHeader("unknown kdf \(kdf)")
            }
            let logN = b[10], r = b[11], p = b[12]
            if kdf == kdfScrypt {
                // Bound the cost so a hostile header cannot force a huge allocation.
                // 限制成本，避免惡意標頭迫使程式配置巨量記憶體。
                guard logN >= 10 && logN <= 22 else { throw TarCryptoError.badHeader("logN \(logN) out of range") }
                guard r >= 1 && r <= 32 && p >= 1 && p <= 16 else {
                    throw TarCryptoError.badHeader("scrypt r/p out of range")
                }
            }
            let cs = (UInt32(b[40]) << 24) | (UInt32(b[41]) << 16) | (UInt32(b[42]) << 8) | UInt32(b[43])
            guard cs >= 1024 && cs <= (1 << 26) else { throw TarCryptoError.badHeader("chunk size \(cs)") }
            return Header(kdf: kdf, logN: logN, r: r, p: p,
                          salt: Array(b[16..<32]), nonceSeed: Array(b[32..<40]), chunkSize: cs)
        }
    }

    /// The 32-byte content key. A keyfile is used as raw key material (hashed to
    /// 32 bytes); a passphrase goes through scrypt with the header's parameters.
    /// 32-byte 內容金鑰。keyfile 直接作為金鑰材料（雜湊成 32 bytes）；passphrase
    /// 則以標頭參數走 scrypt。
    static func contentKey(secret: KeySecret, header: Header) -> [UInt8] {
        switch secret {
        case .keyfile(let material):
            return SHA256.hash(Array("swift_tar keyfile v1".utf8) + header.salt + material)
        case .passphrase(let phrase):
            return Scrypt.derive(password: Array(phrase.utf8), salt: header.salt,
                                 n: 1 << Int(header.logN), r: Int(header.r), p: Int(header.p),
                                 length: 32)
        }
    }

    enum KeySecret {
        case passphrase(String)
        case keyfile([UInt8])
        var kdfID: UInt8 { if case .keyfile = self { return kdfRawKeyfile }; return kdfScrypt }
    }

    private static func aad(header: [UInt8], index: UInt32, flags: UInt8) -> [UInt8] {
        header + [UInt8((index >> 24) & 0xff), UInt8((index >> 16) & 0xff),
                  UInt8((index >> 8) & 0xff), UInt8(index & 0xff), flags]
    }
    private static func nonce(seed: [UInt8], index: UInt32) -> [UInt8] {
        seed + [UInt8((index >> 24) & 0xff), UInt8((index >> 16) & 0xff),
                UInt8((index >> 8) & 0xff), UInt8(index & 0xff)]
    }

    /// Encrypt everything readable from `input` to `output`. / 將 `input` 全部加密寫入 `output`。
    static func encryptStream(input: FileHandle, output: FileHandle, secret: KeySecret) throws {
        let header = Header(kdf: secret.kdfID, logN: defaultLogN, r: defaultR, p: defaultP,
                            salt: cryptoRandomBytes(16), nonceSeed: cryptoRandomBytes(8),
                            chunkSize: UInt32(chunkSize))
        let hb = header.bytes
        let key = contentKey(secret: secret, header: header)
        try output.write(contentsOf: Data(hb))

        var index: UInt32 = 0
        while true {
            guard let part = try input.read(upToCount: chunkSize), !part.isEmpty else { break }
            try writeChunk(Array(part), index: index, final: false, key: key, header: hb,
                           seed: header.nonceSeed, output: output)
            index &+= 1
        }
        // final marker: empty chunk that authenticates the end of the stream
        // 結尾標記：驗證串流結束的空 chunk
        try writeChunk([], index: index, final: true, key: key, header: hb,
                       seed: header.nonceSeed, output: output)
    }

    private static func writeChunk(_ plain: [UInt8], index: UInt32, final: Bool, key: [UInt8],
                                   header: [UInt8], seed: [UInt8], output: FileHandle) throws {
        let flags: UInt8 = final ? 1 : 0
        let sealed = ChaChaPoly.seal(plaintext: plain, key: key,
                                     nonce: nonce(seed: seed, index: index),
                                     aad: aad(header: header, index: index, flags: flags))
        let n = UInt32(sealed.ciphertext.count)
        var out = [UInt8]([UInt8((n >> 24) & 0xff), UInt8((n >> 16) & 0xff),
                           UInt8((n >> 8) & 0xff), UInt8(n & 0xff), flags])
        out += sealed.ciphertext
        out += sealed.tag
        try output.write(contentsOf: Data(out))
    }

    /// Decrypt `input` (with `prefix` already consumed from it) into `output`.
    /// 解密 `input`（`prefix` 為已自其讀出的前置位元組）並寫入 `output`。
    static func decryptStream(input: FileHandle, prefix: Data, output: FileHandle,
                              secret: KeySecret) throws {
        var buf = [UInt8](prefix)
        func need(_ n: Int) throws -> [UInt8] {
            while buf.count < n {
                guard let more = try input.read(upToCount: max(n - buf.count, 65536)), !more.isEmpty else {
                    throw TarCryptoError.truncated
                }
                buf += [UInt8](more)
            }
            let out = Array(buf[0..<n]); buf.removeFirst(n); return out
        }

        let hb = try need(headerSize)
        let header = try Header.parse(hb)
        let key = contentKey(secret: secret, header: header)

        var index: UInt32 = 0
        while true {
            let head = try need(5)
            let n = Int((UInt32(head[0]) << 24) | (UInt32(head[1]) << 16)
                        | (UInt32(head[2]) << 8) | UInt32(head[3]))
            let flags = head[4]
            guard n <= Int(header.chunkSize) else { throw TarCryptoError.badHeader("chunk length \(n)") }
            let ciphertext = try need(n)
            let tag = try need(ChaChaPoly.tagSize)
            guard let plain = ChaChaPoly.open(ciphertext: ciphertext, tag: tag, key: key,
                                              nonce: nonce(seed: header.nonceSeed, index: index),
                                              aad: aad(header: hb, index: index, flags: flags))
            else { throw TarCryptoError.authenticationFailed(Int(index)) }
            if flags & 1 != 0 { return }        // authenticated end of stream / 已驗證的串流結尾
            if !plain.isEmpty { try output.write(contentsOf: Data(plain)) }
            index &+= 1
        }
    }
}

// ---------------------------------------------------------------------
// MARK: - Passphrase / keyfile input / 密語與 keyfile 輸入
// ---------------------------------------------------------------------

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

enum KeyInput {
    /// Read a line from the terminal with echo disabled, so the passphrase does
    /// not appear on screen and never reaches the shell history. Falls back to a
    /// plain read when stdin is not a TTY (pipelines should use --keyfile).
    /// 以關閉回顯的方式自終端讀取一行，密語不會顯示於畫面，也不會進入 shell
    /// 歷史。stdin 非 TTY 時退回一般讀取（管線請改用 --keyfile）。
    static func promptPassphrase(_ prompt: String, confirm: Bool = false) throws -> String {
        guard isatty(fileno(stdin)) == 1 else {
            throw TarCryptoError.io(
                "stdin is not a terminal — pass the key with --keyfile <path>"
                + " / stdin 不是終端機——請以 --keyfile <path> 提供金鑰")
        }
        let first = try readSecretLine(prompt)
        guard !first.isEmpty else {
            throw TarCryptoError.io("empty passphrase / 密語不可為空")
        }
        if confirm {
            let again = try readSecretLine("Verify passphrase / 再次輸入密語: ")
            guard first == again else {
                throw TarCryptoError.io("passphrases do not match / 兩次輸入的密語不一致")
            }
        }
        return first
    }

    private static func readSecretLine(_ prompt: String) throws -> String {
        FileHandle.standardError.write(Data(prompt.utf8))
        var term = termios(), saved = termios()
        guard tcgetattr(fileno(stdin), &term) == 0 else {
            throw TarCryptoError.io("cannot read terminal settings / 無法讀取終端機設定")
        }
        saved = term
        term.c_lflag &= ~UInt(ECHO)
        _ = tcsetattr(fileno(stdin), TCSAFLUSH, &term)
        defer {
            _ = tcsetattr(fileno(stdin), TCSAFLUSH, &saved)
            FileHandle.standardError.write(Data("\n".utf8))
        }
        guard let line = readLine(strippingNewline: true) else {
            throw TarCryptoError.io("no passphrase supplied / 未輸入密語")
        }
        return line
    }

    /// Key material from a keyfile: the file's raw bytes. / keyfile 的金鑰材料：檔案原始位元組。
    static func keyfileMaterial(path: String) throws -> [UInt8] {
        guard let data = FileManager.default.contents(atPath: path) else {
            throw TarCryptoError.io("cannot read keyfile '\(path)' / 無法讀取 keyfile '\(path)'")
        }
        guard !data.isEmpty else {
            throw TarCryptoError.io("keyfile '\(path)' is empty / keyfile '\(path)' 是空的")
        }
        return [UInt8](data)
    }
}

// ---------------------------------------------------------------------
// MARK: - Self test against the official vectors / 對官方向量的自我測試
// ---------------------------------------------------------------------

private func hexBytes(_ s: String) -> [UInt8] {
    var out = [UInt8](); out.reserveCapacity(s.count / 2)
    var it = s.makeIterator(); var hi: UInt8? = nil
    while let ch = it.next() {
        guard let v = ch.hexDigitValue else { continue }
        if let h = hi { out.append(h << 4 | UInt8(v)); hi = nil } else { hi = UInt8(v) }
    }
    return out
}
private func hexString(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }

/// Runs the published test vectors for every primitive. Returns true when all
/// pass; prints one line per case. Hand-rolled crypto must be checked against
/// the specs' own vectors, so this is wired to `--crypto-selftest`.
/// 執行各原語的公開測試向量，全數通過回傳 true，每案輸出一行。自行實作的密碼學
/// 必須以規範自帶向量驗證，故以 `--crypto-selftest` 提供。
func cryptoSelfTest() -> Bool {
    var pass = 0, fail = 0
    func check(_ name: String, _ got: String, _ want: String) {
        if got == want { pass += 1; print("PASS: \(name)") }
        else { fail += 1; print("FAIL: \(name)\n  got  \(got)\n  want \(want)") }
    }

    // RFC 8439 §2.3.2 — ChaCha20 block function
    check("ChaCha20 block (RFC 8439 2.3.2)",
          hexString(ChaCha20.block(
            key: (0..<32).map { UInt8($0) },
            nonce: hexBytes("000000090000004a00000000"), counter: 1)),
          "10f1e7e4d13b5915500fdd1fa32071c4c7d1f4c733c068030422aa9ac3d46c4e"
          + "d2826446079faa0914c2d705d98b02a2b5129cd1de164eb9cbd083e8a2503c4e")

    // RFC 8439 §2.4.2 — ChaCha20 encryption
    let sunscreen = Array("Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it.".utf8)
    check("ChaCha20 encrypt (RFC 8439 2.4.2)",
          hexString(ChaCha20.xor(sunscreen, key: (0..<32).map { UInt8($0) },
                                 nonce: hexBytes("000000000000004a00000000"), counter: 1)).prefix(64).description,
          "6e2e359a2568f98041ba0728dd0d6981e97e7aec1d4360c20a27afccfd9fae0b")

    // RFC 8439 §2.5.2 — Poly1305
    var mac = Poly1305(key: hexBytes("85d6be7857556d337f4452fe42d506a80103808afb0db2fd4abff6af4149f51b"))
    mac.update(Array("Cryptographic Forum Research Group".utf8))
    check("Poly1305 (RFC 8439 2.5.2)", hexString(mac.finish()), "a8061dc1305136c6c22b8baf0c0127a9")

    // RFC 8439 §2.8.2 — ChaCha20-Poly1305 AEAD
    let aeadPlain = Array("Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it.".utf8)
    let sealed = ChaChaPoly.seal(plaintext: aeadPlain,
                                 key: hexBytes("808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f"),
                                 nonce: hexBytes("070000004041424344454647"),
                                 aad: hexBytes("50515253c0c1c2c3c4c5c6c7"))
    check("ChaCha20-Poly1305 tag (RFC 8439 2.8.2)", hexString(sealed.tag), "1ae10b594f09e26a7e902ecbd0600691")
    // round-trip and rejection of a flipped bit / 往返與位元翻轉須被拒
    let opened = ChaChaPoly.open(ciphertext: sealed.ciphertext, tag: sealed.tag,
                                 key: hexBytes("808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f"),
                                 nonce: hexBytes("070000004041424344454647"),
                                 aad: hexBytes("50515253c0c1c2c3c4c5c6c7"))
    check("ChaCha20-Poly1305 round-trip", opened.map { hexString($0) } ?? "nil", hexString(aeadPlain))
    var tampered = sealed.ciphertext; tampered[0] ^= 1
    check("ChaCha20-Poly1305 rejects tampering",
          ChaChaPoly.open(ciphertext: tampered, tag: sealed.tag,
                          key: hexBytes("808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f"),
                          nonce: hexBytes("070000004041424344454647"),
                          aad: hexBytes("50515253c0c1c2c3c4c5c6c7")) == nil ? "rejected" : "accepted",
          "rejected")

    // FIPS 180-4 — SHA-256
    check("SHA-256(\"abc\")", hexString(SHA256.hash(Array("abc".utf8))),
          "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    check("SHA-256(\"\")", hexString(SHA256.hash([])),
          "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")

    // RFC 4231 §4.2 — HMAC-SHA256
    check("HMAC-SHA256 (RFC 4231 case 2)",
          hexString(HMACSHA256.authenticate(Array("what do ya want for nothing?".utf8), key: Array("Jefe".utf8))),
          "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")

    // PBKDF2-HMAC-SHA256 — scrypt depends on it, so it is checked on its own
    // rather than only through scrypt. / scrypt 以其為基礎，故單獨驗證而非僅間接驗證。
    check("PBKDF2-HMAC-SHA256 (c=1)",
          hexString(PBKDF2.derive(password: Array("password".utf8), salt: Array("salt".utf8),
                                  iterations: 1, length: 32)),
          "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b")
    check("PBKDF2-HMAC-SHA256 (c=4096)",
          hexString(PBKDF2.derive(password: Array("password".utf8), salt: Array("salt".utf8),
                                  iterations: 4096, length: 32)),
          "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a")
    // output longer than one hash block exercises the block-index loop
    // 輸出長於單一雜湊區塊，可涵蓋 block index 迴圈
    check("PBKDF2-HMAC-SHA256 (40-byte output, multi-block)",
          hexString(PBKDF2.derive(password: Array("passwordPASSWORDpassword".utf8),
                                  salt: Array("saltSALTsaltSALTsaltSALTsaltSALTsalt".utf8),
                                  iterations: 4096, length: 40)),
          "348c89dbcbd32b2f32d814b8116e84cf2b17347ebc1800181c4e2a1fb8dd53e1c635518c7dac47e9")

    // Tag comparison must not short-circuit on the first differing byte.
    // tag 比較不得在第一個相異位元組就提前返回。
    check("constantTimeEqual: equal",
          Poly1305.constantTimeEqual([1, 2, 3, 4], [1, 2, 3, 4]) ? "true" : "false", "true")
    check("constantTimeEqual: differs in last byte",
          Poly1305.constantTimeEqual([1, 2, 3, 4], [1, 2, 3, 5]) ? "true" : "false", "false")
    check("constantTimeEqual: length mismatch",
          Poly1305.constantTimeEqual([1, 2, 3], [1, 2, 3, 4]) ? "true" : "false", "false")

    // RFC 7914 §11 — scrypt
    check("scrypt (RFC 7914, N=16 r=1 p=1, empty)",
          hexString(Scrypt.derive(password: [], salt: [], n: 16, r: 1, p: 1, length: 64)),
          "77d6576238657b203b19ca42c18a0497f16b4844e3074ae8dfdffa3fede21442"
          + "fcd0069ded0948f8326a753a0fc81f17e8d3e0fb2e0d3628cf35e20c38d18906")
    check("scrypt (RFC 7914, N=1024 r=8 p=16, \"password\")",
          hexString(Scrypt.derive(password: Array("password".utf8), salt: Array("NaCl".utf8),
                                  n: 1024, r: 8, p: 16, length: 64)),
          "fdbabe1c9d3472007856e7190d01e9fe7c6ad7cbc8237830e77376634b373162"
          + "2eaf30d92e22a3886ff109279d9830dac727afb94a83ee6d8360cbdfa2cc0640")

    // Header parsing rejects malformed and hostile values. A header is attacker
    // -controlled input, so out-of-range KDF costs must not reach the KDF.
    // 標頭解析須拒絕格式錯誤與惡意值。標頭是攻擊者可控輸入，超範圍的 KDF 成本
    // 不得傳到 KDF。
    let goodHeader = TarCrypto.Header(kdf: TarCrypto.kdfScrypt, logN: TarCrypto.defaultLogN,
                                      r: TarCrypto.defaultR, p: TarCrypto.defaultP,
                                      salt: [UInt8](repeating: 7, count: 16),
                                      nonceSeed: [UInt8](repeating: 9, count: 8),
                                      chunkSize: UInt32(TarCrypto.chunkSize))
    func headerRejects(_ name: String, _ mutate: (inout [UInt8]) -> Void) {
        var b = goodHeader.bytes
        mutate(&b)
        do { _ = try TarCrypto.Header.parse(b); check(name, "accepted", "rejected") }
        catch { check(name, "rejected", "rejected") }
    }
    // the unmodified header must parse and survive a round-trip / 未改動的標頭須可解析且往返一致
    do {
        let parsed = try TarCrypto.Header.parse(goodHeader.bytes)
        check("header: round-trip preserves fields",
              "\(parsed.logN),\(parsed.r),\(parsed.p),\(parsed.chunkSize),\(hexString(parsed.salt))",
              "\(goodHeader.logN),\(goodHeader.r),\(goodHeader.p),\(goodHeader.chunkSize),\(hexString(goodHeader.salt))")
    } catch { check("header: round-trip preserves fields", "error", "ok") }
    headerRejects("header: bad magic rejected")            { $0[0] ^= 0xff }
    headerRejects("header: unsupported version rejected")  { $0[8] = 99 }
    headerRejects("header: unknown KDF id rejected")       { $0[9] = 77 }
    headerRejects("header: logN above cap rejected")       { $0[10] = 40 }
    headerRejects("header: logN below floor rejected")     { $0[10] = 2 }
    headerRejects("header: scrypt r=0 rejected")           { $0[11] = 0 }
    headerRejects("header: scrypt p=0 rejected")           { $0[12] = 0 }
    headerRejects("header: oversized chunk size rejected") { $0[40] = 0xff; $0[41] = 0xff; $0[42] = 0xff; $0[43] = 0xff }
    headerRejects("header: short buffer rejected")         { $0.removeLast(8) }

    // Container: round-trip, wrong key, tampering and truncation must all be
    // caught. / 容器：往返，以及錯誤金鑰、竄改與截斷皆須被攔截。
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("swift_tar_crypto_selftest_\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    func containerCase(_ name: String, payload: Data, mutate: ((inout Data) -> Void)? = nil,
                       sealWith: TarCrypto.KeySecret? = nil,
                       openWith: TarCrypto.KeySecret? = nil, expectFailure: Bool = false) {
        let plainURL = tmp.appendingPathComponent("plain.bin")
        let encURL = tmp.appendingPathComponent("enc.bin")
        let outURL = tmp.appendingPathComponent("out.bin")
        try? payload.write(to: plainURL)
        FileManager.default.createFile(atPath: encURL.path, contents: nil)
        let secret = sealWith ?? .passphrase("correct horse battery staple")
        do {
            let inH = try FileHandle(forReadingFrom: plainURL)
            let outH = try FileHandle(forWritingTo: encURL)
            try TarCrypto.encryptStream(input: inH, output: outH, secret: secret)
            try? inH.close(); try? outH.close()
            if let mutate {
                var d = try Data(contentsOf: encURL); mutate(&d); try d.write(to: encURL)
            }
            FileManager.default.createFile(atPath: outURL.path, contents: nil)
            let encH = try FileHandle(forReadingFrom: encURL)
            let dstH = try FileHandle(forWritingTo: outURL)
            try TarCrypto.decryptStream(input: encH, prefix: Data(), output: dstH,
                                        secret: openWith ?? secret)
            try? encH.close(); try? dstH.close()
            let got = (try? Data(contentsOf: outURL)) ?? Data()
            if expectFailure { check(name, "accepted", "rejected") }
            else { check(name, got == payload ? "match" : "differ", "match") }
        } catch {
            check(name, expectFailure ? "rejected" : "error: \(error.localizedDescription)",
                  expectFailure ? "rejected" : "match")
        }
    }

    // 9 MiB exercises multi-chunk (4 MiB chunking) plus a partial final chunk.
    // 9 MiB 可涵蓋多 chunk（4 MiB 切塊）與不足一塊的尾段。
    var big = Data(count: 0); big.reserveCapacity(9 << 20)
    var seed: UInt64 = 0x0123_4567_89ab_cdef
    for _ in 0..<(9 << 20) {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        big.append(UInt8(truncatingIfNeeded: seed >> 33))
    }
    containerCase("container: empty payload round-trip", payload: Data())
    containerCase("container: 9 MiB multi-chunk round-trip", payload: big)
    // Exact chunk boundaries are where off-by-one framing bugs hide: a payload
    // of exactly one chunk must not emit a spurious empty chunk, and chunk±1
    // must split correctly. / 精確的 chunk 邊界最容易藏 off-by-one：恰好一個 chunk
    // 不得多寫出空 chunk，chunk±1 則必須正確切分。
    let cs = TarCrypto.chunkSize
    containerCase("container: 1 byte", payload: Data(big.prefix(1)))
    containerCase("container: exactly one chunk", payload: Data(big.prefix(cs)))
    containerCase("container: one chunk minus 1", payload: Data(big.prefix(cs - 1)))
    containerCase("container: one chunk plus 1", payload: Data(big.prefix(cs + 1)))
    containerCase("container: exactly two chunks", payload: Data(big.prefix(cs * 2)))
    containerCase("container: wrong passphrase rejected", payload: big,
                  openWith: .passphrase("wrong passphrase"), expectFailure: true)
    containerCase("container: flipped ciphertext byte rejected", payload: big,
                  mutate: { $0[TarCrypto.headerSize + 8] ^= 0x01 }, expectFailure: true)
    containerCase("container: tampered header (salt) rejected", payload: big,
                  mutate: { $0[20] ^= 0x01 }, expectFailure: true)
    containerCase("container: truncation rejected", payload: big,
                  mutate: { $0.removeLast(64) }, expectFailure: true)
    // keyfile path: seal and open with the same key material, and confirm a
    // different keyfile fails. / keyfile 路徑：同一金鑰材料封裝與開啟，並確認不同
    // keyfile 會失敗。
    let keyMaterial = cryptoRandomBytes(64)
    containerCase("container: keyfile round-trip", payload: big,
                  sealWith: .keyfile(keyMaterial), openWith: .keyfile(keyMaterial))
    containerCase("container: wrong keyfile rejected", payload: big,
                  sealWith: .keyfile(keyMaterial), openWith: .keyfile(cryptoRandomBytes(64)),
                  expectFailure: true)

    print("-----------------------------------------")
    print("crypto self-test — PASS: \(pass)  FAIL: \(fail)")
    return fail == 0
}
