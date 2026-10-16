import Foundation

// The reader is Foundation-only, so GitHub can test it before building for iOS.
// Fixtures are synthetic; no CarTV executable, account, or profile is committed.
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

func word(_ value: UInt32, little: Bool = false) -> Data {
    let shifts = little ? [0, 8, 16, 24] : [24, 16, 8, 0]
    return Data(shifts.map { UInt8(truncatingIfNeeded: value >> $0) })
}

func plist(_ value: [String: Any], format: PropertyListSerialization.PropertyListFormat = .xml) -> Data {
    try! PropertyListSerialization.data(fromPropertyList: value, format: format, options: 0)
}

func container(_ payload: Data, derOnly: Bool = false) -> Data {
    let entry = word(derOnly ? 0xfade7172 : 0xfade7171) + word(UInt32(8 + payload.count)) + payload
    return word(0xfade0cc0) + word(UInt32(20 + entry.count)) + word(1)
        + word(derOnly ? 7 : 5) + word(20) + entry
}

func executable(_ signature: Data) -> Data {
    let header: [UInt32] = [0xfeedfacf, 0x0100000c, 0, 2, 1, 16, 0, 0]
    let command: [UInt32] = [0x1d, 16, 48, UInt32(signature.count)]
    return (header + command).reduce(Data()) { $0 + word($1, little: true) } + signature
}

let audioKey = CarPlayInstallationReader.audioKey
let videoKey = CarPlayInstallationReader.videoKey
let reader = CarPlayInstallationReader.self
let both = reader.signedPermissions(in: executable(container(plist([audioKey: true, videoKey: true]))))
check(both.audio == true && both.video == true, "Must read both signed capabilities")
let audio = reader.signedPermissions(in: executable(container(plist([audioKey: true]))))
check(audio.audio == true && audio.video == false, "Audio-only test must not request video")
let empty = reader.signedPermissions(in: executable(container(plist([:]))))
check(empty.audio == false && empty.video == false, "Readable empty entitlements must report absent")
let der = reader.signedPermissions(in: executable(container(Data([0x30, 0]), derOnly: true)))
check(der.audio == nil && der.note.contains("DER"), "Unsupported DER must be unknown, not absent")
check(reader.signedPermissions(in: Data()).audio == nil, "Empty executable must be unknown")
check(reader.signedPermissions(in: Data([0xcf, 0xfa, 0xed, 0xfe])).audio == nil, "Truncated header must be unknown")
var broken = executable(container(plist([audioKey: true])))
broken.replaceSubrange(40..<44, with: word(UInt32.max, little: true))
check(reader.signedPermissions(in: broken).audio == nil, "Out-of-bounds signature must be unknown")
var badEntry = container(plist([audioKey: true]))
badEntry.replaceSubrange(16..<20, with: word(UInt32.max))
check(reader.signedPermissions(in: executable(badEntry)).audio == nil, "Invalid entry offset must be unknown")
check(reader.signedPermissions(in: executable(container(Data("bad XML".utf8)))).audio == nil,
      "Malformed signed plist must be unknown")
let cms = Data([0x30, 0x82, 0xff, 0]) + plist(["Entitlements": [audioKey: true]]) + Data([0, 1, 2])
let profile = reader.profilePermissions(in: cms)
check(profile.audio == true && profile.video == false, "Must find XML within a CMS container")
let binaryProfile = plist(["Entitlements": [audioKey: true, videoKey: true]], format: .binary)
check(reader.profilePermissions(in: binaryProfile).video == true, "Must accept a decoded binary plist")
check(reader.profilePermissions(in: plist(["Entitlements": [:]])).audio == false,
      "Readable empty profile must report absent")
check(reader.profilePermissions(in: plist(["Name": "synthetic"])).audio == nil,
      "Missing profile dictionary must be unknown")
check(reader.profilePermissions(in: Data("<?xml broken".utf8)).audio == nil,
      "Malformed profile must be unknown")

print("CarPlay installation reader: 14 checks passed.")

// The packaging step also checks the actual locally signed icon-test executable.
if CommandLine.arguments.count > 1 {
    let url = URL(fileURLWithPath: CommandLine.arguments[1])
    let actual = reader.signedPermissions(in: try Data(contentsOf: url))
    check(actual.audio == true && actual.video == false,
          "Icon-test executable must contain CarPlay audio only: \(actual.note)")
    print("Actual icon-test executable: CarPlay audio present; CarPlay video absent.")
}
