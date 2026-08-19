// =====================================================================
//  rgb1.swift — RGB1 raw image container / RGB1 原始影像容器
//
//  Compiled together with swift_tar.swift, see ./compile_tar.zsh /
//  compile_tar-win.bat. Self-contained: only depends on Foundation.
//  與 swift_tar.swift 一起編譯，見 ./compile_tar.zsh / compile_tar-win.bat。
//  獨立自足：僅依賴 Foundation。
// =====================================================================

import Foundation

enum RGB1Error: LocalizedError {
    case badDimensions
    case badGeo
    case badMagic
    /// Field name, then why it was rejected, in English and Traditional
    /// Chinese. The reason is carried rather than derived because one `guard`
    /// used to cover four separate causes -- non-ASCII, empty, too long, and a
    /// control character -- and reported all of them as "invalid". Measured:
    /// a CJK title, a title with a curly quote pasted from a word processor, a
    /// 70-byte title and an empty one produced byte-identical messages, so the
    /// only way to find out which rule was broken was to re-read the flag table.
    ///
    /// 欄位名稱，以及遭拒的原因（英文與繁體中文）。原因採「帶入」而非「推導」，是因為
    /// 原本一個 `guard` 涵蓋了四種各自獨立的成因——非 ASCII、空白、過長、控制字元——
    /// 卻一律回報為「無效」。實測：CJK 標題、從文書軟體貼上的彎引號標題、70 位元組的
    /// 標題與空標題，產生的訊息逐位元組相同，因此要知道違反了哪一條規則，只能回頭重讀
    /// 旗標表。
    case badText(String, String, String)
    case shortHeader(Int)
    case payloadSizeMismatch(expected: Int, actual: Int)
    case missingArgument(String)
    case io(String)

    var errorDescription: String? {
        switch self {
        case .badDimensions:
            return "RGB1 width and height must be positive UInt32 values. / RGB1 寬高必須是正 UInt32。"
        case .badGeo:
            return "RGB1 geo fields are out of range. / RGB1 地理欄位超出範圍。"
        case .badMagic:
            return "Not an RGB1 file. / 不是 RGB1 檔案。"
        case .badText(let field, let reasonEN, let reasonZH):
            return "RGB1 text field '\(field)' is invalid: \(reasonEN). / "
                 + "RGB1 文字欄位 '\(field)' 無效：\(reasonZH)。"
        case .shortHeader(let actual):
            return "RGB1 header is incomplete (\(actual) of \(RGB1Image.headerSize) bytes). / RGB1 標頭不完整（\(actual) / \(RGB1Image.headerSize) bytes）。"
        case .payloadSizeMismatch(let expected, let actual):
            return "RGB1 payload size mismatch: expected \(expected), got \(actual). / RGB1 payload 大小不符：預期 \(expected)，實際 \(actual)。"
        case .missingArgument(let name):
            return "Missing RGB1 argument \(name). / 缺少 RGB1 參數 \(name)。"
        case .io(let message):
            return message
        }
    }
}

struct RGB1Image {
    static let magic = Data([0x52, 0x47, 0x42, 0x31]) // "RGB1"
    static let baseHeaderSize = 32
    // Fixed binary header fields: raw ASCII byte arrays, not JSON/XML/CSV.
    // 固定二進位 header 欄位：raw ASCII byte array，不是 JSON/XML/CSV。
    static let titleFieldSize = 64
    static let countryFieldSize = 512
    static let creatorEmailFieldSize = 254
    static let rightFieldSize = 4
    static let createdTimestampFieldSize = 8
    static let timezoneOffsetFieldSize = 2
    static let taiwanTimezoneOffsetMinutes: Int16 = 480
    static let headerSize = baseHeaderSize + titleFieldSize + countryFieldSize
        + creatorEmailFieldSize + rightFieldSize + createdTimestampFieldSize
        + timezoneOffsetFieldSize
    static let bytesPerPixel = 3
    static let geoPresentFlag: UInt32 = 1
    static let wgs84EllipsoidDatum: UInt32 = 1

