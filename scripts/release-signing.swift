import CryptoKit
import Foundation
import Security

// Private material enters only through stdin. Never print CFError descriptions,
// imported items, passwords, or the input envelope, including on failure.
enum SigningFailure: Error {
    case invalid(String)
    case security(String, OSStatus)
}

func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw SigningFailure.invalid(message) }
}

func check(_ status: OSStatus, _ operation: String) throws {
    if status != errSecSuccess { throw SigningFailure.security(operation, status) }
}

func certificate(at path: String) throws -> (SecCertificate, Data, String) {
    let url = URL(fileURLWithPath: path)
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    try require(values.isRegularFile == true && values.isSymbolicLink != true, "The pinned certificate must be a regular DER file.")
    let data = try Data(contentsOf: url, options: .mappedIfSafe)
    try require(data.count <= 64 * 1024, "The pinned certificate is too large.")
    guard let certificate = SecCertificateCreateWithData(nil, data as CFData) else {
        throw SigningFailure.invalid("The pinned certificate is not valid DER.")
    }
    var commonName: CFString?
    try check(SecCertificateCopyCommonName(certificate, &commonName), "read certificate name")
    try require(commonName as String? == "AgentSwap Release Signing", "The pinned certificate has an unexpected name.")
    let fingerprint = Insecure.SHA1.hash(data: data).map { String(format: "%02X", $0) }.joined()
    return (certificate, data, fingerprint)
}

func pinnedRequirement(_ fingerprint: String) throws -> SecRequirement {
    let text = "identifier \"net.mercen.agentswap\" and certificate leaf = H\"\(fingerprint)\""
    var requirement: SecRequirement?
    try check(SecRequirementCreateWithString(text as CFString, [], &requirement), "create pinned requirement")
    guard let requirement else { throw SigningFailure.invalid("The pinned requirement was not created.") }
    return requirement
}

func openKeychain(_ path: String) throws -> SecKeychain {
    var keychain: SecKeychain?
    try check(SecKeychainOpen(path, &keychain), "open release keychain")
    guard let keychain else { throw SigningFailure.invalid("The release keychain was not opened.") }
    return keychain
}

func preflight(_ certificatePath: String, _ keychainPath: String) throws -> String {
    let (_, expectedDER, fingerprint) = try certificate(at: certificatePath)
    let keychain = try openKeychain(keychainPath)
    let query: [String: Any] = [
        kSecClass as String: kSecClassIdentity,
        kSecMatchSearchList as String: [keychain],
        kSecMatchLimit as String: kSecMatchLimitAll,
        kSecReturnRef as String: true,
        kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
    ]
    var result: CFTypeRef?
    try check(SecItemCopyMatching(query as CFDictionary, &result), "find release signing identity")
    guard let identities = result as? [SecIdentity] else {
        throw SigningFailure.invalid("No release signing identity was returned.")
    }
    var matching = 0
    for identity in identities {
        var leaf: SecCertificate?
        try check(SecIdentityCopyCertificate(identity, &leaf), "read signing identity certificate")
        if let leaf, SecCertificateCopyData(leaf) as Data == expectedDER {
            var privateKey: SecKey?
            try check(SecIdentityCopyPrivateKey(identity, &privateKey), "find release private key")
            try require(privateKey != nil, "The pinned certificate has no private key.")
            matching += 1
        }
    }
    try require(matching == 1, "The release keychain must contain exactly one identity matching the pinned certificate.")
    return fingerprint
}

func verify(_ appPath: String, _ certificatePath: String) throws {
    let (_, expectedDER, fingerprint) = try certificate(at: certificatePath)
    let expected = try pinnedRequirement(fingerprint)
    var code: SecStaticCode?
    try check(SecStaticCodeCreateWithPath(URL(fileURLWithPath: appPath) as CFURL, [], &code), "open signed application")
    guard let code else { throw SigningFailure.invalid("The signed application was not opened.") }
    try check(SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode | kSecCSCheckAllArchitectures), expected), "validate pinned application signature")
    var information: CFDictionary?
    try check(SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information), "inspect application signature")
    guard let information = information as? [String: Any],
          let certificates = information[kSecCodeInfoCertificates as String] as? [SecCertificate],
          let leaf = certificates.first,
          let flags = information[kSecCodeInfoFlags as String] as? UInt32 else {
        throw SigningFailure.invalid("The application must have a certificate signature.")
    }
    try require(flags & 0x2 == 0, "Ad-hoc release signatures are forbidden.")
    try require(information[kSecCodeInfoIdentifier as String] as? String == "net.mercen.agentswap", "The application identifier is incorrect.")
    try require(SecCertificateCopyData(leaf) as Data == expectedDER, "The application signing certificate does not match the public pin.")
    var designated: SecRequirement?
    try check(SecCodeCopyDesignatedRequirement(code, [], &designated), "read designated requirement")
    guard let designated else { throw SigningFailure.invalid("The application has no designated requirement.") }
    var actualData: CFData?
    var expectedData: CFData?
    try check(SecRequirementCopyData(designated, [], &actualData), "encode designated requirement")
    try check(SecRequirementCopyData(expected, [], &expectedData), "encode pinned requirement")
    try require(actualData as Data? == expectedData as Data?, "The embedded designated requirement must pin the release certificate and application identifier exactly.")
}

struct ImportEnvelope: Decodable {
    let p12: String
    let password: String
}

