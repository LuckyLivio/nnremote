#if os(macOS)
import CryptoKit
import Foundation
import Security

enum MHError: LocalizedError {
    case detail(String)
    var errorDescription: String? {
        switch self { case .detail(let text): return text }
    }
}

/// Each listening period has a fresh in-memory key pair and an independent pairing secret.
struct MHIdentity {
    let identity: sec_identity_t
    let fingerprint: String
    private(set) var secret: [UInt8]

    init() throws {
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 256
        ]
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, nil),
              let publicKey = SecKeyCopyPublicKey(key),
              let point = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?,
              point.count == 65, point.first == 4 else {
            throw MHError.detail("无法生成主机身份。")
        }

        // Encode the minimal X.509 structures for an ECDSA P-256 TLS leaf.
        // The viewer authenticates the exact DER certificate using the separately supplied pin.
        let sigAlg = MHDER.sequence(MHDER.oid([0x2A,0x86,0x48,0xCE,0x3D,4,3,2]))
        let name = MHDER.sequence(MHDER.wrap(0x31, MHDER.sequence(
            MHDER.oid([0x55,4,3]) + MHDER.wrap(0x0C, Data("Livio Remote".utf8))
        )))
        let keyAlg = MHDER.sequence(MHDER.oid([0x2A,0x86,0x48,0xCE,0x3D,2,1])
            + MHDER.oid([0x2A,0x86,0x48,0xCE,0x3D,3,1,7]))
        let publicInfo = MHDER.sequence(keyAlg + MHDER.bitString(point))
        var serial = try Self.random(count: 16)
        serial[0] = (serial[0] & 0x7F) | 1
        let now = Date()
        let validity = MHDER.sequence(MHDER.time(now.addingTimeInterval(-300))
            + MHDER.time(now.addingTimeInterval(7 * 24 * 60 * 60)))
        let tlsUsage = MHDER.sequence(MHDER.oid([0x55,0x1D,0x25]) + MHDER.wrap(4,
            MHDER.sequence(MHDER.oid([0x2B,6,1,5,5,7,3,1]))))
        let version = MHDER.wrap(0xA0, MHDER.wrap(2, Data([2])))
        let fields = [version, MHDER.wrap(2, Data(serial)), sigAlg, name, validity, name,
                      publicInfo, MHDER.wrap(0xA3, MHDER.sequence(tlsUsage))]
        let tbs = MHDER.sequence(fields.reduce(into: Data()) { $0.append($1) })
        guard let signature = SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256,
                tbs as CFData, nil) as Data? else { throw MHError.detail("无法签署主机证书。") }
        let der = MHDER.sequence(tbs + sigAlg + MHDER.bitString(signature))
        guard let cert = SecCertificateCreateWithData(nil, der as CFData),
              let pair = SecIdentityCreate(nil, cert, key),
              let tlsIdentity = sec_identity_create(pair) else {
            throw MHError.detail("无法创建 TLS 身份。")
        }
        identity = tlsIdentity
        fingerprint = Self.hex(SHA256.hash(data: der))
        secret = try Self.random(count: 16)
    }

    mutating func refreshSecret() throws { secret = try Self.random(count: 16) }

    static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02X", $0) }.joined()
    }

    private static func random(count: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
            throw MHError.detail("系统随机数生成失败。")
        }
        return bytes
    }

    func accepts(_ ascii: Data) -> Bool {
        guard ascii.count == 32 else { return false }
        let bytes = Array(ascii)
        func nibble(_ n: UInt8) -> UInt8? {
            switch n {
            case 48...57: return n - 48
            case 65...70: return n - 65 + 10
            case 97...102: return n - 97 + 10
            default: return nil
            }
        }
        var difference: UInt8 = 0
        for i in secret.indices {
            guard let hi = nibble(bytes[2*i]), let lo = nibble(bytes[2*i+1]) else { return false }
            difference |= secret[i] ^ ((hi << 4) | lo)
        }
        return difference == 0
    }
}

private enum MHDER {
    static func wrap(_ tag: UInt8, _ content: Data) -> Data {
        var header = Data([tag])
        if content.count < 128 {
            header.append(UInt8(content.count))
        } else {
            var count = content.count
            var length = [UInt8]()
            while count != 0 {
                length.append(UInt8(truncatingIfNeeded: count))
                count >>= 8
            }
            header.append(0x80 | UInt8(length.count))
            header.append(contentsOf: length.reversed())
        }
        header.append(content)
        return header
    }

    static func sequence(_ data: Data) -> Data { wrap(0x30, data) }
    static func oid(_ bytes: [UInt8]) -> Data { wrap(6, Data(bytes)) }
    static func bitString(_ data: Data) -> Data { wrap(3, Data([0]) + data) }

    static func time(_ date: Date) -> Data {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.calendar = Calendar(identifier: .gregorian)
        format.timeZone = TimeZone(secondsFromGMT: 0)
        format.dateFormat = "yyMMddHHmmss'Z'"
        return wrap(0x17, Data(format.string(from: date).utf8))
    }
}
#endif
