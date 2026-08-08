import XCTest
@testable import UsageRing

final class CryptoTests: XCTestCase {
    func testPBKDF2HMACSHA1MatchesReferenceVector() throws {
        // Verified against Python hashlib.pbkdf2_hmac('sha1', ...).
        let key = try Crypto.pbkdf2SHA1(
            password: "password", salt: "saltysalt", rounds: 1003, keyLength: 16)
        XCTAssertEqual(key.map { String(format: "%02x", $0) }.joined(),
                       "9395139d5abdba8b749042ad882c0937")
    }

    func testAES128CBCDecryptMatchesOpenSSLVector() throws {
        let keyHex = "000102030405060708090a0b0c0d0e0f"
        let ctHex = "7e65a0ac6016bee0d0361231ea9f6165"
            + "14549e1e9eb9855d501b4848f47d1351"
        let plain = try Crypto.aes128CBCDecrypt(
            ciphertext: Data(hex: ctHex),
            key: Data(hex: keyHex),
            iv: Data(repeating: 0x20, count: 16))
        XCTAssertEqual(String(decoding: plain, as: UTF8.self), "synthetic-session-value")
    }

    func testHexDataRoundTrips() {
        XCTAssertEqual(Data(hex: "deadbeef").map { String(format: "%02x", $0) }.joined(), "deadbeef")
        XCTAssertEqual(Data(hex: "").count, 0)
    }
}
