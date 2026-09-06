import Foundation

/// Parses the Windows Shell Link (`.lnk`) binary format — just enough of
/// MS-SHLLINK to recover the target executable path and its command-line
/// arguments, which is all `ProgramScanner` needs from a Desktop/Start
/// Menu shortcut. Not a general-purpose `.lnk` writer/reader.
///
/// Layout (little-endian throughout):
/// ```
/// ShellLinkHeader (HeaderSize bytes, normally 76)
///   ...
///   LinkFlags: UInt32 at offset 20
/// [LinkTargetIDList]   present iff LinkFlags.HasLinkTargetIDList
///   IDListSize: UInt16, then that many bytes (includes the terminal ID)
/// [LinkInfo]           present iff LinkFlags.HasLinkInfo
///   LinkInfoSize: UInt32
///   LinkInfoHeaderSize: UInt32
///   LinkInfoFlags: UInt32            bit0 = VolumeIDAndLocalBasePath
///   VolumeIDOffset: UInt32
///   LocalBasePathOffset: UInt32      relative to LinkInfo start
///   CommonNetworkRelativeLinkOffset: UInt32
///   CommonPathSuffixOffset: UInt32
///   [LocalBasePathOffsetUnicode: UInt32]     only if LinkInfoHeaderSize >= 0x24
///   [CommonPathSuffixOffsetUnicode: UInt32]  only if LinkInfoHeaderSize >= 0x24
///   ... NUL-terminated LocalBasePath string lives at its offset
/// StringData            NAME_STRING, RELATIVE_PATH, WORKING_DIR,
///                        COMMAND_LINE_ARGUMENTS, ICON_LOCATION — each
///                        present iff its LinkFlags bit is set, each
///                        encoded as CountCharacters:UInt16 followed by
///                        that many UTF-16LE (or ANSI, if not IsUnicode)
///                        code units (NOT NUL-terminated).
/// ```
enum ShellLink {
    /// The pieces of a `.lnk` this app cares about.
    struct Link: Sendable {
        /// The Windows path the shortcut points at, e.g.
        /// `C:\Program Files\Foo\foo.exe`. Empty if the file had neither
        /// a resolvable `LinkInfo.LocalBasePath` nor a usable id list.
        var target: String
        /// The shortcut's command-line arguments, if any (`""` if none).
        var arguments: String
    }

    private struct LinkFlags: OptionSet {
        let rawValue: UInt32
        static let hasLinkTargetIDList = LinkFlags(rawValue: 0x0000_0001)
        static let hasLinkInfo         = LinkFlags(rawValue: 0x0000_0002)
        static let hasName             = LinkFlags(rawValue: 0x0000_0004)
        static let hasRelativePath     = LinkFlags(rawValue: 0x0000_0008)
        static let hasWorkingDir       = LinkFlags(rawValue: 0x0000_0010)
        static let hasArguments        = LinkFlags(rawValue: 0x0000_0020)
        static let hasIconLocation     = LinkFlags(rawValue: 0x0000_0040)
        static let isUnicode           = LinkFlags(rawValue: 0x0000_0080)
    }

    private struct LinkInfoFlags: OptionSet {
        let rawValue: UInt32
        static let volumeIDAndLocalBasePath = LinkInfoFlags(rawValue: 0x0000_0001)
    }

    // MARK: - Public API

    /// Parses `lnkURL` and returns its target Windows path and arguments,
    /// or `nil` if the file isn't a well-formed `.lnk` (bad magic/header,
    /// truncated, or no `LinkInfo` at all — e.g. a shortcut that only
    /// carries a shell-namespace `LinkTargetIDList`, which this parser
    /// does not walk).
    static func parse(_ lnkURL: URL) -> Link? {
        guard let data = try? Data(contentsOf: lnkURL) else { return nil }
        return parse(data)
    }

    /// Convenience for callers that only need the target path.
    static func targetPath(of lnkURL: URL) -> String? {
        let link = parse(lnkURL)
        return (link?.target.isEmpty == false) ? link?.target : nil
    }

    /// Maps a Windows path like `C:\Program Files\Foo\foo.exe` (or
    /// `c:\...`) to the corresponding file inside a bottle's `drive_c`.
    /// Wine prefixes are plain case-sensitive-on-disk directory trees, so
    /// a `.lnk` authored with different casing than what's actually on
    /// disk (common — Windows paths are case-insensitive) needs a
    /// fallback: try the direct join first, then walk the path
    /// component-by-component doing a case-insensitive lookup against
    /// what's really in each directory.
    static func windowsPathToUnix(_ win: String, driveC: URL) -> URL? {
        var path = win.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.count >= 2 else { return nil }

        // Strip the drive letter ("C:" / "c:") and any leading backslash.
        let driveIndex = path.index(path.startIndex, offsetBy: 2)
        guard path[path.index(after: path.startIndex)] == ":" else { return nil }
        path.removeSubrange(path.startIndex..<driveIndex)
        while path.hasPrefix("\\") || path.hasPrefix("/") {
            path.removeFirst()
        }

        let components = path
            .split(separator: "\\")
            .flatMap { $0.split(separator: "/") }
            .map(String.init)
        guard !components.isEmpty else { return nil }

        // Fast path: direct join, exactly as written.
        let direct = components.reduce(driveC) { $0.appendingPathComponent($1) }
        if FileManager.default.fileExists(atPath: direct.path) {
            return direct
        }

        // Slow path: resolve each component case-insensitively against
        // what's actually on disk.
        var current = driveC
        let fm = FileManager.default
        for component in components {
            guard let entries = try? fm.contentsOfDirectory(atPath: current.path) else {
                return nil
            }
            if entries.contains(component) {
                current = current.appendingPathComponent(component)
            } else if let match = entries.first(where: { $0.caseInsensitiveCompare(component) == .orderedSame }) {
                current = current.appendingPathComponent(match)
            } else {
                return nil
            }
        }
        return fm.fileExists(atPath: current.path) ? current : nil
    }

