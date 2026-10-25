import Foundation

struct BrowserProfile: Codable, Equatable, Identifiable {
    let id: String
    let browserName: String
    let bundleID: String
    let appPath: String
    let userDataDirectory: String
    let profileDirectory: String
    let displayName: String
    let identityHint: String?
    var manualSelection: Bool? = nil
}

struct BrowserLock: Codable, Equatable {
    let account: String
    let profile: BrowserProfile
    let updatedAt: Date
}

enum BrowserLockError: LocalizedError {
    case invalidAccount, unsupportedBrowser, invalidApplication(String), invalidProfile(String)
    case unreadableProfiles(String), duplicateAccount, unsupportedVersion, storage(String)
    var errorDescription: String? {
        switch self {
        case .invalidAccount: return "账号名称不符合要求，请刷新账号列表后重试。"
        case .unsupportedBrowser: return "这个浏览器暂不支持精确指定用户资料，请选择列表中的浏览器。"
        case .invalidApplication(let name): return "无法使用已指定的浏览器“\(name)”，请检查应用是否仍已安装，再重新选择。"
        case .invalidProfile(let name): return "已指定的浏览器用户资料“\(name)”不存在或路径无效。请重新选择，应用不会改用其他用户资料。"
        case .unreadableProfiles(let name): return "无法读取“\(name)”的用户资料列表，请检查浏览器配置后重试。"
        case .duplicateAccount: return "目标账号已有浏览器绑定，无法覆盖。请先检查两个账号的绑定。"
        case .unsupportedVersion: return "浏览器绑定文件来自更新版本，请使用新版应用。"
        case .storage(let message): return "无法保存浏览器绑定：" + message
        }
    }
}

private struct BrowserDefinition {
    let name: String
    let bundleID: String
    let dataComponents: [String]
    static let supported: [BrowserDefinition] = [
        BrowserDefinition(name: "Google Chrome", bundleID: "com.google.Chrome", dataComponents: ["Google", "Chrome"]),
        BrowserDefinition(name: "Microsoft Edge", bundleID: "com.microsoft.edgemac", dataComponents: ["Microsoft Edge"]),
        BrowserDefinition(name: "Brave Browser", bundleID: "com.brave.Browser", dataComponents: ["BraveSoftware", "Brave-Browser"]),
        BrowserDefinition(name: "Chromium", bundleID: "org.chromium.Chromium", dataComponents: ["Chromium"])
    ]
}

enum BrowserProfileDiscovery {
    /// The caller must obtain these exact locations through explicit user choice.
    /// A manually selected profile needs no access to the browser's Local State.
    static func manualProfile(app: URL, directory: URL) throws -> BrowserProfile {
        guard app.isFileURL, directory.isFileURL else { throw BrowserLockError.invalidProfile(directory.lastPathComponent) }
        let application = app.standardizedFileURL.resolvingSymlinksInPath()
        let selected = directory.standardizedFileURL.resolvingSymlinksInPath()
        let identifier = try BrowserLockStore.applicationIdentity(at: application)
        guard let browser = BrowserDefinition.supported.first(where: { $0.bundleID == identifier }) else { throw BrowserLockError.unsupportedBrowser }
        let userData = selected.deletingLastPathComponent()
        let component = selected.lastPathComponent
        let profile = BrowserProfile(id: [identifier, application.path, userData.path, component].joined(separator: "|"),
                                     browserName: browser.name, bundleID: identifier, appPath: application.path,
                                     userDataDirectory: userData.path, profileDirectory: component,
                                     displayName: component, identityHint: nil, manualSelection: true)
        try BrowserLockStore.validate(profile: profile)
        return profile
    }