func createKeychain(_ path: String, _ certificatePath: String) throws {
    _ = try certificate(at: certificatePath)
    try require(!FileManager.default.fileExists(atPath: path), "The release keychain path already exists.")
    var input = Data()
    while let chunk = try FileHandle.standardInput.read(upToCount: 64 * 1024), !chunk.isEmpty {
        try require(input.count + chunk.count <= 16 * 1024 * 1024, "The signing input is too large.")
        input.append(chunk)
    }
    let envelope: ImportEnvelope
    do { envelope = try JSONDecoder().decode(ImportEnvelope.self, from: input) }
    catch { throw SigningFailure.invalid("The signing input is malformed.") }
    guard let p12 = Data(base64Encoded: envelope.p12), !p12.isEmpty, p12.count <= 8 * 1024 * 1024 else {
        throw SigningFailure.invalid("The signing archive is malformed.")
    }
    var random = [UInt8](repeating: 0, count: 48)
    try check(SecRandomCopyBytes(kSecRandomDefault, random.count, &random), "generate temporary keychain password")
    let password = random.map { String(format: "%02x", $0) }.joined()
    var keychain: SecKeychain?
    try password.withCString { bytes in
        try check(SecKeychainCreate(path, UInt32(password.utf8.count), bytes, false, nil, &keychain), "create temporary release keychain")
    }
    guard let keychain else { throw SigningFailure.invalid("The temporary release keychain was not created.") }
    var completed = false
    defer { if !completed { SecKeychainDelete(keychain) } }
    try password.withCString { bytes in
        try check(SecKeychainUnlock(keychain, UInt32(password.utf8.count), bytes, true), "unlock temporary release keychain")
    }
    var codesign: SecTrustedApplication?
    try check(SecTrustedApplicationCreateFromPath("/usr/bin/codesign", &codesign), "identify Apple codesign")
    guard let codesign else { throw SigningFailure.invalid("Apple codesign was not identified.") }
    var access: SecAccess?
    try check(SecAccessCreate("AgentSwap release signing" as CFString, [codesign] as CFArray, &access), "create signing access")
    guard let access else { throw SigningFailure.invalid("The signing access was not created.") }
    let options: [String: Any] = [
        kSecImportExportPassphrase as String: envelope.password,
        kSecImportExportKeychain as String: keychain,
        kSecImportExportAccess as String: access,
    ]
    var imported: CFArray?
    try check(SecPKCS12Import(p12 as CFData, options as CFDictionary, &imported), "import release signing identity")
    _ = try preflight(certificatePath, path)
    // Import may replace initial partition ACLs. Apple's tool uses an SPI for
    // authenticated partition updates, so pass its interactive command on stdin
    // instead of exposing a keychain password in argv or declaring private APIs.
    // This command targets only this newly-created disposable signing keychain.
    try require(path.range(of: #"^/[A-Za-z0-9_./-]+$"#, options: .regularExpression) != nil, "The temporary keychain path contains unsupported characters.")
    for command in [
        "set-keychain-settings -lut 21600 \(path)",
        "set-key-partition-list -S apple-tool:,apple: -s -k \(password) \(path)",
    ] {
        let tool = Process()
        tool.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        tool.arguments = ["-i", "-q"]
        tool.environment = ["PATH": "/usr/bin:/bin", "LANG": "C"]
        let toolInput = Pipe()
        tool.standardInput = toolInput
        tool.standardOutput = FileHandle.nullDevice
        tool.standardError = FileHandle.nullDevice
        try tool.run()
        toolInput.fileHandleForWriting.write(Data("\(command)\n".utf8))
        try toolInput.fileHandleForWriting.close()
        tool.waitUntilExit()
        try require(tool.terminationReason == .exit && tool.terminationStatus == 0, "Apple security could not configure the temporary signing keychain.")
    }
    var settings = SecKeychainSettings()
    try check(SecKeychainCopySettings(keychain, &settings), "verify temporary signing keychain settings")
    try require(!settings.useLockInterval.boolValue || settings.lockInterval >= 21600, "The temporary signing keychain would lock before release packaging completes.")
    completed = true
}

do {
    try check(SecKeychainSetUserInteractionAllowed(false), "disable interactive signing prompts")
    let arguments = CommandLine.arguments
    try require(arguments.count >= 3, "A release signing command and path are required.")
    switch arguments[1] {
    case "fingerprint":
        try require(arguments.count == 3, "fingerprint requires the pinned certificate path.")
        print(try certificate(at: arguments[2]).2)
    case "preflight":
        try require(arguments.count == 4, "preflight requires certificate and keychain paths.")
        print(try preflight(arguments[2], arguments[3]))
    case "verify":
        try require(arguments.count == 4, "verify requires application and certificate paths.")
        try verify(arguments[2], arguments[3])
    case "create-keychain":
        try require(arguments.count == 4, "create-keychain requires keychain and certificate paths.")
        try createKeychain(arguments[2], arguments[3])
    case "delete-keychain":
        try require(arguments.count == 3, "delete-keychain requires a keychain path.")
        if FileManager.default.fileExists(atPath: arguments[2]) {
            try check(SecKeychainDelete(try openKeychain(arguments[2])), "delete temporary release keychain")
        }
    default: throw SigningFailure.invalid("Unknown release signing command.")
    }
} catch SigningFailure.invalid(let message) {
    FileHandle.standardError.write(Data("Release signing: \(message)\n".utf8))
    exit(1)
} catch SigningFailure.security(let operation, let status) {
    FileHandle.standardError.write(Data("Release signing: could not \(operation) (OSStatus \(status)).\n".utf8))
    exit(1)
} catch {
    FileHandle.standardError.write(Data("Release signing: the operation failed.\n".utf8))
    exit(1)
}
