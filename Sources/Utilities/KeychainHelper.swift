import Foundation
import Security

/// Helper for API key storage using local JSON file
/// Uses ~/Library/Application Support/LuLuAICompanion/keys.json
/// Falls back to reading from Keychain for migration from older versions
enum KeychainHelper {
    
    private static let defaultService = "com.lulu-ai-companion"
    
    // MARK: - File Storage Path
    
    private static var storageDir: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("LuLuAICompanion")
    }
    
    private static var keysFile: URL {
        return storageDir.appendingPathComponent("keys.json")
    }
    
    // MARK: - JSON File Operations
    
    private static func readStore() -> [String: String] {
        guard let data = try? Data(contentsOf: keysFile),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return dict
    }
    
    private static func writeStore(_ store: [String: String]) {
        do {
            try FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(store)
            try data.write(to: keysFile, options: [.atomic])
            // Set file permissions to owner-only (600)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: keysFile.path
            )
        } catch {
            print("Failed to write keys file: \(error)")
        }
    }
    
    // MARK: - Standard Operations
    
    static func save(key: String, value: String) {
        var store = readStore()
        store[key] = value
        writeStore(store)
    }
    
    static func get(key: String) -> String? {
        // Try file first
        let store = readStore()
        if let value = store[key], !value.isEmpty {
            return value
        }
        
        // Fall back to Keychain (migration from older versions)
        if let value = getFromKeychain(service: defaultService, key: key), !value.isEmpty {
            // Migrate to file storage
            var store = readStore()
            store[key] = value
            writeStore(store)
            return value
        }
        
        return nil
    }
    
    static func delete(key: String) {
        var store = readStore()
        store.removeValue(forKey: key)
        writeStore(store)
        // Also clean up Keychain if it exists there
        deleteFromKeychain(service: defaultService, key: key)
    }
    
    // MARK: - Cross-Service Operations (for reading OpenClaw's keychain)
    
    static func save(service: String, key: String, value: String) {
        if service == defaultService {
            save(key: key, value: value)
        } else {
            saveToKeychain(service: service, key: key, value: value)
        }
    }
    
    static func get(service: String, key: String) -> String? {
        if service == defaultService {
            return get(key: key)
        }
        return getFromKeychain(service: service, key: key)
    }
    
    static func delete(service: String, key: String) {
        if service == defaultService {
            delete(key: key)
        } else {
            deleteFromKeychain(service: service, key: key)
        }
    }
    
    // MARK: - Check Own Keys
    
    static func hasOwnAPIKeys() -> Bool {
        if get(key: "claude_api_key") != nil { return true }
        for i in 1...5 {
            if get(key: "claude_api_key_\(i)") != nil { return true }
        }
        return false
    }
    
    // MARK: - Legacy Keychain Operations (for migration & cross-service)
    
    private static func saveToKeychain(service: String, key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        deleteFromKeychain(service: service, key: key)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: service,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]
        SecItemAdd(query as CFDictionary, nil)
    }
    
    private static func getFromKeychain(service: String, key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }
    
    private static func deleteFromKeychain(service: String, key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: service
        ]
        SecItemDelete(query as CFDictionary)
    }
}
