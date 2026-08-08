import XCTest
@testable import UsageRing

final class LoginLauncherTests: XCTestCase {
    func testOnlyCredentialErrorsOfferSignIn() {
        XCTAssertTrue(FetchError.noCredentials.isSignInFixable)
        XCTAssertTrue(FetchError.tokenExpired("expired").isSignInFixable)
        XCTAssertTrue(FetchError.credentialsUnreadable.isSignInFixable)

        // Transient problems must not tell the user to re-authenticate.
        XCTAssertFalse(FetchError.refreshRateLimited.isSignInFixable)
        XCTAssertFalse(FetchError.http(503).isSignInFixable)
        XCTAssertFalse(FetchError.network("offline").isSignInFixable)
        XCTAssertFalse(FetchError.parse("weird").isSignInFixable)
    }

    func testScriptRunsTheLoginCommand() {
        let script = LoginLauncher.scriptContents()
        XCTAssertTrue(script.hasPrefix("#!/bin/bash"), script)
        XCTAssertTrue(script.contains("claude auth login"), script)
    }

    func testScriptFallsBackToCommonInstallLocations() {
        let script = LoginLauncher.scriptContents()
        // GUI apps inherit a minimal PATH; Terminal loads the login shell, but
        // cover the usual install spots anyway.
        XCTAssertTrue(script.contains("$HOME/.local/bin"), script)
        XCTAssertTrue(script.contains("/opt/homebrew/bin"), script)
        XCTAssertTrue(script.contains("/usr/local/bin"), script)
    }

    func testScriptIsValidBash() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("syntax-\(UUID().uuidString).command")
        try LoginLauncher.scriptContents().write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-n", url.path] // parse only, never execute
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        let errorText = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "bash syntax check failed: \(errorText)")
    }

    func testWrittenScriptIsExecutable() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("launcher-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = try LoginLauncher.writeScript(into: directory)
        XCTAssertEqual(url.pathExtension, "command", "Terminal opens .command files directly")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: url.path))
        let contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(contents.contains("claude auth login"))
    }

    func testWritingTwiceReplacesTheExistingScript() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("launcher-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = try LoginLauncher.writeScript(into: directory)
        let second = try LoginLauncher.writeScript(into: directory)
        XCTAssertEqual(first, second, "reuses one stable path instead of littering temp files")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: second.path))
    }
}
