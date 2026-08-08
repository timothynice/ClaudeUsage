import XCTest
@testable import UsageRing

final class CookieDecryptTests: XCTestCase {
    // The key here matches the CryptoTests openssl vector.
    private let key = Data(hex: "9395139d5abdba8b749042ad882c0937")

    private func makeV10Blob(_ plaintext: String, domainPrefixed: Bool) throws -> Data {
        // Reproduce how Chromium stores a value: "v10" + AES-128-CBC(iv=16 spaces)
        // over an optional 32-byte domain hash followed by the value (PKCS7).
        var payload = Data()
        if domainPrefixed { payload.append(Data(repeating: 0xAB, count: 32)) }
        payload.append(Data(plaintext.utf8))
        let ct = try Crypto.aes128CBCEncrypt(
            plaintext: payload, key: key, iv: Data(repeating: 0x20, count: 16))
        return Data("v10".utf8) + ct
    }

    func testDecryptsPlainV10Value() throws {
        let blob = try makeV10Blob("lastActiveOrg-uuid-here", domainPrefixed: false)
        XCTAssertEqual(DesktopSessionStore.decryptCookieValue(blob, key: key), "lastActiveOrg-uuid-here")
    }

    func testStripsThe32ByteDomainHashPrefix() throws {
        let blob = try makeV10Blob("synthetic-session-value", domainPrefixed: true)
        XCTAssertEqual(DesktopSessionStore.decryptCookieValue(blob, key: key), "synthetic-session-value")
    }

    func testRejectsNonV10Blob() {
        XCTAssertNil(DesktopSessionStore.decryptCookieValue(Data("plaintext".utf8), key: key))
        XCTAssertNil(DesktopSessionStore.decryptCookieValue(Data(), key: key))
    }
}