    let width: UInt32
    let height: UInt32
    let latitudeE7: Int32
    let longitudeE7: Int32
    let heightMillimeters: Int32
    let geoDatumCode: UInt32
    let title: String
    let country: String
    let creatorEmail: String
    let right: String
    let createdUnixMilliseconds: Int64
    let timezoneOffsetMinutes: Int16
    let payload: Data

    init(
        width: UInt32,
        height: UInt32,
        latitudeE7: Int32,
        longitudeE7: Int32,
        heightMillimeters: Int32,
        geoDatumCode: UInt32 = RGB1Image.wgs84EllipsoidDatum,
        title: String,
        country: String,
        creatorEmail: String,
        right: String,
        createdUnixMilliseconds: Int64,
        timezoneOffsetMinutes: Int16 = RGB1Image.taiwanTimezoneOffsetMinutes,
        payload: Data
    ) throws {
        guard width > 0, height > 0 else { throw RGB1Error.badDimensions }
        guard latitudeE7 >= -900_000_000,
              latitudeE7 <= 900_000_000,
              longitudeE7 >= -1_800_000_000,
              longitudeE7 <= 1_800_000_000
        else {
            throw RGB1Error.badGeo
        }
        let expected = try Self.payloadByteCount(width: width, height: height)
        guard payload.count == expected else {
            throw RGB1Error.payloadSizeMismatch(expected: expected, actual: payload.count)
        }
        // `+ 1` because the bound is exclusive and the field takes its full
        // width. Without it these two capped one byte short -- 63 of 64, 511 of
        // 512 -- while creator_email, which already passed fieldSize + 1, used
        // all 254. The reader is `firstIndex(of: 0) ?? endIndex`, so no NUL
        // terminator is required and a completely full field reads back intact;
        // the lost byte bought nothing.
        // 使用 `+ 1`，因為此上界為排他且欄位可用滿其寬度。若無此項，這兩者各少一個
        // 位元組——64 只能用 63、512 只能用 511——而已傳入 fieldSize + 1 的
        // creator_email 則用滿 254。讀取端為 `firstIndex(of: 0) ?? endIndex`，不需
        // NUL 終止符，欄位塞滿亦可完整讀回；那個少掉的位元組什麼也沒換到。
        try Self.validateASCII(title, field: "title", maxBytesExclusive: Self.titleFieldSize + 1)
        try Self.validateASCII(country, field: "country", maxBytesExclusive: Self.countryFieldSize + 1)
        try Self.validateEmail(creatorEmail)
        try Self.validateRight(right)
        self.width = width
        self.height = height
        self.latitudeE7 = latitudeE7
        self.longitudeE7 = longitudeE7
        self.heightMillimeters = heightMillimeters
        self.geoDatumCode = geoDatumCode
        self.title = title
        self.country = country
        self.creatorEmail = creatorEmail
        self.right = right
        self.createdUnixMilliseconds = createdUnixMilliseconds
        self.timezoneOffsetMinutes = timezoneOffsetMinutes
        self.payload = payload
    }

