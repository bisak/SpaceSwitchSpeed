// SpaceSwitchSpeed — speed control for the macOS Space-switch animation.
// Copyright (C) 2026 Biser Atanasov. Licensed under AGPL-3.0-or-later.
// See LICENSE. This program comes with ABSOLUTELY NO WARRANTY.
//
// Derives the symmetric key for one of Apple's AEA-encrypted restore images, so
// `aea decrypt` can open it. macOS 15 and later ship the system image this way.
//
// The archive's prologue names a public key service and carries an HPKE-wrapped
// key; fetching the one and opening the other is the whole job. Nothing here is a
// bypass — Apple publishes the unwrapping key for images it distributes openly.
//
//     swift Scripts/aea-key.swift <file containing the archive's first 64 KiB>

import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("aea-key: \(message)\n".utf8))
    exit(1)
}

guard CommandLine.arguments.count == 2 else { fail("usage: aea-key <aea header file>") }
let header = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
guard header.count > 12, header.prefix(4) == Data("AEA1".utf8) else { fail("not an AEA archive") }

let authLength = Int(header.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self) })
guard 12 + authLength <= header.count else { fail("need the first \(12 + authLength) bytes") }

// The prologue is a run of length-prefixed key\0value pairs.
var metadata: [String: Data] = [:]
var cursor = 12
while cursor + 4 <= 12 + authLength {
    let length = Int(header.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: cursor, as: UInt32.self) })
    guard length >= 4, cursor + length <= 12 + authLength else { break }
    let pair = header[(cursor + 4)..<(cursor + length)]
    if let separator = pair.firstIndex(of: 0) {
        metadata[String(decoding: pair[pair.startIndex..<separator], as: UTF8.self)] =
            Data(pair[(separator + 1)...])
    }
    cursor += length
}

guard let urlBytes = metadata["com.apple.wkms.fcs-key-url"],
    let urlText = String(data: urlBytes, encoding: .utf8),
    let url = URL(string: urlText.trimmingCharacters(in: .whitespacesAndNewlines))
else { fail("no key URL in the prologue; keys were \(metadata.keys.sorted())") }

guard let responseBytes = metadata["com.apple.wkms.fcs-response"],
    let response = try JSONSerialization.jsonObject(with: responseBytes) as? [String: String],
    let encapsulated = response["enc-request"].flatMap({ Data(base64Encoded: $0) }),
    let wrapped = response["wrapped-key"].flatMap({ Data(base64Encoded: $0) })
else { fail("no wrapped key in the prologue") }

var pem = ""
let finished = DispatchSemaphore(value: 0)
URLSession.shared.dataTask(with: url) { data, _, error in
    if let data { pem = String(decoding: data, as: UTF8.self) }
    if let error { FileHandle.standardError.write(Data("aea-key: \(error)\n".utf8)) }
    finished.signal()
}.resume()
finished.wait()
guard pem.contains("PRIVATE KEY") else { fail("the key service did not return a key") }

let privateKey = try P256.KeyAgreement.PrivateKey(pemRepresentation: pem)
var recipient = try HPKE.Recipient(
    privateKey: privateKey, ciphersuite: .P256_SHA256_AES_GCM_256,
    info: Data(), encapsulatedKey: encapsulated)
print(try recipient.open(wrapped).base64EncodedString())
