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
        try TerminalScript.write(scriptContents(), named: "Sign in to Claude Code.command", into: directory)
    }

    /// Launches the sign-in flow. Returns false if the helper script could not
    /// be created, so the UI can fall back to telling the user the command.
    @discardableResult
    static func launch() -> Bool {
        TerminalScript.open(scriptContents(), named: "Sign in to Claude Code.command")
    }
}

/// Resets a login keychain that rejects every request while claiming to be
/// unlocked. `security unlock-keychain` asks for the password itself in
/// Terminal, so the app never sees it.
enum KeychainUnlockLauncher {
    static func scriptContents() -> String {
        """
        #!/bin/bash
        # Written by UsageRing to reset a stuck login keychain.

        KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

        echo "Your login keychain is refusing every request, so UsageRing can't read"
        echo "the Claude desktop app's session. Locking and unlocking it fixes this."
        echo
        echo "Enter your Mac login password below (typing stays hidden)."
        echo "It goes straight to macOS's 'security' tool — UsageRing never sees it."
        echo

        /usr/bin/security lock-keychain "$KEYCHAIN"

        unlocked=1
        for attempt in 1 2 3; do
          if /usr/bin/security unlock-keychain "$KEYCHAIN"; then
            unlocked=0
            break
          fi
          echo "That password didn't unlock it."
        done

        echo
        if [ $unlocked -eq 0 ]; then
          echo "Keychain unlocked. The UsageRing menu bar icon updates within a few seconds."
        else
          echo "If you recently changed your Mac password, the keychain may still use the old one."
          echo "Re-sync it with (asks for the old password, then the current one):"
          echo "    security set-keychain-password $KEYCHAIN"
        fi
        echo
        read -n 1 -s -r -p "Press any key to close this window."
        echo

        """
    }

    @discardableResult
    static func writeScript(into directory: URL) throws -> URL {
        try TerminalScript.write(scriptContents(), named: "Unlock login keychain.command", into: directory)
    }

    @discardableResult
    static func launch() -> Bool {
        TerminalScript.open(scriptContents(), named: "Unlock login keychain.command")
    }
}

/// Writes an executable `.command` file and opens it; LaunchServices hands
/// `.command` to Terminal, so no Automation permission is needed.
enum TerminalScript {
    @discardableResult
    static func write(_ contents: String, named name: String, into directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    static func open(_ contents: String, named name: String) -> Bool {
        do {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("UsageRing", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(try write(contents, named: name, into: directory))
            return true
        } catch {
            return false
        }
    }
}
