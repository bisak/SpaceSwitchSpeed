// Space Switch Speed — speed control for the macOS Space-switch animation.
// Copyright (C) 2026 Biser Atanasov. Licensed under AGPL-3.0-or-later.
// See LICENSE. This program comes with ABSOLUTELY NO WARRANTY.

import Foundation
import SpaceSwitchSpeedKit

/// Answers "would Space Switch Speed work on this build of Dock?" without a running
/// Dock, root, or any SIP change, by running the shipping locator over a binary on
/// disk. Point it at a new release's Dock before users find out the hard way.
///
///     swift run dock-check                       # the Dock on this Mac
///     swift run dock-check path/to/Dock          # any extracted binary
///
/// Exit status is 0 when the patch would apply and cleanly revert, 1 when
/// Space Switch Speed would refuse, 2 when the file could not be read at all.

// MARK: - Mach-O, from a file rather than a mapped process

private struct DockBinary {
    let textAddress: UInt64
    let words: [UInt32]
    private let data: Data
    private let sliceOffset: UInt64
    private let segments: [(vmAddress: UInt64, vmSize: UInt64, fileOffset: UInt64)]

    init(path: String) throws {
        data = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
        sliceOffset = try DockBinary.arm64eSlice(data)

        let base = Int(sliceOffset)
        guard data.count > base + 32 else { throw Failure("truncated Mach-O") }
        let commandCount = data.load(UInt32.self, at: base + 16)

        var segments: [(UInt64, UInt64, UInt64)] = []
        var text: (address: UInt64, fileOffset: UInt64, size: UInt64)?
        var offset = base + 32
        for _ in 0..<commandCount {
            guard offset + 8 <= data.count else { break }
            let command = data.load(UInt32.self, at: offset)
            let size = Int(data.load(UInt32.self, at: offset + 4))
            guard size > 0, offset + size <= data.count else { break }
            defer { offset += size }
            guard command == 0x19 else { continue }  // LC_SEGMENT_64

            segments.append(
                (
                    data.load(UInt64.self, at: offset + 24), data.load(UInt64.self, at: offset + 32),
                    data.load(UInt64.self, at: offset + 40)
                ))
            let sectionCount = Int(data.load(UInt32.self, at: offset + 64))
            for index in 0..<sectionCount {
                let section = offset + 72 + index * 80
                guard section + 80 <= data.count, data.name(at: section) == "__text" else { continue }
                text = (
                    data.load(UInt64.self, at: section + 32),
                    UInt64(data.load(UInt32.self, at: section + 48)),
                    data.load(UInt64.self, at: section + 40)
                )
            }
        }

        guard let text else { throw Failure("no __TEXT,__text section") }
        self.segments = segments
        textAddress = text.address

        let start = Int(sliceOffset + text.fileOffset)
        let end = start + Int(text.size)
        guard end <= data.count else { throw Failure("__text runs past the end of the file") }
        words = data[start..<end].withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) }
    }

    /// The tool only ever patches arm64e, so a file without that slice is a hard
    /// error rather than something to guess at.
    private static func arm64eSlice(_ data: Data) throws -> UInt64 {
        let magic = data.load(UInt32.self, at: 0)
        if magic == 0xFEED_FACF { return 0 }  // already a thin 64-bit image
        guard magic == 0xBEBA_FECA || magic == 0xBFBA_FECA else { throw Failure("not a Mach-O") }

        let is64 = magic == 0xBFBA_FECA
        let count = Int(data.load(UInt32.self, at: 4).byteSwapped)
        for index in 0..<count {
            let entry = 8 + index * (is64 ? 32 : 20)
            guard entry + (is64 ? 32 : 20) <= data.count else { break }
            let cpu = data.load(UInt32.self, at: entry).byteSwapped
            let subtype = data.load(UInt32.self, at: entry + 4).byteSwapped & 0x00FF_FFFF
            guard cpu == 0x0100_000C, subtype == 2 else { continue }  // arm64e
            return is64
                ? data.load(UInt64.self, at: entry + 8).byteSwapped
                : UInt64(data.load(UInt32.self, at: entry + 8).byteSwapped)
        }
        throw Failure("no arm64e slice; Space Switch Speed is Apple Silicon only")
    }

    /// Resolves a virtual address to the bytes backing it, for reading constants.
    func double(at address: UInt64) -> Double? {
        for segment in segments where segment.vmAddress != 0 {
            guard address >= segment.vmAddress, address < segment.vmAddress + segment.vmSize else { continue }
            let offset = Int(sliceOffset + segment.fileOffset + (address - segment.vmAddress))
            guard offset + 8 <= data.count else { return nil }
            return data[offset..<(offset + 8)].withUnsafeBytes { $0.loadUnaligned(as: Double.self) }
        }
        return nil
    }
}

private struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

extension Data {
    fileprivate func load<T>(_ type: T.Type, at offset: Int) -> T {
        withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: type) }
    }

    fileprivate func name(at offset: Int) -> String {
        var bytes = [UInt8]()
        for index in 0..<16 {
            let byte = self[offset + index]
            if byte == 0 { break }
            bytes.append(byte)
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

// MARK: - The check

/// Rehearses the whole patch on a copy of `__text`: locate, apply exactly what
/// `apply` would write, locate again, revert exactly what `revert` would write,
/// and require the words to come back identical. Everything the tool does to Dock
/// is exercised except the writes themselves.
private func check(_ dock: DockBinary) throws -> [String] {
    let stock = dock.words
    let sites = try PatchLocator.locate(words: stock, base: dock.textAddress)
    guard sites.state == .stock else {
        throw Failure("this binary already looks patched, which cannot happen on disk")
    }

    guard let retention = dock.double(at: sites.stockRetentionAddress) else {
        throw Failure("the retention constant is not in any mapped segment")
    }
    guard abs(retention - SpringModel.stockRetention) < 1e-9 else {
        throw Failure("retention is \(retention), expected \(SpringModel.stockRetention)")
    }

    var report = [
        "integrator     0x\(hex(sites.gainSite))   gain in d\(sites.errorReg), position in d\(sites.positionReg)",
        "preamble       0x\(hex(sites.adrpSite))   x\(sites.baseReg) -> retention \(retention) at 0x\(hex(sites.stockRetentionAddress))",
        "rubber band    0x\(hex(sites.bandSite))   borrows d\(sites.gainReg)",
    ]

    var words = stock
    func apply(_ edits: [(address: UInt64, word: UInt32)]) {
        for (address, word) in edits { words[Int((address - dock.textAddress) / 4)] = word }
    }

    let scratch = (dock.textAddress &+ 0x1000_0000) & ~0xFFF
    apply(try sites.patchWords(scratch: scratch))

    let patched = try PatchLocator.locate(words: words, base: dock.textAddress)
    guard patched.state == .patched else { throw Failure("the patched loop no longer locates") }
    guard patched.scratchPage == scratch else { throw Failure("the scratch page is not recoverable") }
    guard patched.gainSite == sites.gainSite, patched.bandSite == sites.bandSite else {
        throw Failure("the sites move once patched, so revert would write to the wrong place")
    }

    apply(try patched.stockWords(gainZero: sites.stockGainZeroWord ?? sites.fallbackGainZeroWord))
    guard words == stock else {
        let differing = zip(stock, words).filter { $0 != $1 }.count
        throw Failure("revert leaves \(differing) word(s) changed from stock")
    }

    report.append("round trip     patch and revert restore Apple's words exactly")
    return report
}

private func hex(_ value: UInt64) -> String { String(value, radix: 16) }

// MARK: - Entry point

let arguments = CommandLine.arguments.dropFirst().filter { $0 != "-h" && $0 != "--help" }
if CommandLine.arguments.contains("-h") || CommandLine.arguments.contains("--help") {
    print(
        """
        usage: dock-check [Dock binary | Dock.app]

        Reports whether Space Switch Speed would patch a build of Dock, without a
        running Dock, root, or any SIP change. Defaults to the Dock on this Mac.
        Exits 0 when it would patch, 1 when it would refuse.
        """)
    exit(0)
}

var path = arguments.first ?? DockTarget.executable
if path.hasSuffix(".app") || path.hasSuffix(".app/") {
    path = URL(fileURLWithPath: path).appendingPathComponent("Contents/MacOS/Dock").path
}

let version =
    (try? String(
        contentsOf: URL(fileURLWithPath: path)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Info.plist"), encoding: .isoLatin1))
    .flatMap { plist -> String? in
        guard let range = plist.range(of: "CFBundleVersion") else { return nil }
        let tail = plist[range.upperBound...].prefix(120)
        guard let open = tail.range(of: "<string>"), let close = tail.range(of: "</string>") else {
            return nil
        }
        return String(tail[open.upperBound..<close.lowerBound])
    }

print(version.map { "Dock \($0) — \(path)\n" } ?? "\(path)\n")

do {
    let dock = try DockBinary(path: path)
    for line in try check(dock) { print("  \(line)") }
    print("\nPATCHABLE")
} catch let error as Failure {
    print("  REFUSED: \(error.description)")
    exit(1)
} catch let error as SpaceSwitchSpeedError {
    print("  REFUSED: \(error.description)")
    exit(1)
} catch {
    print("  \(error)")
    exit(2)
}