    // MARK: - Binary parsing

    private static func parse(_ data: Data) -> Link? {
        // Header: magic UInt32 at 0 must be 0x0000004C ("L" size marker),
        // then a 16-byte CLSID, then LinkFlags at offset 20.
        guard data.count >= 76,
              let headerSize = readUInt32(data, at: 0), headerSize >= 76,
              data.count >= Int(headerSize),
              let flagsRaw = readUInt32(data, at: 20)
        else { return nil }

        let flags = LinkFlags(rawValue: flagsRaw)
        let isUnicode = flags.contains(.isUnicode)
        var offset = Int(headerSize)

        if flags.contains(.hasLinkTargetIDList) {
            guard let idListSize = readUInt16(data, at: offset) else { return nil }
            offset += 2 + Int(idListSize)
        }

        var target = ""

        if flags.contains(.hasLinkInfo) {
            guard offset + 4 <= data.count, let linkInfoSize = readUInt32(data, at: offset) else { return nil }
            let linkInfoStart = offset
            guard linkInfoSize >= 4, linkInfoStart + Int(linkInfoSize) <= data.count else { return nil }

            if let path = parseLinkInfo(data, start: linkInfoStart, size: Int(linkInfoSize)) {
                target = path
            }
            offset = linkInfoStart + Int(linkInfoSize)
        }

        var arguments = ""

        // StringData, in this fixed order. Each present block is
        // CountCharacters:UInt16 followed by that many code units — 2
        // bytes each if IsUnicode, else 1 (ANSI/Windows-1252).
        let stringFieldFlags: [LinkFlags] = [.hasName, .hasRelativePath, .hasWorkingDir, .hasArguments, .hasIconLocation]
        for field in stringFieldFlags {
            guard flags.contains(field) else { continue }
            guard let count = readUInt16(data, at: offset) else { return target.isEmpty ? nil : Link(target: target, arguments: arguments) }
            offset += 2
            let byteLength = Int(count) * (isUnicode ? 2 : 1)
            guard offset + byteLength <= data.count else { break }
            let slice = data.subdata(in: offset..<(offset + byteLength))
            let string = isUnicode
                ? (String(data: slice, encoding: .utf16LittleEndian) ?? "")
                : (String(data: slice, encoding: .windowsCP1252) ?? "")
            offset += byteLength

            if field == .hasArguments {
                arguments = string
            }
        }

        guard !target.isEmpty else { return nil }
        return Link(target: target, arguments: arguments)
    }

    /// Parses the `LinkInfo` structure starting at `start` (absolute
    /// offset into `data`), `size` bytes long, and returns the resolved
    /// `LocalBasePath` (preferring the Unicode variant when the header is
    /// long enough to carry one), or `nil` if this LinkInfo doesn't carry
    /// a local path (e.g. a network share only).
    private static func parseLinkInfo(_ data: Data, start: Int, size: Int) -> String? {
        guard let headerSize = readUInt32(data, at: start + 4),
              let flagsRaw = readUInt32(data, at: start + 8),
              let localBasePathOffset = readUInt32(data, at: start + 16)
        else { return nil }

        let flags = LinkInfoFlags(rawValue: flagsRaw)
        guard flags.contains(.volumeIDAndLocalBasePath) else { return nil }

        // The Unicode offset fields only exist when LinkInfoHeaderSize is
        // large enough (>= 0x24) to include them.
        if headerSize >= 0x24, let unicodeOffset = readUInt32(data, at: start + 28), unicodeOffset != 0 {
            let absolute = start + Int(unicodeOffset)
            if let string = readNulTerminatedUTF16(data, at: absolute) {
                return string
            }
        }

        guard localBasePathOffset != 0 else { return nil }
        let absolute = start + Int(localBasePathOffset)
        return readNulTerminatedANSI(data, at: absolute)
    }

    // MARK: - Low-level readers

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= data.count else { return nil }
        let b0 = UInt16(data[data.startIndex + offset])
        let b1 = UInt16(data[data.startIndex + offset + 1])
        return b0 | (b1 << 8)
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        let base = data.startIndex + offset
        let b0 = UInt32(data[base])
        let b1 = UInt32(data[base + 1])
        let b2 = UInt32(data[base + 2])
        let b3 = UInt32(data[base + 3])
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }

    private static func readNulTerminatedANSI(_ data: Data, at offset: Int) -> String? {
        guard offset >= 0, offset < data.count else { return nil }
        var end = data.startIndex + offset
        while end < data.endIndex, data[end] != 0 { end += 1 }
        let slice = data.subdata(in: (data.startIndex + offset)..<end)
        return String(data: slice, encoding: .windowsCP1252) ?? String(data: slice, encoding: .isoLatin1)
    }

    private static func readNulTerminatedUTF16(_ data: Data, at offset: Int) -> String? {
        guard offset >= 0, offset < data.count else { return nil }
        var cursor = data.startIndex + offset
        var end = cursor
        while end + 1 < data.endIndex {
            let lo = data[end]
            let hi = data[end + 1]
            if lo == 0, hi == 0 { break }
            end += 2
        }
        let slice = data.subdata(in: cursor..<end)
        cursor = end
        return String(data: slice, encoding: .utf16LittleEndian)
    }
}
