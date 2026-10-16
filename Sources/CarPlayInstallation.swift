import Foundation

// Read-only inspection of this app's own installed files. These values do not grant
// entitlements or verify a CMS signature; iOS performs the authorization checks.
struct CarPlayPermissionReadout: Equatable {
    let audio: Bool?
    let video: Bool?
    let note: String

    static func unknown(_ note: String) -> Self {
        Self(audio: nil, video: nil, note: note)
    }

    static func read(_ entitlements: [String: Any], note: String) -> Self {
        Self(audio: entitlements[CarPlayInstallationReader.audioKey] as? Bool ?? false,
             video: entitlements[CarPlayInstallationReader.videoKey] as? Bool ?? false,
             note: note)
    }
}

enum CarPlayInstallationReader {
    static let audioKey = "com.apple.developer.carplay-audio"
    static let videoKey = "com.apple.developer.carplay-video"

    static func signedPermissions(in executable: Data) -> CarPlayPermissionReadout {
        // Device builds contain a thin, little-endian 64-bit Mach-O executable.
        guard word(executable, 0, littleEndian: true) == 0xfeedfacf,
              let count = word(executable, 16, littleEndian: true),
              let bytes = word(executable, 20, littleEndian: true),
              count <= 4096, executable.count >= 32,
              Int(bytes) <= executable.count - 32 else {
            return .unknown("Executable format could not be inspected.")
        }
        let end = 32 + Int(bytes)
        var offset = 32
        for _ in 0..<Int(count) {
            guard offset <= end - 8,
                  let command = word(executable, offset, littleEndian: true),
                  let length = word(executable, offset + 4, littleEndian: true),
                  length >= 8, Int(length) <= end - offset else {
                return .unknown("Executable load commands could not be inspected.")
            }
            if command == 0x1d { // LC_CODE_SIGNATURE
                guard length >= 16,
                      let start = word(executable, offset + 8, littleEndian: true),
                      let size = word(executable, offset + 12, littleEndian: true),
                      Int(start) <= executable.count,
                      Int(size) <= executable.count - Int(start) else {
                    return .unknown("Embedded signature could not be inspected.")
                }
                let blob = executable.subdata(in: Int(start)..<(Int(start) + Int(size)))
                return signaturePermissions(in: blob)
            }
            offset += Int(length)
        }
        return .unknown("No embedded code signature was found.")
    }

    static func profilePermissions(in profile: Data) -> CarPlayPermissionReadout {
        // CMS .mobileprovision files normally contain an XML property list.
        // Do not expose its certificates, device identifiers, or account details.
        let xmlStart = Data("<?xml".utf8)
        let xmlEnd = Data("</plist>".utf8)
        let plist: Data
        if let start = profile.range(of: xmlStart),
           let end = profile.range(of: xmlEnd, in: start.lowerBound..<profile.endIndex) {
            plist = profile.subdata(in: start.lowerBound..<end.upperBound)
        } else {
            // Also accepts a decoded plist, useful for testing and diagnostics.
            plist = profile
        }
        guard let object = try? PropertyListSerialization.propertyList(from: plist, options: [], format: nil),
              let dictionary = object as? [String: Any],
              let entitlements = dictionary["Entitlements"] as? [String: Any] else {
            return .unknown("Profile format could not be inspected.")
        }
        return .read(entitlements, note: "Read from the embedded profile; iOS checks its validity.")
    }

    private static func signaturePermissions(in signature: Data) -> CarPlayPermissionReadout {
        guard word(signature, 0, littleEndian: false) == 0xfade0cc0,
              let length = word(signature, 4, littleEndian: false),
              let count = word(signature, 8, littleEndian: false),
              length >= 12, Int(length) <= signature.count,
              count <= 1024, Int(count) <= (Int(length) - 12) / 8 else {
            return .unknown("Signature container could not be inspected.")
        }
        var hasDER = false
        for index in 0..<Int(count) {
            guard let position = word(signature, 16 + index * 8, littleEndian: false),
                  Int(position) <= Int(length) - 8,
                  let magic = word(signature, Int(position), littleEndian: false),
                  let size = word(signature, Int(position) + 4, littleEndian: false),
                  size >= 8, Int(size) <= Int(length) - Int(position) else {
                return .unknown("Signature entry could not be inspected.")
            }
            if magic == 0xfade7172 { hasDER = true }
            guard magic == 0xfade7171 else { continue } // XML entitlements
            let data = signature.subdata(in: (Int(position) + 8)..<(Int(position) + Int(size)))
            guard let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
                  let entitlements = object as? [String: Any] else {
                return .unknown("Signed entitlement plist could not be inspected.")
            }
            return .read(entitlements, note: "Read from this installed executable's signature.")
        }
        if hasDER {
            return .unknown("Signature uses DER-only entitlements; this reader cannot decode them.")
        }
        return .read([:], note: "The signature contains no entitlement plist.")
    }

    private static func word(_ data: Data, _ offset: Int, littleEndian: Bool) -> UInt32? {
        guard offset >= 0, data.count >= 4, offset <= data.count - 4 else { return nil }
        let start = data.startIndex + offset
        var value: UInt32 = 0
        if littleEndian {
            for index in 0..<4 { value |= UInt32(data[start + index]) << (index * 8) }
        } else {
            for index in 0..<4 { value = (value << 8) | UInt32(data[start + index]) }
        }
        return value
    }
}