    init(fileData: Data) throws {
        guard fileData.count >= Self.headerSize else {
            throw RGB1Error.shortHeader(fileData.count)
        }
        guard Data(fileData.prefix(4)) == Self.magic else { throw RGB1Error.badMagic }

        let width = Self.readUInt32BE(fileData, offset: 4)
        let height = Self.readUInt32BE(fileData, offset: 8)
        let flags = Self.readUInt32BE(fileData, offset: 12)
        guard flags & Self.geoPresentFlag != 0 else { throw RGB1Error.badGeo }
        let latitudeE7 = Self.readInt32BE(fileData, offset: 16)
        let longitudeE7 = Self.readInt32BE(fileData, offset: 20)
        let heightMillimeters = Self.readInt32BE(fileData, offset: 24)
        let geoDatumCode = Self.readUInt32BE(fileData, offset: 28)
        let title = try Self.readFixedASCII(fileData, offset: 32, size: Self.titleFieldSize)
        let country = try Self.readFixedASCII(
            fileData,
            offset: 32 + Self.titleFieldSize,
            size: Self.countryFieldSize
        )
        let creatorEmail = try Self.readFixedASCII(
            fileData,
            offset: 32 + Self.titleFieldSize + Self.countryFieldSize,
            size: Self.creatorEmailFieldSize
        )
        let right = try Self.readFixedASCII(
            fileData,
            offset: 32 + Self.titleFieldSize + Self.countryFieldSize + Self.creatorEmailFieldSize,
            size: Self.rightFieldSize
        )
        let createdUnixMilliseconds = Self.readInt64BE(
            fileData,
            offset: 32 + Self.titleFieldSize + Self.countryFieldSize
                + Self.creatorEmailFieldSize + Self.rightFieldSize
        )
        let timezoneOffsetMinutes = Self.readInt16BE(
            fileData,
            offset: 32 + Self.titleFieldSize + Self.countryFieldSize
                + Self.creatorEmailFieldSize + Self.rightFieldSize
                + Self.createdTimestampFieldSize
        )
        let payload = fileData.dropFirst(Self.headerSize)
        try self.init(
            width: width,
            height: height,
            latitudeE7: latitudeE7,
            longitudeE7: longitudeE7,
            heightMillimeters: heightMillimeters,
            geoDatumCode: geoDatumCode,
            title: title,
            country: country,
            creatorEmail: creatorEmail,
            right: right,
            createdUnixMilliseconds: createdUnixMilliseconds,
            timezoneOffsetMinutes: timezoneOffsetMinutes,
            payload: Data(payload)
        )
    }

    var fileData: Data {
        var out = Data()
        out.reserveCapacity(Self.headerSize + payload.count)
        out.append(Self.magic)
        Self.appendUInt32BE(width, to: &out)
        Self.appendUInt32BE(height, to: &out)
        Self.appendUInt32BE(Self.geoPresentFlag, to: &out)
        Self.appendInt32BE(latitudeE7, to: &out)
        Self.appendInt32BE(longitudeE7, to: &out)
        Self.appendInt32BE(heightMillimeters, to: &out)
        Self.appendUInt32BE(geoDatumCode, to: &out)
        Self.appendFixedASCII(title, size: Self.titleFieldSize, to: &out)
        Self.appendFixedASCII(country, size: Self.countryFieldSize, to: &out)
        Self.appendFixedASCII(creatorEmail, size: Self.creatorEmailFieldSize, to: &out)
        Self.appendFixedASCII(right, size: Self.rightFieldSize, to: &out)
        Self.appendInt64BE(createdUnixMilliseconds, to: &out)
        Self.appendInt16BE(timezoneOffsetMinutes, to: &out)
        out.append(payload)
        return out
    }

    static func payloadByteCount(width: UInt32, height: UInt32) throws -> Int {
        let pixels = UInt64(width) * UInt64(height)
        let bytes = pixels * UInt64(bytesPerPixel)
        guard bytes <= UInt64(Int.max) else { throw RGB1Error.badDimensions }
        return Int(bytes)
    }

    private static func readUInt32BE(_ data: Data, offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for byte in data[offset..<(offset + 4)] {
            value = (value << 8) | UInt32(byte)
        }
        return value
    }

    private static func readInt32BE(_ data: Data, offset: Int) -> Int32 {
        Int32(bitPattern: readUInt32BE(data, offset: offset))
    }

    private static func readInt16BE(_ data: Data, offset: Int) -> Int16 {
        let hi = UInt16(data[offset])
        let lo = UInt16(data[offset + 1])
        return Int16(bitPattern: (hi << 8) | lo)
    }

    private static func readInt64BE(_ data: Data, offset: Int) -> Int64 {
        var value: UInt64 = 0
        for byte in data[offset..<(offset + 8)] {
            value = (value << 8) | UInt64(byte)
        }
        return Int64(bitPattern: value)
    }

