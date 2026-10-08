import Testing
@testable import ShellforgeCore

@Suite struct LoginEnvironmentParsingTests {
    private let marker = LoginEnvironment.marker

    @Test func readsTheVariablesAfterTheMarkerAndIgnoresAnRcBanner() {
        let output = "Welcome back!\nlast login: today\n\(marker)PATH=/opt/homebrew/bin:/usr/bin\0HOME=/Users/me\0"
        #expect(LoginEnvironment.parse(output) == ["PATH": "/opt/homebrew/bin:/usr/bin", "HOME": "/Users/me"])
    }

    @Test func keepsNewlinesAndEqualsSignsInsideAValue() {
        let output = "\(marker)GREETING=a=b\nsecond line\0"
        #expect(LoginEnvironment.parse(output) == ["GREETING": "a=b\nsecond line"])
    }

    @Test func withoutTheMarkerThereIsNoEnvironment() {
        #expect(LoginEnvironment.parse("PATH=/usr/bin\0") == nil)
    }
}

@Suite struct LoginEnvironmentFilterTests {
    @Test func keepsWhatToolsNeedBeyondThePATH() {
        let kept = ["PATH": "/opt/homebrew/bin", "SSH_AUTH_SOCK": "/tmp/agent.sock", "NVM_DIR": "/Users/me/.nvm",
                    "HTTPS_PROXY": "http://proxy:8080", "LANG": "en_US.UTF-8"]
        #expect(LoginEnvironment.forChildren(kept) == kept)
    }

    @Test func dropsTheShellsOwnSessionKeys() {
        let session = ["SHLVL": "2", "PWD": "/Users/me", "OLDPWD": "/", "_": "/usr/bin/env",
                       "TERM_SESSION_ID": "w0t0p0", "ITERM_SESSION_ID": "w0t0p0", "ITERM_PROFILE": "Default"]
        #expect(LoginEnvironment.forChildren(session.merging(["PATH": "/usr/bin"]) { $1 }) == ["PATH": "/usr/bin"])
    }

    @Test func dropsTheLaunchingAppsIdentity() {
        let identity = ["__CFBundleIdentifier": "com.example.shellforge", "XPC_SERVICE_NAME": "0", "XPC_FLAGS": "0x0",
                        "__XPC_DYLD_LIBRARY_PATH": "/x"]
        #expect(LoginEnvironment.forChildren(identity.merging(["PATH": "/usr/bin"]) { $1 }) == ["PATH": "/usr/bin"])
    }
}
