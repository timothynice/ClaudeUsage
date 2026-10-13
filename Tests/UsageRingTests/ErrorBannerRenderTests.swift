import XCTest
import SwiftUI
@testable import UsageRing

/// Renders the banner offscreen to prove each state lays out without crashing,
/// and that the sign-in affordance is actually present when it should be.
@MainActor
final class ErrorBannerRenderTests: XCTestCase {
    private func render(_ banner: ErrorBanner) throws -> NSImage {
        let renderer = ImageRenderer(content: banner.frame(width: 300))
        renderer.scale = 2
        return try XCTUnwrap(renderer.nsImage)
    }

    func testActionableBannerIsTallerBecauseItShowsTheSignInButton() throws {
        let actionable = try render(ErrorBanner(
            error: .tokenExpired("The saved sign-in has expired."), onFix: { _ in }))
        let plain = try render(ErrorBanner(
            error: .tokenExpired("The saved sign-in has expired."), onFix: nil))
        XCTAssertGreaterThan(actionable.size.height, plain.size.height,
                             "the tappable variant adds the 'Sign in to Claude Code' capsule")
    }

    func testTransientErrorsRenderWithoutASignInButton() throws {
        let withHandler = try render(ErrorBanner(error: .http(503), onFix: { _ in }))
        let withoutHandler = try render(ErrorBanner(error: .http(503), onFix: nil))
        XCTAssertEqual(withHandler.size.height, withoutHandler.size.height, accuracy: 0.5,
                       "a server error must not invite the user to re-authenticate")
    }

    func testAwaitingSignInStateRenders() throws {
        let image = try render(ErrorBanner(
            error: .tokenExpired("expired"), isAwaitingFix: true, onFix: { _ in }))
        XCTAssertGreaterThan(image.size.height, 0)
    }

    func testLaunchFailureFallbackRenders() throws {
        let fallback = try render(ErrorBanner(
            error: .noCredentials, launchFailed: true, onFix: { _ in }))
        let normal = try render(ErrorBanner(error: .noCredentials, onFix: { _ in }))
        XCTAssertGreaterThan(fallback.size.height, 0)
        XCTAssertGreaterThan(normal.size.height, 0)
    }

    func testStuckKeychainOffersTheUnlockButton() throws {
        let actionable = try render(ErrorBanner(error: .keychainStuck, onFix: { _ in }))
        let plain = try render(ErrorBanner(error: .keychainStuck, onFix: nil))
        XCTAssertGreaterThan(actionable.size.height, plain.size.height,
                             "a stuck keychain shows the 'Unlock keychain in Terminal' capsule")
    }

    func testUnapprovedPromptHasNoButton() throws {
        let withHandler = try render(ErrorBanner(error: .desktopSessionLocked, onFix: { _ in }))
        let withoutHandler = try render(ErrorBanner(error: .desktopSessionLocked, onFix: nil))
        XCTAssertEqual(withHandler.size.height, withoutHandler.size.height, accuracy: 0.5,
                       "approving a keychain prompt isn't something a Terminal script can do")
    }
}
