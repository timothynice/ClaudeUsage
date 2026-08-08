import Foundation
import AppKit

/// Opens the real `claude auth login` flow in Terminal.
///
/// The app deliberately does not attempt the OAuth flow itself — signing in
/// happens in the user's browser, against the official CLI. This just saves
/// them from having to find a terminal and remember the command.
enum LoginLauncher {
    static func scriptContents() -> String {
        """
        #!/bin/bash
        # Written by UsageRing to start the Claude Code sign-in flow.

        echo "Signing in to Claude Code — UsageRing needs this once."
        echo

        if ! command -v claude >/dev/null 2>&1; then
          for candidate in "$HOME/.local/bin/claude" "/opt/homebrew/bin/claude" "/usr/local/bin/claude"; do
            if [ -x "$candidate" ]; then
              export PATH="$(dirname "$candidate"):$PATH"
              break
            fi
          done
        fi

        if ! command -v claude >/dev/null 2>&1; then
          echo "Could not find the 'claude' command on this Mac."
          echo "Install Claude Code from https://claude.com/claude-code, then run:"
          echo "    claude auth login"
          echo
          read -n 1 -s -r -p "Press any key to close this window."
          echo
          exit 1
        fi

        claude auth login
        status=$?

        echo
        if [ $status -eq 0 ]; then
          echo "Signed in. The UsageRing menu bar icon updates within a few seconds."
        else
          echo "Sign-in did not complete (exit $status). You can retry from the UsageRing menu."
        fi
        echo
        read -n 1 -s -r -p "Press any key to close this window."
        echo

        """
    }

    @discardableResult
    static func writeScript(into directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("Sign in to Claude Code.command")
        try scriptContents().write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// Launches the sign-in flow. Returns false if the helper script could not
    /// be created, so the UI can fall back to telling the user the command.
    @discardableResult
    static func launch() -> Bool {
        do {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("UsageRing", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let script = try writeScript(into: directory)
            NSWorkspace.shared.open(script)
            return true
        } catch {
            return false
        }
    }
}
