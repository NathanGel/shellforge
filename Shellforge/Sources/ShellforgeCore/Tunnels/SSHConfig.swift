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

/// A User, Port or HostName set by a `Host *` or `Match all` block, and which block.
public struct SSHWildcardDefault: Equatable, Sendable {
    /// The `block` of a setting made before the config's first `Host` or `Match` line.
    public static let topOfFile = "top of the file"
    public var keyword: String
    public var block: String
    public init(keyword: String, block: String) { self.keyword = keyword; self.block = block }
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

    /// The hosts, read again only when a file the last read depended on changed (`SSHConfigCache`).
    public func read() -> [SSHHost] { SSHConfigCache.shared.hosts(in: file, home: home) }

    /// What a `Host *` or `Match all` block sets among User, Port and HostName, read fresh.
    public func wildcardDefaults() -> [SSHWildcardDefault] { SSHConfig.wildcardDefaults(in: file, home: home) }
}

/// The app's one copy of each config's hosts: every window's refresh asks, and the config and its
/// includes are read and parsed again only when one of them — or a folder an `Include` globs —
/// changed, appeared or went since the last read. Thread-safe.
public final class SSHConfigCache: Sendable {
    private struct Read { let stamps: FileStamps; let hosts: [SSHHost] }
    private let kept = Locked<[String: Read]>([:])
    private let parses = Locked(0)

    public init() {}

    public static let shared = SSHConfigCache()

    /// How many times a config was read and parsed, for tests.
    var parseCount: Int { parses.withLock { $0 } }

    public func hosts(in file: URL, home: URL) -> [SSHHost] {
        let key = file.path + "\u{0}" + home.path
        if let read = kept.withLock({ $0[key] }), read.stamps.areCurrent { return read.hosts }
        let (hosts, stamps) = SSHConfig.read(file, home: home)
        parses.withLock { $0 += 1 }
        kept.withLock { $0[key] = Read(stamps: stamps, hosts: hosts) }
        return hosts
    }
}

public enum SSHConfig {
    /// Whether `alias` can be typed into a terminal and handed to ssh as a destination: printable
    /// ASCII only, with no space, no backslash and no leading `-`. A control character is acted on
    /// by the terminal before the shell sees any quoting; a byte at 0x80 or above can be read as a
    /// Meta key by a shell in a non-UTF-8 locale; a backslash is an escape to the line editor; and
    /// ssh reads a leading `-` as an option. An alias that fails is never offered.
    static func isTypable(_ alias: String) -> Bool {
        !alias.isEmpty && !alias.hasPrefix("-")
            && alias.unicodeScalars.allSatisfy { $0.isASCII && $0.value > 0x20 && $0.value != 0x7F && $0 != "\\" }
    }

    /// What the pane beside a task's agent runs for a project's host: `ssh <alias>` without the
    /// host's forwards — those belong to its tunnel, which an interactive ssh would fight for the
    /// same local ports. The alias is one shell word.
    public static func paneCommand(alias: String) -> String { "ssh -o ClearAllForwardings=yes " + AgentCommand.shellWord(alias) }

    /// The concrete `Host` aliases in `file` — none with `*`, `?` or `!` — in file order, each with
    /// its `LocalForward`s. `Include` is followed (relative to `~/.ssh`, globbed), each file once, so
    /// an include loop ends; `Match` blocks are skipped. A missing file has no hosts.
    public static func hosts(in file: URL, home: URL) -> [SSHHost] { read(file, home: home).hosts }

    /// The hosts, and the stamps of everything they were read from: each file tried, missing or
    /// not, under its own name and its target's, and the folder of each `Include` glob, which a
    /// file added to it changes. Each is stamped before it is read, so a change while reading is
    /// caught on the next ask.
    static func read(_ file: URL, home: URL) -> (hosts: [SSHHost], stamps: FileStamps) {
        var reader = Reader(home: home)
        reader.read(file)
        let hosts = reader.order.map { SSHHost(alias: $0, forwards: reader.forwards[$0] ?? []) }
        return (hosts, FileStamps(files: reader.stamped.map(\.0), stamps: reader.stamped.map(\.1)))
    }

    /// What an earlier `Host *` or `Match all` block in the config sets among User, Port and
    /// HostName. ssh takes the first value it finds for each, so a host appended below never gets to
    /// use its own. `IdentityFile` is left out: ssh adds those up across blocks.
    public static func wildcardDefaults(in file: URL, home: URL) -> [SSHWildcardDefault] {
        var reader = Reader(home: home)
        reader.read(file)
        return reader.wildcard
    }