    private static func appendUInt32BE(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8(value & 0xff))
    }

    private static func appendInt32BE(_ value: Int32, to data: inout Data) {
        appendUInt32BE(UInt32(bitPattern: value), to: &data)
    }

    private static func appendInt16BE(_ value: Int16, to data: inout Data) {
        let raw = UInt16(bitPattern: value)
        data.append(UInt8((raw >> 8) & 0xff))
        data.append(UInt8(raw & 0xff))
    }

    private static func appendInt64BE(_ value: Int64, to data: inout Data) {
        let raw = UInt64(bitPattern: value)
        data.append(UInt8((raw >> 56) & 0xff))
        data.append(UInt8((raw >> 48) & 0xff))
        data.append(UInt8((raw >> 40) & 0xff))
        data.append(UInt8((raw >> 32) & 0xff))
        data.append(UInt8((raw >> 24) & 0xff))
        data.append(UInt8((raw >> 16) & 0xff))
        data.append(UInt8((raw >> 8) & 0xff))
        data.append(UInt8(raw & 0xff))
    }

    private static func validateASCII(
        _ value: String,
        field: String,
        maxBytesExclusive: Int
    ) throws {
        // One guard per rule, so the message names the rule that was broken.
        // The curly-quote note is not padding: a title pasted from a word
        // processor carries U+2018/U+2019 or an em dash, which look like ASCII
        // on screen and are the likeliest way an English-speaking user reaches
        // this error at all.
        // 每條規則各一個 guard，訊息才能指出被違反的是哪一條。彎引號那句不是湊字數：
        // 從文書軟體貼上的標題會帶有 U+2018/U+2019 或破折號，它們在畫面上看起來就是
        // ASCII，而那正是英文使用者最可能碰到此錯誤的途徑。
        guard let bytes = value.data(using: .ascii) else {
            throw RGB1Error.badText(field,
                "must be ASCII, and this contains a character that is not "
                + "(a curly quote or dash pasted from a word processor counts)",
                "必須是 ASCII，而此值含有非 ASCII 字元"
                + "（從文書軟體貼上的彎引號或破折號亦屬之）")
        }
        guard !bytes.isEmpty else {
            throw RGB1Error.badText(field, "must not be empty", "不可為空")
        }
        guard bytes.count < maxBytesExclusive else {
            throw RGB1Error.badText(field,
                "must be at most \(maxBytesExclusive - 1) bytes, and this is \(bytes.count)",
                "最多 \(maxBytesExclusive - 1) 個位元組，而此值為 \(bytes.count) 個")
        }
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 <= 0x7e }) else {
            throw RGB1Error.badText(field,
                "must contain only printable ASCII, and this contains a control character",
                "只能包含可列印的 ASCII，而此值含有控制字元")
        }
    }

    private static func validateEmail(_ value: String) throws {
        try validateASCII(value, field: "creator_email", maxBytesExclusive: creatorEmailFieldSize + 1)
        guard value.count <= creatorEmailFieldSize,
              !value.contains(" "),
              let at = value.firstIndex(of: "@"),
              at != value.startIndex,
              at != value.index(before: value.endIndex),
              value[value.index(after: at)...].contains(".")
        else {
            throw RGB1Error.badText("creator_email",
                "must look like an address: no spaces, one '@' with text on both "
                + "sides, and a '.' after it",
                "必須具備位址的形式：不含空白、有一個前後皆有文字的 '@'，且其後含 '.'")
        }
    }

    private static func validateRight(_ value: String) throws {
        guard let bytes = value.data(using: .ascii),
              !bytes.isEmpty,
              bytes.count <= rightFieldSize,
              bytes.allSatisfy({
                  ($0 >= UInt8(ascii: "A") && $0 <= UInt8(ascii: "Z"))
                  || ($0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "z"))
              })
        else {
            throw RGB1Error.badText("right",
                "must be 1 to \(rightFieldSize) ASCII letters, nothing else",
                "必須是 1 到 \(rightFieldSize) 個 ASCII 字母，不含其他字元")
        }
    }

    private static func readFixedASCII(_ data: Data, offset: Int, size: Int) throws -> String {
        let bytes = data[offset..<(offset + size)]
        let end = bytes.firstIndex(of: 0) ?? bytes.endIndex
        let field = Data(bytes[..<end])
        guard let value = String(data: field, encoding: .ascii) else {
            throw RGB1Error.badText("ascii",
                "the file holds bytes that are not ASCII at offset \(offset); "
                + "it was probably not written by this tool",
                "檔案在位移 \(offset) 處存有非 ASCII 位元組；很可能並非由本工具寫出")
        }
        return value
    }

    private static func appendFixedASCII(_ value: String, size: Int, to data: inout Data) {
        let bytes = value.data(using: .ascii) ?? Data()
        precondition(bytes.count <= size, "RGB1 fixed ASCII field exceeds its storage size")
        data.append(bytes)
        data.append(Data(count: size - bytes.count))
    }
}

