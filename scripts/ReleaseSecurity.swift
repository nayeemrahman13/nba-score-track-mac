import Foundation
import Security
import CryptoKit

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.count == 4, arguments[0] == "verify" {
    do {
        guard let keyData = Data(base64Encoded: arguments[2]),
              let signature = Data(base64Encoded: arguments[3]), signature.count == 64 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
        let data = try Data(contentsOf: URL(fileURLWithPath: arguments[1]), options: .mappedIfSafe)
        guard key.isValidSignature(signature, for: data) else {
            fputs("Invalid Ed25519 signature: \(arguments[1])\n", stderr)
            exit(1)
        }
        exit(0)
    } catch {
        fputs("Cannot verify signature: \(error)\n", stderr)
        exit(1)
    }
}
guard arguments.count == 2, arguments[0] == "entitlements" else {
    fputs("Usage: ReleaseSecurity entitlements APP_OR_EXECUTABLE | verify FILE PUBLIC_KEY SIGNATURE\n", stderr)
    exit(1)
}
let url = URL(fileURLWithPath: arguments[1])
var code: SecStaticCode?
let createStatus = SecStaticCodeCreateWithPath(url as CFURL, [], &code)
guard createStatus == errSecSuccess, let code else {
    fputs("Cannot read code signature: \(createStatus)\n", stderr)
    exit(1)
}
var information: CFDictionary?
let infoStatus = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
guard infoStatus == errSecSuccess, let information else {
    fputs("Cannot read signing information: \(infoStatus)\n", stderr)
    exit(1)
}
let dictionary = information as NSDictionary
let entitlements = dictionary[kSecCodeInfoEntitlementsDict] as? [String: Any] ?? [:]
let data = try PropertyListSerialization.data(fromPropertyList: entitlements, format: .xml, options: 0)
FileHandle.standardOutput.write(data)
