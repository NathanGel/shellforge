import Foundation

/// A host in `~/.ssh/config` that Shellforge can run as a tunnel: its alias, and the local ports it
/// forwards. Read only, to offer the hosts and show their ports; `ssh -N <alias>` applies the
/// forwards itself, exactly as `ssh <alias>` does.
public struct SSHHost: Equatable, Sendable, Identifiable {
    public var alias: String
    public var id: String { alias }
    public var forwards: [LocalForward]
    public init(alias: String, forwards: [LocalForward]) { self.alias = alias; self.forwards = forwards }
}

/// One `LocalForward` line: `[bind:]port host:hostport`.
public struct LocalForward: Equatable, Sendable {
    public var bind: String?
    public var localPort: Int
    public var remoteHost: String
    public var remotePort: Int
    public init(bind: String?, localPort: Int, remoteHost: String, remotePort: Int) {
        self.bind = bind; self.localPort = localPort; self.remoteHost = remoteHost; self.remotePort = remotePort
    }

    /// `5432 → db.internal:5432`, as a row shows it.
    public var label: String { "\(localPort) → \(remoteHost):\(remotePort)" }
}

/// Where the hosts are read from: `~/.ssh/config` in the app, a temporary file in the tests.
public struct SSHConfigSource: Sendable {
    public let file: URL
    public let home: URL

    public init(file: URL, home: URL) { self.file = file; self.home = home }

    /// The user's own `~/.ssh/config`.
    public static var user: SSHConfigSource {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return SSHConfigSource(file: home.appendingPathComponent(".ssh/config"), home: home)
    }

    /// No config: a model not told where the user's is reads nothing, so no test reads `~/.ssh`.
    public static let none = SSHConfigSource(file: URL(fileURLWithPath: "/dev/null"), home: URL(fileURLWithPath: "/var/empty"))

    public func read() -> [SSHHost] { SSHConfig.hosts(in: file, home: home) }
}

