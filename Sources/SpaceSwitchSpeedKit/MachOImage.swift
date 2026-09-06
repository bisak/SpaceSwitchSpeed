// SpaceSwitchSpeed — speed control for the macOS Space-switch animation.
// Copyright (C) 2026 Biser Atanasov. Licensed under AGPL-3.0-or-later.
// See LICENSE. This program comes with ABSOLUTELY NO WARRANTY.

import Darwin
import Foundation
import MachO

/// Dock's Mach-O as it is actually mapped, parsed out of the live process.
///
/// Reading the mapped image rather than the file on disk means the addresses
/// need no slide arithmetic and the tool can never be fooled by a binary that
/// differs from the one currently running.
public struct MachOImage {
    /// The only section this tool reads.
    public let text: (address: UInt64, size: UInt64)

    public init(target: DockTarget) throws {
        guard let base = try MachOImage.findMainExecutable(target) else {
            throw SpaceSwitchSpeedError.imageNotFound
        }

        let header = try target.read(base, 32)
        let ncmds = header.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 16, as: UInt32.self) }
        let sizeofcmds = header.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 20, as: UInt32.self) }
        let commands = try target.read(base + 32, Int(sizeofcmds))

        var found: (address: UInt64, size: UInt64)?
        var textVMAddr: UInt64?
        commands.withUnsafeBytes { raw in
            var offset = 0
            for _ in 0..<ncmds {
                guard offset + 8 <= raw.count else { break }
                let cmd = raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
                let cmdsize = Int(raw.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self))
                guard cmdsize > 0, offset + cmdsize <= raw.count else { break }

                if cmd == UInt32(LC_SEGMENT_64), MachOImage.name(raw, offset + 8) == "__TEXT" {
                    textVMAddr = raw.loadUnaligned(fromByteOffset: offset + 24, as: UInt64.self)
                    let nsects = Int(raw.loadUnaligned(fromByteOffset: offset + 64, as: UInt32.self))
                    for s in 0..<nsects {
                        let so = offset + 72 + s * 80
                        guard so + 80 <= raw.count else { break }
                        guard MachOImage.name(raw, so) == "__text" else { continue }
                        found = (
                            address: raw.loadUnaligned(fromByteOffset: so + 32, as: UInt64.self),
                            size: raw.loadUnaligned(fromByteOffset: so + 40, as: UInt64.self)
                        )
                    }
                }
                offset += cmdsize
            }
        }

        guard let linked = textVMAddr, let found else { throw SpaceSwitchSpeedError.imageNotFound }
        text = (address: found.address &+ (base &- linked), size: found.size)
    }

    private static func name(_ raw: UnsafeRawBufferPointer, _ offset: Int) -> String {
        var bytes = [UInt8]()
        for i in 0..<16 {
            let b = raw.load(fromByteOffset: offset + i, as: UInt8.self)
            if b == 0 { break }
            bytes.append(b)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Walks the target's regions for the one carrying an `MH_EXECUTE` header.
    /// A process has exactly one, so the match is unambiguous.
    private static func findMainExecutable(_ target: DockTarget) throws -> UInt64? {
        var address = mach_vm_address_t(0)
        var size = mach_vm_size_t(0)
        var objectName = mach_port_t()

        while true {
            var info = vm_region_basic_info_data_64_t()
            var count = mach_msg_type_number_t(MemoryLayout<vm_region_basic_info_data_64_t>.size / 4)
            let kr = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: Int32.self, capacity: Int(count)) {
                    mach_vm_region(
                        target.task, &address, &size, VM_REGION_BASIC_INFO_64, $0, &count, &objectName)
                }
            }
            guard kr == KERN_SUCCESS else { return nil }

            if info.protection & VM_PROT_EXECUTE != 0,
                let header = try? target.read(UInt64(address), 16)
            {
                let magic = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
                let filetype = header.withUnsafeBytes {
                    $0.loadUnaligned(fromByteOffset: 12, as: UInt32.self)
                }
                if magic == MH_MAGIC_64 && filetype == UInt32(MH_EXECUTE) { return UInt64(address) }
            }
            address += size
        }
    }

}
