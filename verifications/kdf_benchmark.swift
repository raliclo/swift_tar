import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@main
struct KDFBenchmark {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            FileHandle.standardError.write(Data("usage: kdf_benchmark passphrase|keyfile\n".utf8))
            exit(2)
        }

        let secret: TarCrypto.KeySecret
        switch CommandLine.arguments[1] {
        case "passphrase":
            secret = .passphrase("swift_tar benchmark passphrase")
        case "keyfile":
            secret = .keyfile(Array(repeating: 0x5a, count: 64))
        default:
            FileHandle.standardError.write(Data("unknown benchmark mode\n".utf8))
            exit(2)
        }

        let input = try FileHandle(forReadingFrom: URL(fileURLWithPath: "/dev/null"))
        let output = try FileHandle(forWritingTo: URL(fileURLWithPath: "/dev/null"))
        defer {
            try? input.close()
            try? output.close()
        }
        try TarCrypto.encryptStream(input: input, output: output, secret: secret)
    }
}