public enum SSHConfig {
    /// Whether `alias` can be typed into a terminal and handed to ssh as a destination: no control
    /// character, which a terminal acts on before the shell sees any quoting, and no leading `-`,
    /// which ssh reads as an option. An alias that fails is never offered.
    static func isTypable(_ alias: String) -> Bool {
        !alias.isEmpty && !alias.hasPrefix("-")
            && alias.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) && !CharacterSet.whitespaces.contains($0) }
    }

    /// What the pane beside a task's agent runs for a project's host: `ssh <alias>` without the
    /// host's forwards — those belong to its tunnel, which an interactive ssh would fight for the
    /// same local ports. The alias is one shell word.
    public static func paneCommand(alias: String) -> String { "ssh -o ClearAllForwardings=yes " + AgentCommand.shellWord(alias) }

    /// The concrete `Host` aliases in `file` — none with `*`, `?` or `!` — in file order, each with
    /// its `LocalForward`s. `Include` is followed (relative to `~/.ssh`, globbed), each file once, so
    /// an include loop ends; `Match` blocks are skipped. A missing file has no hosts.
    public static func hosts(in file: URL, home: URL) -> [SSHHost] {
        var reader = Reader(home: home)
        reader.read(file)
        return reader.order.map { SSHHost(alias: $0, forwards: reader.forwards[$0] ?? []) }
    }

    private struct Reader {
        let home: URL
        var order: [String] = []
        var forwards: [String: [LocalForward]] = [:]
        var visited: Set<String> = []

        init(home: URL) { self.home = home }

        mutating func read(_ file: URL) {
            let path = file.resolvingSymlinksInPath().path
            guard visited.insert(path).inserted, visited.count <= 64,
                  let text = try? String(contentsOf: file, encoding: .utf8) else { return }
            var current: [String] = []
            for raw in text.split(whereSeparator: \.isNewline) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty, !line.hasPrefix("#"), let (keyword, value) = Self.split(line) else { continue }
                switch keyword {
                case "host":
                    let patterns = Self.tokens(value)
                    current = patterns.filter { !$0.contains("*") && !$0.contains("?") && !$0.hasPrefix("!") && SSHConfig.isTypable($0) }
                    for alias in current where forwards[alias] == nil { order.append(alias); forwards[alias] = [] }
                case "match":
                    current = []
                case "include":
                    for pattern in Self.tokens(value) { for url in expand(pattern) { read(url) } }
                case "localforward":
                    guard let forward = Self.forward(value) else { continue }
                    for alias in current { forwards[alias, default: []].append(forward) }
                default:
                    continue
                }
            }
        }

        /// An `Include` argument as ssh reads it: `~` is the home folder, a relative path is under
        /// `~/.ssh`, and wildcards are globbed, in sorted order.
        private func expand(_ pattern: String) -> [URL] {
            var path = pattern
            if path.hasPrefix("~/") { path = home.path + String(path.dropFirst(1)) }
            else if !path.hasPrefix("/") { path = home.appendingPathComponent(".ssh").path + "/" + path }
            guard path.contains("*") || path.contains("?") || path.contains("[") else { return [URL(fileURLWithPath: path)] }
            var matches = glob_t()
            defer { globfree(&matches) }
            guard glob(path, 0, nil, &matches) == 0 else { return [] }
            return (0..<Int(matches.gl_pathc)).compactMap { matches.gl_pathv[$0].map { URL(fileURLWithPath: String(cString: $0)) } }.sorted { $0.path < $1.path }
        }

        /// `Keyword value` or `Keyword=value`, the keyword lower-cased.
        static func split(_ line: String) -> (String, String)? {
            guard let end = line.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "=" }) else { return nil }
            let keyword = line[..<end].lowercased()
            var value = line[end...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("=") { value = value.dropFirst().trimmingCharacters(in: .whitespaces) }
            return (keyword, value)
        }

        /// Whitespace-separated arguments, quotes removed.
        static func tokens(_ value: String) -> [String] {
            var result: [String] = [], current = "", quoted = false
            for character in value {
                if character == "\"" { quoted.toggle(); continue }
                if !quoted, character == " " || character == "\t" {
                    if !current.isEmpty { result.append(current); current = "" }
                } else {
                    current.append(character)
                }
            }
            if !current.isEmpty { result.append(current) }
            return result
        }

        /// `[bind:]port host:hostport`, an IPv6 address in brackets or `/` in place of `:`; a trailing
        /// `# comment` (OpenSSH 8.7 and later) is not part of it. A port outside 1–65535 is none.
        static func forward(_ value: String) -> LocalForward? {
            let parts = Array(tokens(value).prefix { !$0.hasPrefix("#") })
            guard parts.count == 2, let (bind, local) = endpoint(parts[0], portOnly: true),
                  let localPort = Int(local), let (host, remote) = endpoint(parts[1], portOnly: false),
                  let remoteHost = host, let remotePort = Int(remote),
                  Self.ports.contains(localPort), Self.ports.contains(remotePort) else { return nil }
            return LocalForward(bind: bind, localPort: localPort, remoteHost: remoteHost, remotePort: remotePort)
        }

        static let ports = 1...65535

        /// `port`, `address:port` or `[v6]:port`: the address (nil when only a port is allowed and
        /// given) and the port.
        static func endpoint(_ text: String, portOnly: Bool) -> (String?, String)? {
            if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
                let address = String(text[text.index(after: text.startIndex)..<close])
                let rest = text[text.index(after: close)...]
                guard rest.hasPrefix(":") else { return nil }
                return (address, String(rest.dropFirst()))
            }
            // `/` is ssh's other separator, the one an unbracketed IPv6 address needs.
            guard let colon = text.contains("/") ? text.lastIndex(of: "/") : text.lastIndex(of: ":") else {
                return portOnly ? (nil, text) : nil
            }
            return (String(text[..<colon]), String(text[text.index(after: colon)...]))
        }
    }
}
