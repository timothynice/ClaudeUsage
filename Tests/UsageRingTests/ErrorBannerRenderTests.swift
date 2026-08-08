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
            error: .tokenExpired("The saved sign-in has expired."), onSignIn: {}))
        let plain = try render(ErrorBanner(
            error: .tokenExpired("The saved sign-in has expired."), onSignIn: nil))
        XCTAssertGreaterThan(actionable.size.height, plain.size.height,
                             "the tappable variant adds the 'Sign in to Claude Code' capsule")
    }

    func testTransientErrorsRenderWithoutASignInButton() throws {
        let withHandler = try render(ErrorBanner(error: .http(503), onSignIn: {}))
        let withoutHandler = try render(ErrorBanner(error: .http(503), onSignIn: nil))
        XCTAssertEqual(withHandler.size.height, withoutHandler.size.height, accuracy: 0.5,
                       "a server error must not invite the user to re-authenticate")
    }

    func testAwaitingSignInStateRenders() throws {
        let image = try render(ErrorBanner(
            error: .tokenExpired("expired"), isAwaitingSignIn: true, onSignIn: {}))
        XCTAssertGreaterThan(image.size.height, 0)
    }

    func testLaunchFailureFallbackRenders() throws {
        let fallback = try render(ErrorBanner(
            error: .noCredentials, launchFailed: true, onSignIn: {}))
        let normal = try render(ErrorBanner(error: .noCredentials, onSignIn: {}))
        XCTAssertGreaterThan(fallback.size.height, 0)
        XCTAssertGreaterThan(normal.size.height, 0)
    }
}
