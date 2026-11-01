import Collaboration
import Foundation
import Security

// The Team ID this process is signed with; nil when it's signed ad hoc.
func ownTeamID() -> String? {
    var code: SecCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
    var info: CFDictionary?
    guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
          let info = info as? [String: Any] else { return nil }
    return info[kSecCodeInfoTeamIdentifier as String] as? String
}

// A code requirement for code signed by this team as identifier. Release builds also require Developer ID, which a
// developer's own Apple Development certificate doesn't meet, and no get-task-allow, so a debugger can't be attached to
// what they trust. Debug builds accept development builds, to work from Xcode.
func signingRequirement(identifier: String, team: String) -> String {
    let base = "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
    #if DEBUG
    return base
    #else
    return base + " and certificate 1[field.1.2.840.113635.100.6.2.6] exists" // Developer ID intermediate
        + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists" // Developer ID Application leaf
        + " and !(entitlement[\"com.apple.security.get-task-allow\"] exists)"
    #endif
}

// Whether the code at url is signed by this team as identifier, per signingRequirement.
func isSigned(_ url: URL, identifier: String, team: String) -> Bool {
    var code: SecStaticCode?
    var requirement: SecRequirement?
    guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
          SecRequirementCreateWithString(signingRequirement(identifier: identifier, team: team) as CFString, [], &requirement) == errSecSuccess
    else { return false }
    let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
    return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
}

// Whether the macOS user uid is an administrator: a member of the admin group, directly or through another group.
func isAdministrator(_ uid: uid_t) -> Bool {
    guard let user = CBUserIdentity(posixUID: uid, authority: .default()),
          let admin = CBGroupIdentity(posixGID: 80, authority: .default()) else { return false } // 80: admin
    return user.isMember(ofGroup: admin)
}
