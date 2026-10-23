import Foundation
#if os(macOS)
import Security
#endif

/// Outcome of one Keychain lookup. The password bytes stay in memory and are
/// never logged, written to disk, or put in UserDefaults.
enum CursorKeychainPasswordResult: Sendable, Equatable {
    case password(Data)
    case denied
    case notFound
}

/// OSStatus values `SecItemCopyMatching` returns for this lookup.
/// Denial and a missing item are different: a missing item does not mean the
/// user clicked Don't Allow.
enum CursorKeychainAccess {
    static let success: Int32 = 0
    static let userCanceled: Int32 = -128
    static let authFailed: Int32 = -25293
    static let interactionNotAllowed: Int32 = -25308
    static let itemNotFound: Int32 = -25300

    static func result(status: Int32, data: Data?) -> CursorKeychainPasswordResult {
        switch status {
        case success:
            guard let data, !data.isEmpty else { return .notFound }
            return .password(data)
        case userCanceled, authFailed, interactionNotAllowed:
            return .denied
        case itemNotFound:
            return .notFound
        default:
            return .denied
        }
    }
}

/// Chromium/Electron safeStorage on macOS, for `cursorAuth/accessToken` only.
///
/// Cursor 3.27.6 ships Electron 42.11.16. On macOS that build sets the
/// Keychain service to `Browser::GetName() + " Safe Storage"` and the account
/// base to the same name (`electron_browser_main_parts.cc`). `app.setName` is
/// not called. `product.json` nameShort and nameLong are both `Cursor`, and
/// `GetApplicationName()` is the Info.plist bundle name, so the service is
/// `Cursor Safe Storage`.
///
/// Electron's os_crypt patch looks up `account + " Key"` first (non-Mac App
/// Store suffix) and, only when that item is missing, the unsuffixed legacy
/// account. This app does not create a Keychain item and does not use the
/// App Store account.
///
/// The sqlite value is `cursor-safe-storage:v1:` plus standard base64 of
/// `v10` and AES-128-CBC ciphertext. The key is PBKDF2-HMAC-SHA1 of the
/// Keychain password, salt `saltysalt`, 1003 iterations, 16 bytes. The IV is
/// 16 spaces. `cursorAuth/refreshToken` is never read.
enum CursorSafeStorage {
    static let envelopePrefix = "cursor-safe-storage:v1:"
    static let service = "Cursor Safe Storage"
    static let account = "Cursor Key"
    static let legacyAccount = "Cursor"
    /// Shown in the macOS Allow sheet and in the menu when that sheet is denied.
    static let prompt = "Allow Keychain access to read Cursor usage"

    static func isEnvelope(_ stored: String) -> Bool {
        stored.hasPrefix(envelopePrefix)
    }

    /// Primary account first. The legacy account is tried only when the
    /// primary item does not exist, so a denial does not prompt a second time.
    static func resolve(
        primary: CursorKeychainPasswordResult,
        legacy: () -> CursorKeychainPasswordResult
    ) -> CursorKeychainPasswordResult {
        if case .notFound = primary {
            return legacy()
        }
        return primary
    }

    static func deriveKey(_ password: Data) -> Data {
        let salt = Array("saltysalt".utf8)
        return Data(PBKDF2SHA1.derive(
            password: [UInt8](password),
            salt: salt,
            iterations: 1003,
            length: 16
        ))
    }

    /// AES-128-CBC decrypt. Strips a leading `v10` when present. `nil` when
    /// the bytes are not valid PKCS7 plaintext.
    static func decrypt(ciphertext: Data, password: Data) -> Data? {
        var bytes = [UInt8](ciphertext)
        if bytes.starts(with: [0x76, 0x31, 0x30]) {
            bytes.removeFirst(3)
        }
        guard let plain = AES128CBC.decrypt(
            bytes,
            key: [UInt8](deriveKey(password)),
            iv: [UInt8](repeating: 0x20, count: 16)
        ) else { return nil }
        return Data(plain)
    }