func runRGB1Pack(
    inputPath: String,
    outputPath: String,
    width: UInt32,
    height: UInt32,
    latitude: Double,
    longitude: Double,
    heightMeters: Double,
    title: String,
    country: String,
    creatorEmail: String,
    right: String,
    createdUnixMilliseconds: Int64,
    timezoneOffsetMinutes: Int16 = RGB1Image.taiwanTimezoneOffsetMinutes
) throws {
    let payload: Data
    if inputPath == "-" {
        payload = FileHandle.standardInput.readDataToEndOfFile()
    } else {
        // The raw payload input for --rgb1-pack, same treatment: a directory
        // here reported "You don't have permission" too.
        // --rgb1-pack 的原始 payload 輸入，比照辦理：此處若是目錄，同樣會回報
        // 「您沒有權限」。
        payload = try rgb1ReadFile(inputPath)
    }
    let latitudeE7 = try rgb1ScaledGeo(latitude, scale: 10_000_000, min: -90, max: 90)
    let longitudeE7 = try rgb1ScaledGeo(longitude, scale: 10_000_000, min: -180, max: 180)
    let heightMillimeters = try rgb1ScaledGeo(
        heightMeters,
        scale: 1_000,
        min: Double(Int32.min) / 1_000,
        max: Double(Int32.max) / 1_000
    )
    let image = try RGB1Image(
        width: width,
        height: height,
        latitudeE7: latitudeE7,
        longitudeE7: longitudeE7,
        heightMillimeters: heightMillimeters,
        geoDatumCode: RGB1Image.wgs84EllipsoidDatum,
        title: title,
        country: country,
        creatorEmail: creatorEmail,
        right: right,
        createdUnixMilliseconds: createdUnixMilliseconds,
        timezoneOffsetMinutes: timezoneOffsetMinutes,
        payload: payload
    )
    let data = image.fileData
    if outputPath == "-" {
        try FileHandle.standardOutput.write(contentsOf: data)
    } else {
        do {
            try data.write(to: URL(fileURLWithPath: outputPath), options: [])
        } catch {
            // Say what is actually wrong. Foundation's own descriptions here are
            // not merely unhelpful, they misdirect: writing onto an existing
            // directory reports "You don't have permission", which sends the
            // reader to check ownership or re-run elevated when the only problem
            // is that -f names a directory. A missing parent reports "The file
            // doesn't exist", which names no file and points at the output
            // rather than the directory above it.
            //
            // 說出真正出錯的地方。Foundation 自帶的描述在此不只是無用，而是誤導：
            // 寫到既有目錄上會回報「您沒有權限」，使讀者跑去查擁有者或改用系統管理員
            // 身分重跑，而唯一的問題只是 -f 指向了一個目錄。父目錄不存在則回報
            // 「檔案不存在」，既沒點名任何檔案，指的方向也是輸出本身而非其上層目錄。
            let fm = FileManager.default
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: outputPath, isDirectory: &isDir), isDir.boolValue {
                throw RGB1Error.io(
                    "-f '\(outputPath)' is a directory, not a file to write / "
                    + "-f '\(outputPath)' 是目錄，不是可寫入的檔案")
            }
            let parent = (outputPath as NSString).deletingLastPathComponent
            if !parent.isEmpty, !fm.fileExists(atPath: parent) {
                throw RGB1Error.io(
                    "cannot write '\(outputPath)': its directory '\(parent)' does not exist / "
                    + "無法寫入 '\(outputPath)'：其所在目錄 '\(parent)' 不存在")
            }
            throw RGB1Error.io(
                "cannot write '\(outputPath)': \(error.localizedDescription) / "
                + "無法寫入 '\(outputPath)'")
        }
    }
}

