import Foundation
import Security

/// Code-signing identity checks for the self-updater, using the same notion
/// of identity macOS uses for privacy grants (Screen Recording,
/// Accessibility): the designated requirement. For a build signed with a
/// certificate this pins the bundle ID and that exact certificate, so a
/// different certificate that merely has the same name does not pass.
enum CodeIdentity {
    private static func staticCode(_ path: String) -> SecStaticCode? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, SecCSFlags(), &code) == errSecSuccess else {
            return nil
        }
        return code
    }

    /// The designated requirement of the signed code at `path`, nil if it is
    /// unsigned or unreadable.
    static func designatedRequirement(at path: String) -> SecRequirement? {
        guard let code = staticCode(path) else { return nil }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(code, SecCSFlags(), &requirement) == errSecSuccess else { return nil }
        return requirement
    }

    /// Requirement source text, for logs.
    static func text(_ requirement: SecRequirement) -> String {
        var s: CFString?
        guard SecRequirementCopyString(requirement, SecCSFlags(), &s) == errSecSuccess, let s else { return "?" }
        return s as String
    }

    /// True when the code at `path` has a valid signature that satisfies
    /// `requirement`.
    static func satisfies(_ path: String, requirement: SecRequirement) -> Bool {
        guard let code = staticCode(path) else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate)
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }

    /// True when `candidate` is validly signed by the same identity as
    /// `current` (it satisfies `current`'s designated requirement). False for
    /// ad-hoc builds: their requirement names one exact binary.
    static func sameIdentity(current: String, candidate: String) -> Bool {
        guard let requirement = designatedRequirement(at: current) else { return false }
        return satisfies(candidate, requirement: requirement)
    }
}
