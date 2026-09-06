// SpaceSwitchSpeed — speed control for the macOS Space-switch animation.
// Copyright (C) 2026 Biser Atanasov. Licensed under AGPL-3.0-or-later.
// See LICENSE. This program comes with ABSOLUTELY NO WARRANTY.

import Darwin
import Foundation

public enum SpaceSwitchSpeedError: Error, CustomStringConvertible {
    case needsRoot
    case notPermitted(kern_return_t)
    case machFailure(String, kern_return_t)
    case imageNotFound
    case signatureNotFound
    case unexpectedConstants(String)
    case noReachableScratch
    case encodingFailed(String)
    case verificationFailed(String)

    public var description: String {
        switch self {
        case .needsRoot:
            return "This needs to run as root."
        case .notPermitted(let kr):
            return """
                Cannot open Dock's task port (kern error \(kr)). \
                This needs System Integrity Protection disabled and root privileges.
                """
        case .machFailure(let op, let kr):
            return "\(op) failed: \(String(cString: mach_error_string(kr))) (\(kr))"
        case .imageNotFound:
            return "Could not locate Dock's Mach-O image in memory."
        case .signatureNotFound:
            return """
                The Space-switch integrator was not found in this build of Dock. \
                SpaceSwitchSpeed refuses to write to an address it has not positively \
                identified. Please file an issue with your macOS version.
                """
        case .unexpectedConstants(let detail):
            return "Dock's spring constants are not what this version expects: \(detail)"
        case .noReachableScratch:
            return "Could not allocate scratch memory within adrp range of the patch site."
        case .encodingFailed(let what):
            return "Could not encode \(what)."
        case .verificationFailed(let what):
            return "Patch verification failed: \(what)"
        }
    }
}

/// A handle on one running Dock's address space.
public final class DockTarget {
    public static let executable = "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock"

    public let pid: pid_t
    public let task: mach_port_t

    public init(pid: pid_t) throws {
        self.pid = pid
        var port = mach_port_t()
        let kr = task_for_pid(mach_task_self_, pid, &port)
        guard kr == KERN_SUCCESS else { throw SpaceSwitchSpeedError.notPermitted(kr) }
        self.task = port
    }

    deinit { mach_port_deallocate(mach_task_self_, task) }

    /// Every running Dock. Each logged-in user has one, so fast user switching
    /// means several.
    public static func findDocks() -> [pid_t] { Processes.pids(runningExecutable: executable) }

    // MARK: - Memory

    public func read(_ address: UInt64, _ count: Int) throws -> Data {
        var buffer = Data(count: count)
        var got = mach_vm_size_t(0)
        let kr: kern_return_t = buffer.withUnsafeMutableBytes { raw in
            mach_vm_read_overwrite(
                task, mach_vm_address_t(address), mach_vm_size_t(count),
                mach_vm_address_t(UInt(bitPattern: raw.baseAddress)), &got)
        }
        guard kr == KERN_SUCCESS else {
            throw SpaceSwitchSpeedError.machFailure("read at 0x\(String(address, radix: 16))", kr)
        }
        guard Int(got) == count else { throw SpaceSwitchSpeedError.machFailure("short read", KERN_FAILURE) }
        return buffer
    }

    public func write(_ address: UInt64, _ data: Data) throws {
        // __TEXT is mapped read-execute and shared copy-on-write. Requesting
        // VM_PROT_COPY forces a private copy so the write cannot reach the file
        // or any other process mapping the same page.
        let kr = mach_vm_protect(
            task, mach_vm_address_t(address), mach_vm_size_t(data.count), 0,
            VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY)
        guard kr == KERN_SUCCESS else { throw SpaceSwitchSpeedError.machFailure("protect", kr) }
        let wrote: kern_return_t = data.withUnsafeBytes { raw in
            mach_vm_write(
                task, mach_vm_address_t(address),
                vm_offset_t(UInt(bitPattern: raw.baseAddress)), mach_msg_type_number_t(data.count))
        }
        guard wrote == KERN_SUCCESS else { throw SpaceSwitchSpeedError.machFailure("write", wrote) }
        _ = mach_vm_protect(
            task, mach_vm_address_t(address), mach_vm_size_t(data.count), 0,
            VM_PROT_READ | VM_PROT_EXECUTE)
    }

    public func readDouble(_ address: UInt64) throws -> Double {
        try read(address, 8).withUnsafeBytes { $0.loadUnaligned(as: Double.self) }
    }

    public func readWord(_ address: UInt64) throws -> UInt32 {
        try read(address, 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
    }

    public func writeWord(_ address: UInt64, _ word: UInt32) throws {
        try write(address, withUnsafeBytes(of: word) { Data($0) })
    }

    public func writeDouble(_ address: UInt64, _ value: Double) throws {
        try write(address, withUnsafeBytes(of: value) { Data($0) })
    }

    /// Reserves a page of read/write scratch inside the target. The hint puts it
    /// beside the patch site, which one `adrp` has to be able to reach.
    public func allocateScratch(near hint: UInt64) throws -> UInt64 {
        var address = mach_vm_address_t(hint & ~0xFFF)
        let kr = mach_vm_allocate(task, &address, 0x4000, VM_FLAGS_ANYWHERE)
        guard kr == KERN_SUCCESS else { throw SpaceSwitchSpeedError.machFailure("allocate", kr) }
        guard abs(Int64(bitPattern: address) - Int64(bitPattern: hint)) < (1 << 32) else {
            _ = mach_vm_deallocate(task, address, 0x4000)
            throw SpaceSwitchSpeedError.noReachableScratch
        }
        return UInt64(address)
    }

    public func freeScratch(_ address: UInt64) {
        _ = mach_vm_deallocate(task, mach_vm_address_t(address), 0x4000)
    }
}