/// Read a file for the RGB1 commands, saying what is wrong when it cannot be.
/// `Data(contentsOf:)` describes a directory as "You don't have permission" and
/// a missing path as "The file doesn't exist" -- the first is false and sends
/// the reader to check ownership or re-run elevated, and the second names no
/// path at all. Found on the write side first (round 63) and confirmed here on
/// the read side, which is the point: the wording is Foundation's, so every
/// place its descriptions reach the user unmodified carries the same defect,
/// and that is a different search than "where do we format our own errors".
///
/// 為 RGB1 各命令讀取檔案，並在讀不到時說出原因。`Data(contentsOf:)` 把目錄描述為
/// 「您沒有權限」、把不存在的路徑描述為「檔案不存在」——前者是假的，會使讀者跑去查
/// 擁有者或改用系統管理員身分重跑，後者則完全沒點名任何路徑。此問題先在寫入端發現
/// （round 63），並於此在讀取端獲得確認，而這正是重點：措辭出自 Foundation，因此凡是
/// 其描述原封抵達使用者的地方都帶有相同的缺陷，而那與「我們自己格式化錯誤的地方」是
/// 兩個不同的搜尋範圍。
func rgb1ReadFile(_ path: String) throws -> Data {
    do {
        return try Data(contentsOf: URL(fileURLWithPath: path))
    } catch {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: path, isDirectory: &isDir) {
            if isDir.boolValue {
                throw RGB1Error.io("-f '\(path)' is a directory, not a file to read / "
                                   + "-f '\(path)' 是目錄，不是可讀取的檔案")
            }
            throw RGB1Error.io("cannot read '\(path)': \(error.localizedDescription) / "
                               + "無法讀取 '\(path)'")
        }
        throw RGB1Error.io("'\(path)' does not exist / '\(path)' 不存在")
    }
}

func runRGB1Info(inputPath: String) throws {
    let data = try rgb1ReadFile(inputPath)
    let image = try RGB1Image(fileData: data)
    print("format=RGB1")
    print("width=\(image.width)")
    print("height=\(image.height)")
    print(String(format: "latitude=%.7f", Double(image.latitudeE7) / 10_000_000))
    print(String(format: "longitude=%.7f", Double(image.longitudeE7) / 10_000_000))
    print(String(format: "height_m=%.3f", Double(image.heightMillimeters) / 1_000))
    print("geo_datum_code=\(image.geoDatumCode)")
    print("title=\(image.title)")
    print("country=\(image.country)")
    print("creator_email=\(image.creatorEmail)")
    print("right=\(image.right)")
    print("created_unix_ms=\(image.createdUnixMilliseconds)")
    print("timezone_offset_minutes=\(image.timezoneOffsetMinutes)")
    print("payload_bytes=\(image.payload.count)")
}

func runRGB1Raw(inputPath: String) throws {
    let data = try rgb1ReadFile(inputPath)
    let image = try RGB1Image(fileData: data)
    try FileHandle.standardOutput.write(contentsOf: image.payload)
}

private func rgb1ScaledGeo(_ value: Double, scale: Double, min: Double, max: Double) throws -> Int32 {
    guard value.isFinite, value >= min, value <= max else { throw RGB1Error.badGeo }
    let scaled = (value * scale).rounded()
    guard scaled >= Double(Int32.min), scaled <= Double(Int32.max) else {
        throw RGB1Error.badGeo
    }
    return Int32(scaled)
}