    /// Plaintext UTF-8 from a `cursor-safe-storage:v1:` value. `nil` when the
    /// envelope cannot be opened. Callers must not log the result.
    static func openEnvelope(_ stored: String, password: Data) -> String? {
        guard stored.hasPrefix(envelopePrefix) else { return nil }
        let encoded = String(stored.dropFirst(envelopePrefix.count))
        guard !encoded.isEmpty, let blob = Data(base64Encoded: encoded) else { return nil }
        guard let plain = decrypt(ciphertext: blob, password: password),
              let text = String(data: plain, encoding: .utf8),
              !text.isEmpty
        else { return nil }
        return text
    }

    /// Login-keychain generic password. No item is created. On this Mac the
    /// call runs on the main actor so the Allow sheet can appear. Other
    /// platforms have no Cursor Keychain and report the item missing.
    static func copyPassword() async -> CursorKeychainPasswordResult {
        #if os(macOS)
        await MainActor.run {
            let primary = copy(account: account)
            return resolve(primary: primary) { copy(account: legacyAccount) }
        }
        #else
        .notFound
        #endif
    }

    #if os(macOS)
    /// Electron writes this password with `SecKeychainAddGenericPassword`,
    /// which is the file-based login keychain. The data-protection keychain
    /// is a different store and does not hold the item.
    private static func copy(account: String) -> CursorKeychainPasswordResult {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIAllow,
            kSecUseOperationPrompt as String: prompt,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return CursorKeychainAccess.result(status: status, data: item as? Data)
    }
    #endif
}

/// In-memory Keychain password and decrypted access tokens. Nothing here is
/// written to disk, UserDefaults, the unified log, or iCloud.
actor CursorSafeStorageSecrets {
    static let shared = CursorSafeStorageSecrets()

    private var password: Data?
    private var promptsSuppressed = false
    private var decrypted: [String: String] = [:]
    private var lookupRunning = false
    private var waiters: [CheckedContinuation<CursorKeychainPasswordResult, Never>] = []

    /// Plaintext tokens are returned unchanged and do not look at the Keychain.
    /// The decrypted token for an envelope is remembered until this process ends.
    func unlock(
        _ read: CursorTokenRead,
        lookup: @escaping @Sendable () async -> CursorKeychainPasswordResult
    ) async -> CursorTokenRead {
        guard case .token(let stored) = read, CursorSafeStorage.isEnvelope(stored) else {
            return read
        }
        if let plain = decrypted[stored] {
            return .token(plain)
        }
        switch await password(lookup: lookup) {
        case .denied:
            return .keychainDenied
        case .notFound:
            return .keychainMissing
        case .password(let secret):
            guard let plain = CursorSafeStorage.openEnvelope(stored, password: secret) else {
                return .keychainLocked
            }
            decrypted[stored] = plain
            return .token(plain)
        }
    }

    /// The next envelope read may show the Allow sheet again. A password the
    /// user already allowed stays cached, so a later Refresh does not ask twice.
    func allowPromptAgain() {
        promptsSuppressed = false
    }

    private func password(
        lookup: @escaping @Sendable () async -> CursorKeychainPasswordResult
    ) async -> CursorKeychainPasswordResult {
        if let password {
            return .password(password)
        }
        if promptsSuppressed {
            return .denied
        }
        if lookupRunning {
            return await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
        lookupRunning = true
        let result = Self.normalized(await lookup())
        switch result {
        case .password(let data):
            password = data
        case .denied:
            promptsSuppressed = true
        case .notFound:
            break
        }
        lookupRunning = false
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume(returning: result)
        }
        return result
    }

    private static func normalized(_ result: CursorKeychainPasswordResult) -> CursorKeychainPasswordResult {
        if case .password(let data) = result, data.isEmpty {
            return .notFound
        }
        return result
    }
}