    /// Reads application identities and profile name metadata only. Cookies,
    /// credentials, browser Preferences, and login state are never opened.
    static func discover(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                         applicationRoots: [URL]? = nil, allowedBundleIDs: Set<String>? = nil) throws -> [BrowserProfile] {
        let roots = applicationRoots ?? [URL(fileURLWithPath: "/Applications", isDirectory: true), home.appendingPathComponent("Applications", isDirectory: true)]
        let fm = FileManager.default
        var applications: [URL] = [], seen = Set<String>()
        for root in roots {
            var directory: ObjCBool = false
            guard fm.fileExists(atPath: root.path, isDirectory: &directory) else { continue }
            guard directory.boolValue else { throw BrowserLockError.invalidApplication(root.lastPathComponent) }
            var enumerationError: Error?
            guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, error in enumerationError = error; return false }) else {
                throw BrowserLockError.invalidApplication(root.lastPathComponent)
            }
            for case let candidate as URL in enumerator {
                guard candidate.pathExtension.lowercased() == "app" else { continue }
                enumerator.skipDescendants()
                let path = candidate.standardizedFileURL.resolvingSymlinksInPath()
                if seen.insert(path.path).inserted { applications.append(path) }
            }
            if let enumerationError { throw enumerationError }
        }
        var profiles: [BrowserProfile] = []
        for app in applications {
            // Other apps are not profile sources. Missing/unreadable Info files
            // in unrelated packages do not block browser discovery.
            guard let identifier = try? BrowserLockStore.applicationIdentity(at: app),
                  let browser = BrowserDefinition.supported.first(where: { $0.bundleID == identifier }),
                  allowedBundleIDs?.contains(identifier) != false else { continue }
            var userData = home.appendingPathComponent("Library/Application Support", isDirectory: true)
            for component in browser.dataComponents { userData.appendPathComponent(component, isDirectory: true) }
            userData = userData.standardizedFileURL.resolvingSymlinksInPath()
            let cache = try BrowserLockStore.profileCache(userData: userData, browserName: browser.name, missingIsEmpty: true)
            for directory in cache.keys.sorted() {
                let metadata = cache[directory] ?? [:]
                let name = (metadata["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let identity = (metadata["user_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let profile = BrowserProfile(id: [browser.bundleID, app.path, userData.path, directory].joined(separator: "|"),
                                             browserName: browser.name, bundleID: browser.bundleID, appPath: app.path,
                                             userDataDirectory: userData.path, profileDirectory: directory,
                                             displayName: (name?.isEmpty == false ? name : nil) ?? directory,
                                             identityHint: identity?.isEmpty == false ? identity : nil)
                do { try BrowserLockStore.validatePaths(profile: profile) }
                catch BrowserLockError.invalidProfile {
                    // Chromium may retain an info_cache entry after its folder
                    // was removed. It is not a selectable profile; other valid
                    // profiles remain available. Saved bindings still fail closed.
                    continue
                }
                profiles.append(profile)
            }
        }
        return profiles.sorted {
            let lhs = [$0.browserName, $0.displayName, $0.profileDirectory, $0.appPath].joined(separator: "\n")
            let rhs = [$1.browserName, $1.displayName, $1.profileDirectory, $1.appPath].joined(separator: "\n")
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
    }
}

/// The app's account-to-browser preference. This never modifies browser files.
/// Stale bindings remain visible and fail validation rather than selecting a fallback.
final class BrowserLockStore {
    private struct Document: Codable {
        var version = 1
        let locks: [BrowserLock]
        let profiles: [BrowserProfile]?
    }
    private struct State {
        var locks: [BrowserLock]
        var profiles: [BrowserProfile]
    }
    static var defaultURL: URL { ProjectStore.defaultURL.deletingLastPathComponent().appendingPathComponent("browser-locks.json") }
    private static let mutationLock = NSLock()
    let url: URL
    private(set) var locks: [BrowserLock] = []
    private(set) var registeredProfiles: [BrowserProfile] = []

    init(url: URL = BrowserLockStore.defaultURL) throws {
        self.url = url
        apply(try Self.readState(from: url))
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func readState(from url: URL) throws -> State {
        guard FileManager.default.fileExists(atPath: url.path) else { return State(locks: [], profiles: []) }
        try Self.validateStorageFile(url)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(Document.self, from: Data(contentsOf: url))
        guard document.version == 1 else { throw BrowserLockError.unsupportedVersion }
        var names = Set<String>()
        for lock in document.locks {
            try Self.validateAccount(lock.account)
            guard names.insert(lock.account).inserted else { throw BrowserLockError.duplicateAccount }
        }
        var profiles: [String: BrowserProfile] = [:]
        for profile in document.profiles ?? [] {
            if let old = profiles[profile.id], !sameIdentity(old, profile) { throw BrowserLockError.invalidProfile(profile.displayName) }
            profiles[profile.id] = profile
        }
        // Older documents embedded their only profile copies inside bindings.
        // Retain them independently now, with the most recent legacy label winning.
        for lock in document.locks.sorted(by: { $0.updatedAt < $1.updatedAt }) {
            if let old = profiles[lock.profile.id], !sameIdentity(old, lock.profile) { throw BrowserLockError.invalidProfile(lock.profile.displayName) }
            if document.profiles == nil || profiles[lock.profile.id] == nil { profiles[lock.profile.id] = lock.profile }
        }
        // Do not validate profile existence here: a missing browser/profile must
        // remain bound so the interface can ask the user to repair it explicitly.
        let bindings = document.locks.map { BrowserLock(account: $0.account, profile: profiles[$0.profile.id]!, updatedAt: $0.updatedAt) }
        return State(locks: bindings, profiles: profiles.values.sorted { $0.id < $1.id })
    }

    func binding(account: String) -> BrowserLock? { locks.first { $0.account == account } }

    /// Register a user-selected profile even before assigning it to an account.
    func register(profile: BrowserProfile) throws {
        try Self.validate(profile: profile)
        Self.mutationLock.lock(); defer { Self.mutationLock.unlock() }
        var current = try Self.readState(from: url)
        try Self.register(profile: profile, in: &current)
        try commit(current)
    }

    func lock(account: String, profile: BrowserProfile) throws {
        try Self.validateAccount(account)
        Self.mutationLock.lock(); defer { Self.mutationLock.unlock() }
        var current = try Self.readState(from: url)
        let selected: BrowserProfile
        if let registered = current.profiles.first(where: { $0.id == profile.id }) {
            guard Self.sameIdentity(registered, profile) else { throw BrowserLockError.invalidProfile(profile.displayName) }
            // Assigning an account must not revert a label edited in another
            // window. Metadata changes are explicit through register(profile:).
            selected = registered
        } else {
            try Self.register(profile: profile, in: &current)
            selected = profile
        }
        try Self.validate(profile: selected)
        current.locks.removeAll { $0.account == account }
        current.locks.append(BrowserLock(account: account, profile: selected, updatedAt: Self.timestamp()))
        try commit(current)
    }

    func unlock(account: String) throws {
        try Self.validateAccount(account)
        Self.mutationLock.lock(); defer { Self.mutationLock.unlock() }
        var current = try Self.readState(from: url)
        guard current.locks.contains(where: { $0.account == account }) else { apply(current); return }
        current.locks.removeAll { $0.account == account }
        try commit(current)
    }

    /// Preserve both identities until the caller verifies CCAM's actual rename
    /// result. A stale profile remains locked and must not prevent an account rename.
    func stageRename(old: String, new: String) throws {
        try Self.validateAccount(old); try Self.validateAccount(new)
        Self.mutationLock.lock(); defer { Self.mutationLock.unlock() }
        var current = try Self.readState(from: url)
        guard let existing = current.locks.first(where: { $0.account == old }) else { apply(current); return }
        guard !current.locks.contains(where: { $0.account == new }) else { throw BrowserLockError.duplicateAccount }
        current.locks.append(BrowserLock(account: new, profile: existing.profile, updatedAt: Self.timestamp()))
        try commit(current)
    }

    /// Call only after CCAM reports a successful account rename.
    func rename(old: String, new: String) throws {
        try Self.validateAccount(old); try Self.validateAccount(new)
        Self.mutationLock.lock(); defer { Self.mutationLock.unlock() }
        var current = try Self.readState(from: url)
        guard old != new, let existing = current.locks.first(where: { $0.account == old }) else { apply(current); return }
        guard !current.locks.contains(where: { $0.account == new }) else { throw BrowserLockError.duplicateAccount }
        current.locks.removeAll { $0.account == old }
        current.locks.append(BrowserLock(account: new, profile: existing.profile, updatedAt: Self.timestamp()))
        try commit(current)
    }

    private static func sameIdentity(_ lhs: BrowserProfile, _ rhs: BrowserProfile) -> Bool {
        lhs.bundleID == rhs.bundleID && lhs.appPath == rhs.appPath && lhs.userDataDirectory == rhs.userDataDirectory && lhs.profileDirectory == rhs.profileDirectory
    }
    private static func register(profile: BrowserProfile, in state: inout State) throws {
        if let existing = state.profiles.first(where: { $0.id == profile.id }), !sameIdentity(existing, profile) {
            throw BrowserLockError.invalidProfile(profile.displayName)
        }
        state.profiles.removeAll { $0.id == profile.id }
        state.profiles.append(profile)
        state.locks = state.locks.map { $0.profile.id == profile.id ? BrowserLock(account: $0.account, profile: profile, updatedAt: $0.updatedAt) : $0 }
    }
    private func apply(_ state: State) { locks = state.locks; registeredProfiles = state.profiles }

    static func validate(profile: BrowserProfile) throws {
        try validatePaths(profile: profile)
        if profile.manualSelection == true {
            let marker = URL(fileURLWithPath: profile.userDataDirectory, isDirectory: true)
                .appendingPathComponent(profile.profileDirectory, isDirectory: true).appendingPathComponent("Preferences")
            do {
                // Only stat the marker. Its contents can include private browser
                // settings and must never be read or copied by the login lock.
                let attributes = try FileManager.default.attributesOfItem(atPath: marker.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular else { throw BrowserLockError.invalidProfile(profile.displayName) }
            } catch { throw BrowserLockError.invalidProfile(profile.displayName) }
            return
        }
        let cache = try profileCache(userData: URL(fileURLWithPath: profile.userDataDirectory, isDirectory: true), browserName: profile.browserName, missingIsEmpty: false)
        guard cache[profile.profileDirectory] != nil else { throw BrowserLockError.invalidProfile(profile.displayName) }
    }

    fileprivate static func validatePaths(profile: BrowserProfile) throws {
        guard BrowserDefinition.supported.contains(where: { $0.bundleID == profile.bundleID }) else { throw BrowserLockError.unsupportedBrowser }
        let component = profile.profileDirectory
        guard !component.isEmpty, component != ".", component != "..", !component.hasPrefix("-"),
              !component.contains("/"), !component.contains("\\"), !component.contains("\0"),
              component == component.trimmingCharacters(in: .whitespacesAndNewlines),
              profile.userDataDirectory.hasPrefix("/"), !profile.userDataDirectory.contains("\0"),
              profile.appPath.hasPrefix("/"), !profile.appPath.contains("\0") else {
            throw BrowserLockError.invalidProfile(profile.displayName)
        }
        let app = URL(fileURLWithPath: profile.appPath, isDirectory: true)
        guard app.pathExtension.lowercased() == "app", try applicationIdentity(at: app) == profile.bundleID else {
            throw BrowserLockError.invalidApplication(profile.browserName)
        }
        let userData = URL(fileURLWithPath: profile.userDataDirectory, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        let directory = userData.appendingPathComponent(component, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard directory.deletingLastPathComponent().path == userData.path,
              FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw BrowserLockError.invalidProfile(profile.displayName)
        }
    }

    fileprivate static func applicationIdentity(at app: URL) throws -> String {
        let info = app.appendingPathComponent("Contents/Info.plist")
        let object = try PropertyListSerialization.propertyList(from: Data(contentsOf: info), options: [], format: nil)
        guard let dictionary = object as? [String: Any], let identifier = dictionary["CFBundleIdentifier"] as? String else {
            throw BrowserLockError.invalidApplication(app.lastPathComponent)
        }
        return identifier
    }

    fileprivate static func profileCache(userData: URL, browserName: String, missingIsEmpty: Bool) throws -> [String: [String: Any]] {
        let state = userData.appendingPathComponent("Local State")
        let data: Data
        do { data = try Data(contentsOf: state) }
        catch {
            // fileExists also returns false when macOS denies access. Only an
            // actual missing file means that this browser has no profile cache.
            let failure = error as NSError
            let missing = (failure.domain == NSPOSIXErrorDomain && failure.code == 2)
                || (failure.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(failure.code))
            if missing {
                if missingIsEmpty { return [:] }
                throw BrowserLockError.invalidProfile(browserName)
            }
            throw BrowserLockError.unreadableProfiles(browserName)
        }
        do {
            let object = try JSONSerialization.jsonObject(with: data)
            guard let dictionary = object as? [String: Any] else { throw BrowserLockError.unreadableProfiles(browserName) }
            guard let rawProfile = dictionary["profile"] else { return [:] }
            guard let profile = rawProfile as? [String: Any] else { throw BrowserLockError.unreadableProfiles(browserName) }
            guard let rawCache = profile["info_cache"] else { return [:] }
            guard let cache = rawCache as? [String: [String: Any]] else { throw BrowserLockError.unreadableProfiles(browserName) }
            return cache
        } catch { throw BrowserLockError.unreadableProfiles(browserName) }
    }

    private static func validateAccount(_ account: String) throws {
        guard account.range(of: "^[a-z0-9][a-z0-9_-]{0,31}$", options: .regularExpression) != nil else { throw BrowserLockError.invalidAccount }
    }
    private static func timestamp() -> Date { Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970)) }
    private static func validateStorageFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw BrowserLockError.storage("绑定文件的位置不是普通文件。")
        }
    }

    private func commit(_ next: State) throws {
        let fm = FileManager.default
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let sorted = State(locks: next.locks.sorted { $0.account.localizedStandardCompare($1.account) == .orderedAscending },
                           profiles: next.profiles.sorted { $0.id < $1.id })
        let data = try encoder.encode(Document(locks: sorted.locks, profiles: sorted.profiles))
        let parent = url.deletingLastPathComponent()
        if fm.fileExists(atPath: url.path) { try Self.validateStorageFile(url) }
        try fm.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = parent.appendingPathComponent(".browser-locks-\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw BrowserLockError.storage("无法创建临时文件。")
        }
        defer { try? fm.removeItem(at: temporary) }
        let handle = try FileHandle(forWritingTo: temporary)
        do { try handle.write(contentsOf: data); try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); throw error }
        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: temporary, backupItemName: nil, options: [.usingNewMetadataOnly])
        } else { try fm.moveItem(at: temporary, to: url) }
        apply(sorted)
    }
}
