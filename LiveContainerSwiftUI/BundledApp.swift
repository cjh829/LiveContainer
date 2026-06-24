//
//  BundledApp.swift
//  LiveContainer
//
//  Zero-copy "playbox" launch: the guest app ships pre-patched (MH_DYLIB) and
//  pre-signed inside BundledApp.framework (built by Resources/Frameworks/
//  build_bundled_app.sh). At launch we just point a symlink in Applications/ at
//  the framework's app and let LiveContainer dlopen it in place — no copy and no
//  runtime signing (LCPatchRevision is already current and the binary is signed).
//

import Foundation

enum BundledApp {
    /// Hardcoded password of the embedded p12.
    static let certPassword = "1111"
    /// Bundle identifier of the embedded app (must match the IPA's Info.plist).
    static let bundleId = "com.group050.xrd.test"
    /// Fixed data container, kept in sync with build_bundled_app.sh.
    static let containerUUID = "B9111111-1111-4111-8111-111111111111"
    /// Name of the symlink placed in Applications/.
    static let relativeBundleName = "BundledApp.app"

    /// LiveContainer.app/Frameworks/BundledApp.framework
    static var frameworkURL: URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Frameworks", isDirectory: true)
            .appendingPathComponent("BundledApp.framework", isDirectory: true)
    }

    /// The guest .app inside the framework's Payload/ folder.
    static var guestAppURL: URL? {
        let payload = frameworkURL.appendingPathComponent("Payload", isDirectory: true)
        let apps = (try? FileManager.default.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "app" }
        return apps?.first
    }

    /// Raw bytes of the embedded signing certificate.
    static var certData: Data? {
        try? Data(contentsOf: frameworkURL.appendingPathComponent("cert.p12"))
    }

    /// (Re)create the Applications/ symlink pointing at the framework's app.
    /// Recreated every time because the app bundle's absolute path changes on
    /// reinstall/update. Returns the relative bundle name on success.
    @discardableResult
    static func refreshSymlink() -> String? {
        let fm = FileManager.default
        guard let guest = guestAppURL, fm.fileExists(atPath: guest.path) else {
            NSLog("[LC] BundledApp: framework guest app not found")
            return nil
        }
        try? fm.createDirectory(at: LCPath.bundlePath, withIntermediateDirectories: true)
        let dest = LCPath.bundlePath.appendingPathComponent(relativeBundleName)
        // remove any existing entry (including a dangling symlink)
        if (try? fm.destinationOfSymbolicLink(atPath: dest.path)) != nil || fm.fileExists(atPath: dest.path) {
            try? fm.removeItem(at: dest)
        }
        do {
            try fm.createSymbolicLink(at: dest, withDestinationURL: guest)
            return relativeBundleName
        } catch {
            NSLog("[LC] BundledApp: symlink failed: %@", error.localizedDescription)
            return nil
        }
    }

    /// Make sure the fixed data container exists so guest data persists.
    static func ensureContainer() {
        let container = LCContainer(folderName: containerUUID, name: "Default", isShared: false)
        let infoPlist = container.containerURL.appendingPathComponent("LCContainerInfo.plist")
        if !FileManager.default.fileExists(atPath: infoPlist.path) {
            container.makeLCContainerInfoPlist(
                appIdentifier: bundleId,
                keychainGroupId: Int.random(in: 0..<SharedModel.keychainAccessGroupCount))
        }
    }

    /// Write the hardcoded certificate into the app group defaults so that
    /// LiveContainer can sign guest apps without the user importing a p12.
    /// Safe to call repeatedly; it only writes when no usable cert is present.
    static func ensureCertificate() {
        if LCUtils.certificateData() != nil && LCSharedUtils.certificatePassword() != nil {
            return
        }
        guard let certData else {
            NSLog("[LC] BundledApp: certificate not found in framework")
            return
        }
        guard LCUtils.getCertTeamId(withKeyData: certData, password: certPassword) != nil else {
            NSLog("[LC] BundledApp: embedded certificate is invalid (wrong password?)")
            return
        }
        LCUtils.appGroupUserDefault.set(certData, forKey: "LCCertificateData")
        LCUtils.appGroupUserDefault.set(certPassword, forKey: "LCCertificatePassword")
        LCUtils.appGroupUserDefault.set(NSDate.now, forKey: "LCCertificateUpdateDate")
        UserDefaults.standard.set(LCSharedUtils.appGroupID(), forKey: "LCAppGroupID")
        NSLog("[LC] BundledApp: hardcoded certificate installed")
    }
}