private enum PBKDF2SHA1 {
    static func derive(password: [UInt8], salt: [UInt8], iterations: Int, length: Int) -> [UInt8] {
        var derived: [UInt8] = []
        var block: UInt32 = 1
        while derived.count < length {
            var message = salt
            message.append(UInt8((block >> 24) & 0xff))
            message.append(UInt8((block >> 16) & 0xff))
            message.append(UInt8((block >> 8) & 0xff))
            message.append(UInt8(block & 0xff))
            var u = HMACSHA1.authenticate(key: password, message: message)
            var t = u
            if iterations > 1 {
                for _ in 1..<iterations {
                    u = HMACSHA1.authenticate(key: password, message: u)
                    for index in t.indices {
                        t[index] ^= u[index]
                    }
                }
            }
            derived.append(contentsOf: t)
            block += 1
        }
        return Array(derived.prefix(length))
    }
}

private enum HMACSHA1 {
    static func authenticate(key: [UInt8], message: [UInt8]) -> [UInt8] {
        var key = key
        if key.count > 64 {
            key = SHA1Hash.digest(key)
        }
        if key.count < 64 {
            key.append(contentsOf: repeatElement(0, count: 64 - key.count))
        }
        let inner = key.map { $0 ^ 0x36 } + message
        let outer = key.map { $0 ^ 0x5c } + SHA1Hash.digest(inner)
        return SHA1Hash.digest(outer)
    }
}

private enum SHA1Hash {
    static func digest(_ message: [UInt8]) -> [UInt8] {
        var h0: UInt32 = 0x67452301
        var h1: UInt32 = 0xEFCDAB89
        var h2: UInt32 = 0x98BADCFE
        var h3: UInt32 = 0x10325476
        var h4: UInt32 = 0xC3D2E1F0

        var bytes = message
        let bitLength = UInt64(message.count) &* 8
        bytes.append(0x80)
        while bytes.count % 64 != 56 {
            bytes.append(0)
        }
        for shift in stride(from: 56, through: 0, by: -8) {
            bytes.append(UInt8((bitLength >> UInt64(shift)) & 0xff))
        }

        var offset = 0
        while offset < bytes.count {
            var w = [UInt32](repeating: 0, count: 80)
            for index in 0..<16 {
                let start = offset + index * 4
                w[index] = (UInt32(bytes[start]) << 24)
                    | (UInt32(bytes[start + 1]) << 16)
                    | (UInt32(bytes[start + 2]) << 8)
                    | UInt32(bytes[start + 3])
            }
            for index in 16..<80 {
                let mixed = w[index - 3] ^ w[index - 8] ^ w[index - 14] ^ w[index - 16]
                w[index] = (mixed << 1) | (mixed >> 31)
            }
            var a = h0
            var b = h1
            var c = h2
            var d = h3
            var e = h4
            for index in 0..<80 {
                let f: UInt32
                let k: UInt32
                switch index {
                case 0..<20:
                    f = (b & c) | (~b & d)
                    k = 0x5A827999
                case 20..<40:
                    f = b ^ c ^ d
                    k = 0x6ED9EBA1
                case 40..<60:
                    f = (b & c) | (b & d) | (c & d)
                    k = 0x8F1BBCDC
                default:
                    f = b ^ c ^ d
                    k = 0xCA62C1D6
                }
                let temp = rotate(a, 5) &+ f &+ e &+ k &+ w[index]
                e = d
                d = c
                c = rotate(b, 30)
                b = a
                a = temp
            }
            h0 = h0 &+ a
            h1 = h1 &+ b
            h2 = h2 &+ c
            h3 = h3 &+ d
            h4 = h4 &+ e
            offset += 64
        }

        var out: [UInt8] = []
        out.reserveCapacity(20)
        for word in [h0, h1, h2, h3, h4] {
            out.append(UInt8((word >> 24) & 0xff))
            out.append(UInt8((word >> 16) & 0xff))
            out.append(UInt8((word >> 8) & 0xff))
            out.append(UInt8(word & 0xff))
        }
        return out
    }