    /// The sheet's warning, if any: the keywords the new host sets that an earlier wildcard block
    /// has already set. Nil when none clash.
    public static func wildcardWarning(for host: NewSSHHost, earlier: [SSHWildcardDefault]) -> String? {
        let typed = host.trimmed
        let sets: [String: Bool] = ["User": !typed.user.isEmpty, "Port": !typed.port.isEmpty, "HostName": !typed.hostName.isEmpty]
        let clashing = earlier.filter { sets[$0.keyword] == true }
        guard !clashing.isEmpty else { return nil }
        func list(_ entries: [SSHWildcardDefault]) -> String {
            var keywords: [String] = []
            for entry in entries where !keywords.contains(entry.keyword) { keywords.append(entry.keyword) }
            return keywords.count > 1 ? keywords.dropLast().joined(separator: ", ") + " and " + keywords[keywords.count - 1] : keywords[0]
        }
        let top = clashing.filter { $0.block == SSHWildcardDefault.topOfFile }
        let inBlocks = clashing.filter { $0.block != SSHWildcardDefault.topOfFile }
        var sentences: [String] = []
        if !top.isEmpty {
            sentences.append("Your SSH config sets \(list(top)) before its first Host line, so it applies before this host’s own.")
        }
        if !inBlocks.isEmpty {
            var blocks: [String] = []
            for entry in inBlocks where !blocks.contains(entry.block) { blocks.append(entry.block) }
            sentences.append("An earlier \(blocks.joined(separator: " or ")) block in your SSH config sets \(list(inBlocks)), so it applies before this host’s own.")
        }
        return sentences.joined(separator: " ")
    }

    private struct Reader {
        let home: URL
        var order: [String] = []
        var forwards: [String: [LocalForward]] = [:]
        var visited: Set<String> = []
        var stamped: [(String, FileStamps.Stamp?)] = []
        /// User, Port and HostName set in a `Host *` or `Match all` block, or before the first
        /// `Host` or `Match` line: keyword, then the block.
        var wildcard: [SSHWildcardDefault] = []
        /// The block the line being read is in, when it applies to every host: the top of the file
        /// until the first `Host` or `Match` line. An included file starts in the block of the
        /// `Include` line, as ssh reads it, and that block is back once the file is read.
        var wildcardBlock: String? = SSHWildcardDefault.topOfFile

        init(home: URL) { self.home = home }

        mutating func stamp(_ path: String) {
            guard !stamped.contains(where: { $0.0 == path }) else { return }
            stamped.append((path, FileStamps.stamp(path)))
        }

        mutating func read(_ file: URL) {
            let path = file.resolvingSymlinksInPath().path
            stamp(file.path)
            stamp(path)
            guard visited.insert(path).inserted, visited.count <= 64,
                  let text = try? String(contentsOf: file, encoding: .utf8) else { return }
            var current: [String] = []
            for raw in text.split(whereSeparator: \.isNewline) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty, !line.hasPrefix("#"), let (keyword, value) = Self.split(line) else { continue }
                switch keyword {
                case "host":
                    let patterns = Self.tokens(value)
                    wildcardBlock = patterns.contains("*") ? "Host *" : nil
                    current = patterns.filter { !$0.contains("*") && !$0.contains("?") && !$0.hasPrefix("!") && SSHConfig.isTypable($0) }
                    for alias in current where forwards[alias] == nil { order.append(alias); forwards[alias] = [] }
                case "match":
                    current = []
                    let criteria = Self.tokens(value).map { $0.lowercased() }
                    wildcardBlock = Self.matchesAll(criteria) ? "Match " + criteria.joined(separator: " ") : nil
                case "include":
                    let enclosing = wildcardBlock
                    for pattern in Self.tokens(value) { for url in expand(pattern) { read(url) } }
                    wildcardBlock = enclosing
                case "localforward":
                    guard let forward = Self.forward(value) else { continue }
                    for alias in current { forwards[alias, default: []].append(forward) }
                case "user", "port", "hostname":
                    guard let block = wildcardBlock else { continue }
                    let canonical = ["user": "User", "port": "Port", "hostname": "HostName"][keyword] ?? keyword
                    if !wildcard.contains(where: { $0.keyword == canonical && $0.block == block }) {
                        wildcard.append(SSHWildcardDefault(keyword: canonical, block: block))
                    }
                default:
                    continue
                }
            }
        }

        /// An `Include` argument as ssh reads it: `~` is the home folder, a relative path is under
        /// `~/.ssh`, and wildcards are globbed, in sorted order.
        private mutating func expand(_ pattern: String) -> [URL] {
            var path = pattern
            if path.hasPrefix("~/") { path = home.path + String(path.dropFirst(1)) }
            else if !path.hasPrefix("/") { path = home.appendingPathComponent(".ssh").path + "/" + path }
            let wild: (Substring) -> Bool = { $0.contains("*") || $0.contains("?") || $0.contains("[") }
            guard wild(Substring(path)) else { return [URL(fileURLWithPath: path)] }
            // The deepest folder above the first wildcard: a file added there changes its date.
            stamp("/" + path.split(separator: "/").prefix { !wild($0) }.joined(separator: "/"))
            var matches = glob_t()
            defer { globfree(&matches) }
            guard glob(path, 0, nil, &matches) == 0 else { return [] }
            return (0..<Int(matches.gl_pathc)).compactMap { matches.gl_pathv[$0].map { URL(fileURLWithPath: String(cString: $0)) } }.sorted { $0.path < $1.path }
        }

        /// `Match all`, alone or after `canonical` or `final`, which only say when it is evaluated.
        static func matchesAll(_ criteria: [String]) -> Bool {
            criteria.last == "all" && criteria.dropLast().allSatisfy { $0 == "canonical" || $0 == "final" } && criteria.count <= 3
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
