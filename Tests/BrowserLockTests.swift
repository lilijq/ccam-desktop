import Foundation

@main struct BrowserLockTests {
    static var count = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        count += 1
        if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
    static func app(_ root: URL, name: String, identifier: String) throws -> URL {
        let bundle = root.appendingPathComponent(name + ".app")
        let contents = bundle.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": identifier, "CFBundleName": name], format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        return bundle
    }
    static func state(_ directory: URL, profiles: [String: [String: String]]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for key in profiles.keys where !key.contains("/") {
            try FileManager.default.createDirectory(at: directory.appendingPathComponent(key), withIntermediateDirectories: true)
        }
        let data = try JSONSerialization.data(withJSONObject: ["profile": ["info_cache": profiles], "os_crypt": ["encrypted_key": "DO-NOT-STORE-TOKEN"]])
        try data.write(to: directory.appendingPathComponent("Local State"))
    }
    static func changed(_ profile: BrowserProfile, component: String? = nil, appPath: String? = nil, bundleID: String? = nil) -> BrowserProfile {
        BrowserProfile(id: profile.id, browserName: profile.browserName, bundleID: bundleID ?? profile.bundleID, appPath: appPath ?? profile.appPath,
                       userDataDirectory: profile.userDataDirectory, profileDirectory: component ?? profile.profileDirectory, displayName: profile.displayName, identityHint: profile.identityHint)
    }
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ccam-browser-lock-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let home = root.appendingPathComponent("home"), applications = root.appendingPathComponent("Applications")
        let chrome = try app(applications, name: "Google Chrome", identifier: "com.google.Chrome")
        let safari = try app(applications, name: "Safari", identifier: "com.apple.Safari")
        _ = try app(applications, name: "Fake Chrome", identifier: "example.unrelated")
        let data = home.appendingPathComponent("Library/Application Support/Google/Chrome")
        try state(data, profiles: ["Default": ["name": "个人", "user_name": "personal@example.invalid"], "Profile 3": ["name": "工作", "user_name": "work@example.invalid"]])
        try Data("PRIVATE-DO-NOT-READ".utf8).write(to: data.appendingPathComponent("Default/Preferences"))
        let profiles = try BrowserProfileDiscovery.discover(home: home, applicationRoots: [applications])
        check(profiles.count == 2, "only supported app identities and registered profiles discovered")
        let personal = profiles.first { $0.profileDirectory == "Default" }!
        let work = profiles.first { $0.profileDirectory == "Profile 3" }!
        check(personal.appPath == chrome.path && personal.displayName == "个人" && personal.identityHint == "personal@example.invalid", "profile identity uses exact installed app and cache metadata")
        try BrowserLockStore.validate(profile: personal)
        let stable = try BrowserProfileDiscovery.discover(home: home, applicationRoots: [applications, applications])
        check(stable == profiles, "discovery is stable and duplicate roots do not duplicate profiles")
        let bindingURL = root.appendingPathComponent("app-data/browser-locks.json")
        let store = try BrowserLockStore(url: bindingURL)
        try store.lock(account: "first", profile: personal)
        check(store.binding(account: "first")?.profile == personal, "account locked to exact profile")
        let permissions = try fm.attributesOfItem(atPath: bindingURL.path)[.posixPermissions] as? NSNumber
        check(permissions?.intValue == 0o600, "binding file permissions are 0600")
        try store.lock(account: "second", profile: work)
        let saved = try String(contentsOf: bindingURL, encoding: .utf8)
        check(!saved.contains("DO-NOT-STORE") && !saved.contains("PRIVATE-DO-NOT-READ") && !saved.contains("encrypted_key"), "no token or Preferences data stored")
        let reopened = try BrowserLockStore(url: bindingURL)
        check(reopened.locks == store.locks, "bindings persist through reopen")
        let libraryURL = root.appendingPathComponent("profile-library/locks.json")
        let libraryA = try BrowserLockStore(url: libraryURL), libraryB = try BrowserLockStore(url: libraryURL)
        try libraryA.register(profile: personal)
        check(libraryA.locks.isEmpty && libraryA.registeredProfiles == [personal], "profile can be registered without an account binding")
        try libraryB.register(profile: work)
        try libraryA.lock(account: "shared-one", profile: personal)
        try libraryB.lock(account: "shared-two", profile: personal)
        let sharedProfiles = try BrowserLockStore(url: libraryURL)
        check(sharedProfiles.locks.count == 2 && sharedProfiles.locks.allSatisfy { $0.profile == personal }, "multiple accounts can share one exact browser profile after reopening")
        check(Set(sharedProfiles.registeredProfiles.map(\.id)) == Set([personal.id, work.id]), "alternating stores retain independently registered profiles")
        let renamedProfile = BrowserProfile(id: personal.id, browserName: personal.browserName, bundleID: personal.bundleID, appPath: personal.appPath,
                                            userDataDirectory: personal.userDataDirectory, profileDirectory: personal.profileDirectory,
                                            displayName: "常用 Chrome 账号", identityHint: personal.identityHint, manualSelection: personal.manualSelection)
        try libraryA.register(profile: renamedProfile)
        check(libraryA.locks.allSatisfy { $0.profile == renamedProfile }, "updating a registered label synchronizes every account reference")
        try libraryB.lock(account: "shared-three", profile: personal)
        check(libraryB.locks.allSatisfy { $0.profile == renamedProfile }, "binding from a stale window does not revert the registered label")
        let changedIdentity = BrowserProfile(id: personal.id, browserName: work.browserName, bundleID: work.bundleID, appPath: work.appPath,
                                            userDataDirectory: work.userDataDirectory, profileDirectory: work.profileDirectory,
                                            displayName: "Wrong directory", identityHint: nil)
        do { try libraryB.register(profile: changedIdentity); check(false, "registered profile identity cannot change under the same id") }
        catch BrowserLockError.invalidProfile { check(true, "registered profile identity cannot change under the same id") }
        try libraryB.unlock(account: "shared-one")
        try libraryA.unlock(account: "shared-two")
        try libraryB.unlock(account: "shared-three")
        let unboundLibrary = try BrowserLockStore(url: libraryURL)
        check(unboundLibrary.locks.isEmpty && unboundLibrary.registeredProfiles.count == 2, "unlocking every account preserves the independently registered directory library")
        check(unboundLibrary.registeredProfiles.contains(renamedProfile), "latest label survives other windows unlocking their accounts")
        var legacyDocument = try JSONSerialization.jsonObject(with: Data(contentsOf: bindingURL)) as! [String: Any]
        legacyDocument.removeValue(forKey: "profiles")
        var legacyBindings = legacyDocument["locks"] as! [[String: Any]]
        var sharedLegacyBinding = legacyBindings[0]; sharedLegacyBinding["account"] = "legacy-copy"
        legacyBindings.append(sharedLegacyBinding); legacyDocument["locks"] = legacyBindings
        let legacyURL = root.appendingPathComponent("legacy-locks.json")
        try JSONSerialization.data(withJSONObject: legacyDocument).write(to: legacyURL)
        let legacyStore = try BrowserLockStore(url: legacyURL)
        check(legacyStore.registeredProfiles.count == 2 && Set(legacyStore.registeredProfiles.map(\.id)) == Set([personal.id, work.id]), "older lock-only document derives and deduplicates its profile library")
        try legacyStore.unlock(account: "first"); try legacyStore.unlock(account: "second"); try legacyStore.unlock(account: "legacy-copy")
        let migratedStore = try BrowserLockStore(url: legacyURL)
        check(migratedStore.locks.isEmpty && migratedStore.registeredProfiles.count == 2, "legacy profile migration persists after removing every old binding")
        try store.rename(old: "first", new: "renamed")
        check(store.binding(account: "first") == nil && store.binding(account: "renamed")?.profile == personal, "successful rename preserves browser profile")
        do { try store.rename(old: "renamed", new: "second"); check(false, "rename collision rejected") } catch { check(true, "rename collision rejected") }
        check(store.binding(account: "renamed") != nil && store.binding(account: "second")?.profile == work, "rename collision preserves both locks")
        try store.rename(old: "absent", new: "unused")
        check(store.locks.count == 2, "renaming account without binding is a no-op")
        let sharedURL = root.appendingPathComponent("two-windows/browser-locks.json")
        let windowA = try BrowserLockStore(url: sharedURL), windowB = try BrowserLockStore(url: sharedURL)
        try windowA.lock(account: "alpha", profile: personal)
        try windowB.lock(account: "beta", profile: work)
        check(Set(windowB.locks.map(\.account)) == Set(["alpha", "beta"]), "second window preserves another window's new lock")
        try windowA.unlock(account: "alpha")
        check(windowA.binding(account: "beta")?.profile == work, "stale window unlock preserves newer unrelated binding")
        try windowB.rename(old: "beta", new: "renamed-beta")
        check(windowB.binding(account: "alpha") == nil && windowB.binding(account: "renamed-beta")?.profile == work, "stale window rename does not resurrect deleted binding")
        try windowA.lock(account: "gamma", profile: personal)
        try windowB.lock(account: "delta", profile: work)
        try windowA.rename(old: "renamed-beta", new: "final-beta")
        check(Set(windowA.locks.map(\.account)) == Set(["final-beta", "gamma", "delta"]), "alternating writes retain all current mappings")
        try windowB.unlock(account: "absent")
        check(windowB.locks == windowA.locks, "no-op mutation refreshes stale snapshot without rewriting")
        let stagingURL = root.appendingPathComponent("rename-staging/browser-locks.json")
        let stagingA = try BrowserLockStore(url: stagingURL), stagingB = try BrowserLockStore(url: stagingURL)
        try stagingA.lock(account: "source", profile: work)
        try stagingB.lock(account: "other", profile: personal)
        try stagingA.stageRename(old: "source", new: "destination")
        check(stagingA.binding(account: "source")?.profile == work && stagingA.binding(account: "destination")?.profile == work,
              "staging preserves source and copies the exact profile to destination")
        check(stagingA.binding(account: "other")?.profile == personal, "staging from stale window preserves another window's addition")
        do { try stagingB.stageRename(old: "source", new: "destination"); check(false, "staging checks current disk for destination collision") }
        catch { check(true, "staging checks current disk for destination collision") }
        try stagingB.stageRename(old: "absent", new: "unused")
        check(stagingB.locks == stagingA.locks, "staging absent source refreshes snapshot without adding a lock")
        for bad in ["../Default", "..", "--profile-directory=Default", "Default/child", "Default\\child", "Default\0"] {
            do { try BrowserLockStore.validate(profile: changed(personal, component: bad)); check(false, "unsafe directory rejected \(bad)") }
            catch { check(true, "unsafe directory rejected") }
        }
        do { try BrowserLockStore.validate(profile: changed(personal, bundleID: "com.apple.Safari")); check(false, "unsupported browser rejected") } catch { check(true, "unsupported browser rejected") }
        do { try BrowserLockStore.validate(profile: changed(personal, appPath: safari.path)); check(false, "application identity mismatch rejected") } catch { check(true, "application identity mismatch rejected") }
        do { try store.lock(account: "--unsafe", profile: personal); check(false, "unsafe account rejected") } catch { check(true, "unsafe account rejected") }
        let outside = root.appendingPathComponent("outside")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: data.appendingPathComponent("Profile Escape"), withDestinationURL: outside)
        do { try BrowserLockStore.validate(profile: changed(personal, component: "Profile Escape")); check(false, "symlink escape rejected") } catch { check(true, "symlink escape rejected") }
        try fm.removeItem(at: data.appendingPathComponent("Profile 3"))
        do { try BrowserLockStore.validate(profile: work); check(false, "missing bound profile rejected") } catch { check(true, "missing bound profile rejected") }
        try stagingB.stageRename(old: "source", new: "stale-destination")
        check(stagingB.binding(account: "source")?.profile == work && stagingB.binding(account: "stale-destination")?.profile == work,
              "staging retains unavailable profile without validation or fallback")
        try stagingA.unlock(account: "other")
        check(Set(stagingA.locks.map(\.account)) == Set(["source", "destination", "stale-destination"]),
              "another stale store mutation preserves both staged destinations")
        let stagedReopened = try BrowserLockStore(url: stagingURL)
        check(stagedReopened.locks == stagingA.locks, "staged unavailable bindings persist unchanged")
        check(Set(stagedReopened.registeredProfiles.map(\.id)) == Set([personal.id, work.id]), "staged and completed renames preserve the profile library")
        let discoveredAfterRemoval = try BrowserProfileDiscovery.discover(home: home, applicationRoots: [applications])
        check(discoveredAfterRemoval.map(\.profileDirectory) == ["Default"], "deleted cached profile does not block valid profile discovery")
        let stale = try BrowserLockStore(url: bindingURL)
        check(stale.binding(account: "second")?.profile == work, "missing profile binding retained without fallback")
        try stale.unlock(account: "second")
        check(stale.binding(account: "second") == nil && stale.binding(account: "renamed") != nil, "unlock removes only selected account mapping")
        check(fm.fileExists(atPath: data.appendingPathComponent("Default/Preferences").path), "unlock does not alter browser data")
        try state(data, profiles: ["Default": ["name": "个人"]])
        try fm.createDirectory(at: data.appendingPathComponent("Profile 99"), withIntermediateDirectories: true)
        do { try BrowserLockStore.validate(profile: changed(personal, component: "Profile 99")); check(false, "unregistered directory rejected") } catch { check(true, "unregistered directory rejected") }
        let noInvented = try BrowserProfileDiscovery.discover(home: home, applicationRoots: [applications])
        check(noInvented.count == 1, "unregistered physical directories are not invented as profiles")
        let original = try Data(contentsOf: bindingURL)
        try Data("broken json".utf8).write(to: bindingURL)
        do { _ = try BrowserLockStore(url: bindingURL); check(false, "corrupt lock file surfaced") } catch { check(true, "corrupt lock file surfaced") }
        let corrupted = try Data(contentsOf: bindingURL)
        check(corrupted == Data("broken json".utf8), "corrupt lock file preserved")
        try original.write(to: bindingURL)
        let blockedURL = root.appendingPathComponent("blocked/locks.json")
        let blocked = try BrowserLockStore(url: blockedURL)
        try Data("file".utf8).write(to: blockedURL.deletingLastPathComponent())
        do { try blocked.lock(account: "first", profile: personal); check(false, "save error surfaced") } catch { check(true, "save error surfaced") }
        check(blocked.locks.isEmpty, "failed save does not mutate in-memory binding")
        try Data("bad browser metadata".utf8).write(to: data.appendingPathComponent("Local State"))
        do { _ = try BrowserProfileDiscovery.discover(home: home, applicationRoots: [applications]); check(false, "corrupt browser metadata surfaced") } catch { check(true, "corrupt browser metadata surfaced") }
        let stateFile = data.appendingPathComponent("Local State")
        try fm.removeItem(at: stateFile)
        let missingCache = try BrowserProfileDiscovery.discover(home: home, applicationRoots: [applications])
        check(missingCache.isEmpty, "missing Local State is an empty discovery result")
        do { try BrowserLockStore.validate(profile: personal); check(false, "missing Local State cannot validate a saved binding") }
        catch BrowserLockError.invalidProfile { check(true, "missing Local State cannot validate a saved binding") }
        try fm.createDirectory(at: stateFile, withIntermediateDirectories: false)
        do { _ = try BrowserProfileDiscovery.discover(home: home, applicationRoots: [applications]); check(false, "Local State directory is reported as unreadable") }
        catch BrowserLockError.unreadableProfiles { check(true, "Local State directory is reported as unreadable") }
        try fm.removeItem(at: stateFile)
        try state(data, profiles: ["Default": ["name": "个人"]])
        let restrictedHome = root.appendingPathComponent("restricted-home")
        let restrictedParent = restrictedHome.appendingPathComponent("Library/Application Support/Google")
        try state(restrictedParent.appendingPathComponent("Chrome"), profiles: ["Default": ["name": "Permission fixture"]])
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: restrictedParent.path)
        let permissionErrorReported: Bool
        do {
            _ = try BrowserProfileDiscovery.discover(home: restrictedHome, applicationRoots: [applications])
            permissionErrorReported = false
        } catch BrowserLockError.unreadableProfiles { permissionErrorReported = true }
        catch { permissionErrorReported = false }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: restrictedParent.path)
        check(permissionErrorReported, "denied profile-cache access is not mistaken for a missing cache")
        _ = try app(applications, name: "Microsoft Edge", identifier: "com.microsoft.edgemac")
        _ = try app(home.appendingPathComponent("Applications"), name: "Brave Browser", identifier: "com.brave.Browser")
        _ = try app(applications.appendingPathComponent("Tools"), name: "Chromium", identifier: "org.chromium.Chromium")
        try state(home.appendingPathComponent("Library/Application Support/Microsoft Edge"), profiles: ["Profile 8": ["name": "Edge 工作"]])
        try state(home.appendingPathComponent("Library/Application Support/BraveSoftware/Brave-Browser"), profiles: ["Default": ["name": "Brave 个人"]])
        try state(home.appendingPathComponent("Library/Application Support/Chromium"), profiles: ["Custom Person": ["name": "测试用户"]])
        let all = try BrowserProfileDiscovery.discover(home: home, applicationRoots: [applications, home.appendingPathComponent("Applications")])
        check(Set(all.map(\.bundleID)) == Set(["com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser", "org.chromium.Chromium"]), "all four browser data layouts discovered by bundle identity")
        check(all.contains(where: { $0.profileDirectory == "Custom Person" }), "actual registered directory names are used instead of inventing Default/Profile N")
        check(all.filter { $0.bundleID != "com.google.Chrome" }.allSatisfy { $0.identityHint == nil }, "missing browser identity hint remains absent")
        let legacyData = try JSONEncoder().encode(personal)
        let legacy = try JSONDecoder().decode(BrowserProfile.self, from: legacyData)
        check(legacy.manualSelection == nil && legacy == personal, "profiles without manualSelection decode in the original automatic mode")
        let manualData = root.appendingPathComponent("Explicit Browser Data")
        let manualDirectory = manualData.appendingPathComponent("Profile Chosen")
        let marker = manualDirectory.appendingPathComponent("Preferences")
        try fm.createDirectory(at: manualDirectory, withIntermediateDirectories: true)
        try Data("PRIVATE-MANUAL-PREFERENCES".utf8).write(to: marker)
        // A stat remains possible but reading either marker contents or Local
        // State would fail. Only explicit profile-directory validation may pass.
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: marker.path)
        try fm.createDirectory(at: manualData.appendingPathComponent("Local State"), withIntermediateDirectories: false)
        let manual = try BrowserProfileDiscovery.manualProfile(app: chrome, directory: manualDirectory)
        check(manual.manualSelection == true && manual.identityHint == nil && manual.displayName == "Profile Chosen", "manual profile uses directory name and never infers a browser identity hint")
        check(manual.userDataDirectory == manualData.path && manual.profileDirectory == manualDirectory.lastPathComponent && manual.appPath == chrome.path,
              "manual selection keeps the exact selected app, parent data directory and profile component")
        let manualStoreURL = root.appendingPathComponent("manual-locks/locks.json")
        let manualStore = try BrowserLockStore(url: manualStoreURL)
        try manualStore.lock(account: "manual", profile: manual)
        let restoredManual = try BrowserLockStore(url: manualStoreURL).binding(account: "manual")!
        check(restoredManual.profile == manual, "manual selection and exact route persist through reopening")
        try BrowserLockStore.validate(profile: restoredManual.profile)
        check(true, "the routing validator accepts manual selection without reading Local State or Preferences contents")
        let manualSaved = try String(contentsOf: manualStoreURL, encoding: .utf8)
        check(!manualSaved.contains("PRIVATE-MANUAL-PREFERENCES"), "manual binding does not store Preferences contents")
        try manualStore.unlock(account: "manual")
        let unboundManual = try BrowserLockStore(url: manualStoreURL)
        check(unboundManual.locks.isEmpty && unboundManual.registeredProfiles == [manual], "manual profile remains available after its final account is unbound")
        try manualStore.lock(account: "manual", profile: manual)
        for source in all {
            let selected = try BrowserProfileDiscovery.manualProfile(app: URL(fileURLWithPath: source.appPath), directory: manualDirectory)
            check(selected.bundleID == source.bundleID && selected.manualSelection == true, "manual selection supports each known browser identity")
        }
        do { _ = try BrowserProfileDiscovery.manualProfile(app: safari, directory: manualDirectory); check(false, "manual selection rejects unsupported browser") }
        catch BrowserLockError.unsupportedBrowser { check(true, "manual selection rejects unsupported browser") }
        try fm.removeItem(at: marker)
        do { try BrowserLockStore.validate(profile: manual); check(false, "manual binding rejects a missing Preferences marker") }
        catch BrowserLockError.invalidProfile { check(true, "manual binding rejects a missing Preferences marker") }
        try fm.createDirectory(at: marker, withIntermediateDirectories: false)
        do { try BrowserLockStore.validate(profile: manual); check(false, "manual binding rejects a Preferences directory") }
        catch BrowserLockError.invalidProfile { check(true, "manual binding rejects a Preferences directory") }
        try fm.removeItem(at: marker)
        try fm.createSymbolicLink(at: marker, withDestinationURL: data.appendingPathComponent("Default/Preferences"))
        do { try BrowserLockStore.validate(profile: manual); check(false, "manual binding rejects a symbolic-link marker") }
        catch BrowserLockError.invalidProfile { check(true, "manual binding rejects a symbolic-link marker") }
        try fm.removeItem(at: manualDirectory)
        do { try BrowserLockStore.validate(profile: manual); check(false, "manual binding rejects a removed profile directory") }
        catch BrowserLockError.invalidProfile { check(true, "manual binding rejects a removed profile directory") }
        check(manualStore.binding(account: "manual")?.profile == manual, "invalid manual selection remains bound and never falls back")
        let modeAfterReplacement = try fm.attributesOfItem(atPath: bindingURL.path)[.posixPermissions] as? NSNumber
        check(modeAfterReplacement?.intValue == 0o600, "replacement preserves private file permissions")
        print("PASS: \(count) browser lock checks")
    }
}