    private static func rotate(_ value: UInt32, _ count: UInt32) -> UInt32 {
        (value << count) | (value >> (32 - count))
    }
}

private enum AES128CBC {
    static func decrypt(_ ciphertext: [UInt8], key: [UInt8], iv: [UInt8]) -> [UInt8]? {
        guard key.count == 16, iv.count == 16, ciphertext.count >= 16, ciphertext.count.isMultiple(of: 16) else {
            return nil
        }
        let roundKeys = expand(key)
        var previous = iv
        var plain: [UInt8] = []
        plain.reserveCapacity(ciphertext.count)
        var offset = 0
        while offset < ciphertext.count {
            let block = Array(ciphertext[offset..<(offset + 16)])
            let decrypted = decryptBlock(block, roundKeys: roundKeys)
            for index in 0..<16 {
                plain.append(decrypted[index] ^ previous[index])
            }
            previous = block
            offset += 16
        }
        return pkcs7Unpad(plain)
    }

    private static func pkcs7Unpad(_ bytes: [UInt8]) -> [UInt8]? {
        guard let last = bytes.last, last >= 1, last <= 16 else { return nil }
        let count = Int(last)
        guard bytes.count >= count, bytes.suffix(count).allSatisfy({ $0 == last }) else { return nil }
        return Array(bytes.dropLast(count))
    }

    private static func expand(_ key: [UInt8]) -> [UInt8] {
        var words: [[UInt8]] = stride(from: 0, to: 16, by: 4).map { start in
            [key[start], key[start + 1], key[start + 2], key[start + 3]]
        }
        var rconIndex = 1
        while words.count < 44 {
            var temp = words[words.count - 1]
            if words.count.isMultiple(of: 4) {
                temp = [temp[1], temp[2], temp[3], temp[0]]
                temp = temp.map { sBox[Int($0)] }
                temp[0] ^= rcon[rconIndex]
                rconIndex += 1
            }
            let earlier = words[words.count - 4]
            words.append(zip(earlier, temp).map { $0 ^ $1 })
        }
        return words.flatMap { $0 }
    }

    private static func decryptBlock(_ input: [UInt8], roundKeys: [UInt8]) -> [UInt8] {
        var state = input
        addRoundKey(&state, roundKeys, round: 10)
        for round in stride(from: 9, through: 1, by: -1) {
            invShiftRows(&state)
            invSubBytes(&state)
            addRoundKey(&state, roundKeys, round: round)
            invMixColumns(&state)
        }
        invShiftRows(&state)
        invSubBytes(&state)
        addRoundKey(&state, roundKeys, round: 0)
        return state
    }

    private static func addRoundKey(_ state: inout [UInt8], _ roundKeys: [UInt8], round: Int) {
        let start = round * 16
        for index in 0..<16 {
            state[index] ^= roundKeys[start + index]
        }
    }

    private static func invSubBytes(_ state: inout [UInt8]) {
        for index in state.indices {
            state[index] = invSBox[Int(state[index])]
        }
    }

    private static func invShiftRows(_ state: inout [UInt8]) {
        for row in 1..<4 {
            let cells = [state[row], state[row + 4], state[row + 8], state[row + 12]]
            var rotated = [UInt8](repeating: 0, count: 4)
            for index in 0..<4 {
                rotated[index] = cells[(index - row + 4) % 4]
            }
            state[row] = rotated[0]
            state[row + 4] = rotated[1]
            state[row + 8] = rotated[2]
            state[row + 12] = rotated[3]
        }
    }

