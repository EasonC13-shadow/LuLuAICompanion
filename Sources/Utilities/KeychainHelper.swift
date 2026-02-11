import Foundation

/// Helper for API key storage using local JSON file with obfuscation
/// Uses ~/Library/Application Support/LuLuAICompanion/keys.json
/// Keys are XOR-obfuscated so they're not plaintext in the file
enum KeychainHelper {
    
    // XOR obfuscation key (not cryptographically secure, just prevents casual snooping)
    private static let obfuscationKey: [UInt8] = [
        0x4A, 0x7B, 0x2E, 0x91, 0xD3, 0x58, 0xF6, 0x14,
        0xA2, 0x6C, 0x3D, 0x87, 0xE5, 0x49, 0xB0, 0x72,
        0x1F, 0xC8, 0x5A, 0x93, 0xD7, 0x46, 0xEB, 0x38,
        0x84, 0x6F, 0x2B, 0xA1, 0xF3, 0x55, 0xC9, 0x17,
        0x9E, 0x63, 0xD4, 0x48, 0xB7, 0x2A, 0xF1, 0x86,
        0x3C, 0x75, 0xE9, 0x52, 0xAD, 0x41, 0xC6, 0x18,
        0x9B, 0x67, 0xD2, 0x4E, 0xBF, 0x23, 0xFA, 0x85,
        0x39, 0x74, 0xE8, 0x51, 0xAC, 0x40, 0xC5, 0x19
    ]
    
    // MARK: - File Storage Path
    
    private static var storageDir: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("LuLuAICompanion")
    }
    
    private static var keysFile: URL {
        return storageDir.appendingPathComponent("keys.json")
    }
    
    // MARK: - XOR Obfuscation
    
    private static func xorObfuscate(_ input: [UInt8]) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: input.count)
        for i in 0..<input.count {
            output[i] = input[i] ^ obfuscationKey[i % obfuscationKey.count]
        }
        return output
    }
    
    private static func encode(_ value: String) -> String {
        let bytes = Array(value.utf8)
        let obfuscated = xorObfuscate(bytes)
        return Data(obfuscated).base64EncodedString()
    }
    
    private static func decode(_ encoded: String) -> String? {
        guard let data = Data(base64Encoded: encoded) else { return nil }
        let deobfuscated = xorObfuscate(Array(data))
        return String(bytes: deobfuscated, encoding: .utf8)
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
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(store)
            try data.write(to: keysFile, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: keysFile.path
            )
        } catch {
            print("Failed to write keys file: \(error)")
        }
    }
    
    // MARK: - Public API
    
    static func save(key: String, value: String) {
        var store = readStore()
        store[key] = encode(value)
        writeStore(store)
    }
    
    static func get(key: String) -> String? {
        let store = readStore()
        guard let encoded = store[key], !encoded.isEmpty else { return nil }
        return decode(encoded)
    }
    
    static func delete(key: String) {
        var store = readStore()
        store.removeValue(forKey: key)
        writeStore(store)
    }
    
    // MARK: - Cross-Service (no-op, kept for API compat)
    
    static func save(service: String, key: String, value: String) {
        save(key: key, value: value)
    }
    
    static func get(service: String, key: String) -> String? {
        return get(key: key)
    }
    
    static func delete(service: String, key: String) {
        delete(key: key)
    }
    
    // MARK: - Check Own Keys
    
    static func hasOwnAPIKeys() -> Bool {
        if get(key: "claude_api_key") != nil { return true }
        for i in 1...5 {
            if get(key: "claude_api_key_\(i)") != nil { return true }
        }
        return false
    }
}
