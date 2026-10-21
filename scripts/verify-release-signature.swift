import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("Release signature: \(message)\n".utf8))
    exit(1)
}

guard CommandLine.arguments.count == 4 else {
    fail("Expected application Info.plist, archive, and public EdDSA signature.")
}

do {
    let plistData = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    let value = try PropertyListSerialization.propertyList(from: plistData, format: nil)
    guard let dictionary = value as? [String: Any],
          let encodedKey = dictionary["SUPublicEDKey"] as? String,
          let publicKeyData = Data(base64Encoded: encodedKey), publicKeyData.count == 32,
          let signature = Data(base64Encoded: CommandLine.arguments[3]), signature.count == 64 else {
        fail("The application public key or archive signature is invalid.")
    }
    let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
    let archive = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]), options: .mappedIfSafe)
    guard publicKey.isValidSignature(signature, for: archive) else {
        fail("The archive signature does not match the public key embedded in the application.")
    }
    print("Archive signature matches the application's public key.")
} catch {
    fail("Could not verify the archive with the application's public key.")
}
