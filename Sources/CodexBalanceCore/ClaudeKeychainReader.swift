import Foundation
import Security
import CryptoKit

/// Read only the current user's Claude entry through the already-trusted Apple tool.
/// Inspect metadata first; never ask the user to unlock a keychain or change its ACL.
enum ClaudeKeychainReader {
  static let service = "Claude Code-credentials"

  static func dedicatedService(configHome: URL) -> String {
    let digest = SHA256.hash(data: Data(configHome.path.precomposedStringWithCanonicalMapping.utf8))
    return service + "-" + digest.map { String(format: "%02x", $0) }.joined().prefix(8)
  }

  static func read(service: String = service) -> Data? {
    guard securityToolIsTrusted(service: service) else { return nil }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    process.arguments = ["find-generic-password", "-s", service, "-a", NSUserName(), "-w"]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    let finished = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in finished.signal() }
    do { try process.run() } catch { return nil }
    // Drain while the process runs so a large MCP credential record cannot fill the pipe.
    let bytes = ClaudeKeychainDataBox()
    let drained = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .utility).async {
      bytes.data = output.fileHandleForReading.readDataToEndOfFile()
      drained.signal()
    }
    guard finished.wait(timeout: .now() + 3) == .success else {
      process.terminate()
      return nil
    }
    guard drained.wait(timeout: .now() + 1) == .success, process.terminationStatus == 0 else { return nil }
    return bytes.data
  }

  static func securityToolIsTrusted(service: String = service) -> Bool {
    // This legacy-keychain switch applies only to our process, including the metadata APIs below.
    SecKeychainSetUserInteractionAllowed(false)
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: NSUserName(),
      kSecReturnRef as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne
    ]
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
          let result, CFGetTypeID(result) == SecKeychainItemGetTypeID() else { return false }
    let item = result as! SecKeychainItem
    var keychain: SecKeychain?
    var status: SecKeychainStatus = 0
    guard SecKeychainItemCopyKeychain(item, &keychain) == errSecSuccess,
          SecKeychainGetStatus(keychain, &status) == errSecSuccess,
          status & UInt32(kSecUnlockStateStatus) != 0 else { return false }
    var access: SecAccess?
    var list: CFArray?
    guard SecKeychainItemCopyAccess(item, &access) == errSecSuccess, let access,
          SecAccessCopyACLList(access, &list) == errSecSuccess else { return false }
    for acl in list as? [SecACL] ?? [] {
      let rights = SecACLCopyAuthorizations(acl) as? [String] ?? []
      guard rights.contains(kSecACLAuthorizationDecrypt as String) else { continue }
      var apps: CFArray?
      var description: CFString?
      var flags = SecKeychainPromptSelector(rawValue: 0)
      guard SecACLCopyContents(acl, &apps, &description, &flags) == errSecSuccess,
            flags.rawValue & SecKeychainPromptSelector.requirePassphase.rawValue == 0 else { continue }
      for app in apps as? [SecTrustedApplication] ?? [] {
        var data: CFData?
        guard SecTrustedApplicationCopyData(app, &data) == errSecSuccess, let data else { continue }
        let path = String(decoding: data as Data, as: UTF8.self).trimmingCharacters(in: .controlCharacters)
        if path == "/usr/bin/security" { return true }
      }
    }
    return false
  }
}

private final class ClaudeKeychainDataBox: @unchecked Sendable {
  // Written once before the semaphore signals, read only after that signal.
  var data = Data()
}