    private static func invMixColumns(_ state: inout [UInt8]) {
        for column in 0..<4 {
            let index = column * 4
            let a0 = state[index]
            let a1 = state[index + 1]
            let a2 = state[index + 2]
            let a3 = state[index + 3]
            state[index] = mul(0x0e, a0) ^ mul(0x0b, a1) ^ mul(0x0d, a2) ^ mul(0x09, a3)
            state[index + 1] = mul(0x09, a0) ^ mul(0x0e, a1) ^ mul(0x0b, a2) ^ mul(0x0d, a3)
            state[index + 2] = mul(0x0d, a0) ^ mul(0x09, a1) ^ mul(0x0e, a2) ^ mul(0x0b, a3)
            state[index + 3] = mul(0x0b, a0) ^ mul(0x0d, a1) ^ mul(0x09, a2) ^ mul(0x0e, a3)
        }
    }

    private static func mul(_ left: UInt8, _ right: UInt8) -> UInt8 {
        var left = left
        var right = right
        var product: UInt8 = 0
        for _ in 0..<8 {
            if right & 1 == 1 {
                product ^= left
            }
            let high = left & 0x80
            left <<= 1
            if high != 0 {
                left ^= 0x1b
            }
            right >>= 1
        }
        return product
    }

    private static let rcon: [UInt8] = [
        0x00, 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36,
    ]

    private static let sBox: [UInt8] = [
        0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b, 0xfe, 0xd7, 0xab, 0x76,
        0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0, 0xad, 0xd4, 0xa2, 0xaf, 0x9c, 0xa4, 0x72, 0xc0,
        0xb7, 0xfd, 0x93, 0x26, 0x36, 0x3f, 0xf7, 0xcc, 0x34, 0xa5, 0xe5, 0xf1, 0x71, 0xd8, 0x31, 0x15,
        0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a, 0x07, 0x12, 0x80, 0xe2, 0xeb, 0x27, 0xb2, 0x75,
        0x09, 0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a, 0xa0, 0x52, 0x3b, 0xd6, 0xb3, 0x29, 0xe3, 0x2f, 0x84,
        0x53, 0xd1, 0x00, 0xed, 0x20, 0xfc, 0xb1, 0x5b, 0x6a, 0xcb, 0xbe, 0x39, 0x4a, 0x4c, 0x58, 0xcf,
        0xd0, 0xef, 0xaa, 0xfb, 0x43, 0x4d, 0x33, 0x85, 0x45, 0xf9, 0x02, 0x7f, 0x50, 0x3c, 0x9f, 0xa8,
        0x51, 0xa3, 0x40, 0x8f, 0x92, 0x9d, 0x38, 0xf5, 0xbc, 0xb6, 0xda, 0x21, 0x10, 0xff, 0xf3, 0xd2,
        0xcd, 0x0c, 0x13, 0xec, 0x5f, 0x97, 0x44, 0x17, 0xc4, 0xa7, 0x7e, 0x3d, 0x64, 0x5d, 0x19, 0x73,
        0x60, 0x81, 0x4f, 0xdc, 0x22, 0x2a, 0x90, 0x88, 0x46, 0xee, 0xb8, 0x14, 0xde, 0x5e, 0x0b, 0xdb,
        0xe0, 0x32, 0x3a, 0x0a, 0x49, 0x06, 0x24, 0x5c, 0xc2, 0xd3, 0xac, 0x62, 0x91, 0x95, 0xe4, 0x79,
        0xe7, 0xc8, 0x37, 0x6d, 0x8d, 0xd5, 0x4e, 0xa9, 0x6c, 0x56, 0xf4, 0xea, 0x65, 0x7a, 0xae, 0x08,
        0xba, 0x78, 0x25, 0x2e, 0x1c, 0xa6, 0xb4, 0xc6, 0xe8, 0xdd, 0x74, 0x1f, 0x4b, 0xbd, 0x8b, 0x8a,
        0x70, 0x3e, 0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e, 0x61, 0x35, 0x57, 0xb9, 0x86, 0xc1, 0x1d, 0x9e,
        0xe1, 0xf8, 0x98, 0x11, 0x69, 0xd9, 0x8e, 0x94, 0x9b, 0x1e, 0x87, 0xe9, 0xce, 0x55, 0x28, 0xdf,
        0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68, 0x41, 0x99, 0x2d, 0x0f, 0xb0, 0x54, 0xbb, 0x16,
    ]

