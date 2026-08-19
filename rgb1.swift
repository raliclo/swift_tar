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
    case badText(String)
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
        case .badText(let field):
            return "RGB1 text field is invalid: \(field). / RGB1 文字欄位無效：\(field)。"
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
        guard let bytes = value.data(using: .ascii),
              !bytes.isEmpty,
              bytes.count < maxBytesExclusive,
              bytes.allSatisfy({ $0 >= 0x20 && $0 <= 0x7e })
        else {
            throw RGB1Error.badText(field)
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
            throw RGB1Error.badText("creator_email")
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
            throw RGB1Error.badText("right")
        }
    }

    private static func readFixedASCII(_ data: Data, offset: Int, size: Int) throws -> String {
        let bytes = data[offset..<(offset + size)]
        let end = bytes.firstIndex(of: 0) ?? bytes.endIndex
        let field = Data(bytes[..<end])
        guard let value = String(data: field, encoding: .ascii) else {
            throw RGB1Error.badText("ascii")
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
        payload = try Data(contentsOf: URL(fileURLWithPath: inputPath))
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
        try data.write(to: URL(fileURLWithPath: outputPath), options: [])
    }
}

func runRGB1Info(inputPath: String) throws {
    let data = try Data(contentsOf: URL(fileURLWithPath: inputPath))
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
    let data = try Data(contentsOf: URL(fileURLWithPath: inputPath))
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
