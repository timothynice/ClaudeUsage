import Foundation
import CommonCrypto

/// Minimal wrappers over CommonCrypto for the Chromium cookie scheme
/// (PBKDF2-HMAC-SHA1 key derivation + AES-128-CBC with PKCS7 padding).
enum Crypto {
    static func pbkdf2SHA1(password: String, salt: String, rounds: Int, keyLength: Int) throws -> Data {
        let pw = Array(password.utf8)
        let saltBytes = Array(salt.utf8)
        var derived = Data(count: keyLength)
        let status = derived.withUnsafeMutableBytes { out -> Int32 in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                pw, pw.count,
                saltBytes, saltBytes.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                UInt32(rounds),
                out.bindMemory(to: UInt8.self).baseAddress, keyLength)
        }
        guard status == kCCSuccess else { throw FetchError.credentialsUnreadable }
        return derived
    }

    static func aes128CBCDecrypt(ciphertext: Data, key: Data, iv: Data) throws -> Data {
        try crypt(CCOperation(kCCDecrypt), input: ciphertext, key: key, iv: iv)
    }

    static func aes128CBCEncrypt(plaintext: Data, key: Data, iv: Data) throws -> Data {
        try crypt(CCOperation(kCCEncrypt), input: plaintext, key: key, iv: iv)
    }

    private static func crypt(_ operation: CCOperation, input: Data, key: Data, iv: Data) throws -> Data {
        var output = Data(count: input.count + kCCBlockSizeAES128)
        var moved = 0
        let status = output.withUnsafeMutableBytes { out in
            input.withUnsafeBytes { dataIn in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(operation, CCAlgorithm(kCCAlgorithmAES),
                                CCOptions(kCCOptionPKCS7Padding),
                                keyBytes.baseAddress, key.count,
                                ivBytes.baseAddress,
                                dataIn.baseAddress, input.count,
                                out.baseAddress, out.count, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw FetchError.credentialsUnreadable }
        output.removeSubrange(moved..<output.count)
        return output
    }
}

extension Data {
    /// Decodes a hex string (no `0x`, even length assumed). Odd trailing nibble is dropped.
    init(hex: String) {
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex), next <= hex.endIndex {
            if let byte = UInt8(hex[index..<next], radix: 16) { data.append(byte) }
            index = next
        }
        self = data
    }
}