    private static let invSBox: [UInt8] = [
        0x52, 0x09, 0x6a, 0xd5, 0x30, 0x36, 0xa5, 0x38, 0xbf, 0x40, 0xa3, 0x9e, 0x81, 0xf3, 0xd7, 0xfb,
        0x7c, 0xe3, 0x39, 0x82, 0x9b, 0x2f, 0xff, 0x87, 0x34, 0x8e, 0x43, 0x44, 0xc4, 0xde, 0xe9, 0xcb,
        0x54, 0x7b, 0x94, 0x32, 0xa6, 0xc2, 0x23, 0x3d, 0xee, 0x4c, 0x95, 0x0b, 0x42, 0xfa, 0xc3, 0x4e,
        0x08, 0x2e, 0xa1, 0x66, 0x28, 0xd9, 0x24, 0xb2, 0x76, 0x5b, 0xa2, 0x49, 0x6d, 0x8b, 0xd1, 0x25,
        0x72, 0xf8, 0xf6, 0x64, 0x86, 0x68, 0x98, 0x16, 0xd4, 0xa4, 0x5c, 0xcc, 0x5d, 0x65, 0xb6, 0x92,
        0x6c, 0x70, 0x48, 0x50, 0xfd, 0xed, 0xb9, 0xda, 0x5e, 0x15, 0x46, 0x57, 0xa7, 0x8d, 0x9d, 0x84,
        0x90, 0xd8, 0xab, 0x00, 0x8c, 0xbc, 0xd3, 0x0a, 0xf7, 0xe4, 0x58, 0x05, 0xb8, 0xb3, 0x45, 0x06,
        0xd0, 0x2c, 0x1e, 0x8f, 0xca, 0x3f, 0x0f, 0x02, 0xc1, 0xaf, 0xbd, 0x03, 0x01, 0x13, 0x8a, 0x6b,
        0x3a, 0x91, 0x11, 0x41, 0x4f, 0x67, 0xdc, 0xea, 0x97, 0xf2, 0xcf, 0xce, 0xf0, 0xb4, 0xe6, 0x73,
        0x96, 0xac, 0x74, 0x22, 0xe7, 0xad, 0x35, 0x85, 0xe2, 0xf9, 0x37, 0xe8, 0x1c, 0x75, 0xdf, 0x6e,
        0x47, 0xf1, 0x1a, 0x71, 0x1d, 0x29, 0xc5, 0x89, 0x6f, 0xb7, 0x62, 0x0e, 0xaa, 0x18, 0xbe, 0x1b,
        0xfc, 0x56, 0x3e, 0x4b, 0xc6, 0xd2, 0x79, 0x20, 0x9a, 0xdb, 0xc0, 0xfe, 0x78, 0xcd, 0x5a, 0xf4,
        0x1f, 0xdd, 0xa8, 0x33, 0x88, 0x07, 0xc7, 0x31, 0xb1, 0x12, 0x10, 0x59, 0x27, 0x80, 0xec, 0x5f,
        0x60, 0x51, 0x7f, 0xa9, 0x19, 0xb5, 0x4a, 0x0d, 0x2d, 0xe5, 0x7a, 0x9f, 0x93, 0xc9, 0x9c, 0xef,
        0xa0, 0xe0, 0x3b, 0x4d, 0xae, 0x2a, 0xf5, 0xb0, 0xc8, 0xeb, 0xbb, 0x3c, 0x83, 0x53, 0x99, 0x61,
        0x17, 0x2b, 0x04, 0x7e, 0xba, 0x77, 0xd6, 0x26, 0xe1, 0x69, 0x14, 0x63, 0x55, 0x21, 0x0c, 0x7d,
    ]
}
