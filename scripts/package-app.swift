#!/usr/bin/env swift
// Assembles dist/Honeycrisp.app from a release build. Run from the repo
// root with: swift scripts/package-app.swift
//
// Everything in this project is native Swift, including this script. It
// shells out only to the toolchain binaries that have no API form:
// swift build, iconutil, codesign.

import AppKit
import Foundation

let fileManager = FileManager.default
let root = URL(fileURLWithPath: fileManager.currentDirectoryPath)

func run(_ tool: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    process.currentDirectoryURL = root
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        fatalError("\(tool) \(arguments.joined(separator: " ")) failed")
    }
}

/// Runs a tool and returns its trimmed stdout, or nil on any failure.
func capture(_ tool: String, _ arguments: [String]) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    process.currentDirectoryURL = root
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    do { try process.run() } catch { return nil }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let text = String(decoding: data, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? nil : text
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("package-app: " + message + "\n").utf8))
    exit(1)
}

// 1. Release build.
print("building release...")
try run("/usr/bin/swift", ["build", "-c", "release"])

let releaseDir = root.appendingPathComponent(".build/release")
let appExecutable = releaseDir.appendingPathComponent("HoneycrispMenuBar")
let cliExecutable = releaseDir.appendingPathComponent("honeycrisp")
guard fileManager.fileExists(atPath: appExecutable.path),
    fileManager.fileExists(atPath: cliExecutable.path)
else {
    fail("release binaries are missing from .build/release")
}

// 2. Bundle structure.
let app = root.appendingPathComponent("dist/Honeycrisp.app")
let contents = app.appendingPathComponent("Contents")
let macOS = contents.appendingPathComponent("MacOS")
let resources = contents.appendingPathComponent("Resources")
try? fileManager.removeItem(at: app)
try fileManager.createDirectory(at: macOS, withIntermediateDirectories: true)
try fileManager.createDirectory(at: resources, withIntermediateDirectories: true)

// 3. Binaries. The CLI must be honeycrisp-cli: on a case-insensitive
// filesystem a binary named honeycrisp would overwrite the app executable
// Honeycrisp (see the AGENTS.md findings).
try fileManager.copyItem(at: appExecutable, to: macOS.appendingPathComponent("Honeycrisp"))
try fileManager.copyItem(at: cliExecutable, to: macOS.appendingPathComponent("honeycrisp-cli"))

// 4. Brand resources from the committed artwork in assets/.
// Keys are the resource names the app loads; values are repo paths.
let artwork: [String: String] = [
    "icon.svg": "assets/marks/honeycrisp-icon.svg",
    "glyph-black.svg": "assets/marks/honeycrisp-glyph-black.svg",
    "mail.svg": "assets/app-icons/mail.svg",
    "reminders.svg": "assets/app-icons/reminders.svg",
    "messages.svg": "assets/app-icons/messages.svg",
    "contacts.svg": "assets/app-icons/contacts.svg",
    "calendar.svg": "assets/app-icons/calendar.svg",
]
for (name, path) in artwork {
    let source = root.appendingPathComponent(path)
    guard fileManager.fileExists(atPath: source.path) else {
        fail("missing artwork: \(path)")
    }
    try fileManager.copyItem(at: source, to: resources.appendingPathComponent(name))
}

// 4b. The brand font (OFL licensed; the license ships beside it).
for fontFile in ["Sora[wght].ttf", "OFL.txt"] {
    let source = root.appendingPathComponent("assets/fonts/\(fontFile)")
    guard fileManager.fileExists(atPath: source.path) else {
        fail("missing font file: assets/fonts/\(fontFile)")
    }
    try fileManager.copyItem(at: source, to: resources.appendingPathComponent(fontFile))
}

// 5. App icon: flat render of the brand icon into an icns. The true Liquid
// Glass icon needs an Xcode-built asset catalog; this render is the
// documented fallback.
print("rendering icon...")
let iconSource = root.appendingPathComponent("assets/marks/honeycrisp-icon.svg")
if let svgImage = NSImage(contentsOf: iconSource) {
    let iconset = root.appendingPathComponent("dist/AppIcon.iconset")
    try? fileManager.removeItem(at: iconset)
    try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)
    let sizes: [(Int, String)] = [
        (16, "icon_16x16"), (32, "icon_16x16@2x"), (32, "icon_32x32"),
        (64, "icon_32x32@2x"), (128, "icon_128x128"), (256, "icon_128x128@2x"),
        (256, "icon_256x256"), (512, "icon_256x256@2x"), (512, "icon_512x512"),
        (1024, "icon_512x512@2x"),
    ]
    for (size, name) in sizes {
        let target = NSImage(size: NSSize(width: size, height: size))
        target.lockFocus()
        svgImage.draw(
            in: NSRect(x: 0, y: 0, width: size, height: size),
            from: .zero, operation: .sourceOver, fraction: 1)
        target.unlockFocus()
        guard let tiff = target.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff),
            let png = bitmap.representation(using: .png, properties: [:])
        else { fail("could not render \(name)") }
        try png.write(to: iconset.appendingPathComponent("\(name).png"))
    }
    try run("/usr/bin/iconutil", ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("AppIcon.icns").path])
    try? fileManager.removeItem(at: iconset)
} else {
    print("warning: icon.svg did not load; skipping the icns")
}

// 6. Info.plist. The bundle id is locked (changing it resets TCC grants).
// The git tag is the version's single source of truth: the release workflow
// sets HONEYCRISP_VERSION from the computed tag; a local build reads the
// latest tag; a tagless checkout falls back to a dev marker.
func resolveVersion() -> String {
    func strip(_ v: String) -> String { v.hasPrefix("v") ? String(v.dropFirst()) : v }
    if let env = ProcessInfo.processInfo.environment["HONEYCRISP_VERSION"], !env.isEmpty {
        return strip(env)
    }
    if let tag = capture("/usr/bin/git", ["describe", "--tags", "--abbrev=0"]) {
        return strip(tag)
    }
    return "0.0.0-dev"
}
let version = resolveVersion()
print("version: \(version)")
let plist: [String: Any] = [
    "CFBundleIdentifier": "app.honeycrisp.Honeycrisp",
    "CFBundleName": "Honeycrisp",
    "CFBundleDisplayName": "Honeycrisp",
    "CFBundleExecutable": "Honeycrisp",
    "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": version,
    "CFBundleVersion": version,
    "CFBundleIconFile": "AppIcon",
    "LSMinimumSystemVersion": "15.0",
    "LSUIElement": true,
    "NSContactsUsageDescription":
        "Honeycrisp looks up and saves contacts only when your assistant asks for them. Nothing leaves your Mac.",
    "NSRemindersFullAccessUsageDescription":
        "Honeycrisp reads and creates reminders only when your assistant asks. Nothing leaves your Mac.",
    "NSRemindersUsageDescription":
        "Honeycrisp reads and creates reminders only when your assistant asks. Nothing leaves your Mac.",
    "NSCalendarsFullAccessUsageDescription":
        "Honeycrisp reads and creates calendar events only when your assistant asks. Nothing leaves your Mac.",
    "NSCalendarsUsageDescription":
        "Honeycrisp reads and creates calendar events only when your assistant asks. Nothing leaves your Mac.",
    "NSAppleEventsUsageDescription":
        "Honeycrisp drives Mail and Messages only to save a Mail draft, mark messages read, and send what you approve. Nothing leaves your Mac without you.",
    "NSHumanReadableCopyright": "MIT licensed. Made with care by Christian.",
    // Sparkle in-app updates. The feed is the latest release's appcast; the
    // public key verifies update signatures (the private key stays in CI).
    "SUFeedURL": "https://github.com/christianpatrick/honeycrisp/releases/latest/download/appcast.xml",
    "SUPublicEDKey": "dPED5ZqzSxXxJYYub5ICxU7SwvZsEfx1Fp1sP9V5AbI=",
    "SUEnableAutomaticChecks": true,
]
let plistData = try PropertyListSerialization.data(
    fromPropertyList: plist, format: .xml, options: 0)
try plistData.write(to: contents.appendingPathComponent("Info.plist"))

// 6b. Bundle Sparkle.framework (the app links it via @rpath) and point the
// app's rpath at Contents/Frameworks. install_name_tool must run before
// signing; signing is the last step, so the order holds.
print("bundling Sparkle.framework...")
let frameworks = contents.appendingPathComponent("Frameworks")
try fileManager.createDirectory(at: frameworks, withIntermediateDirectories: true)
func findSparkleFramework() -> URL? {
    let preferred = root.appendingPathComponent(
        ".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework")
    if fileManager.fileExists(atPath: preferred.path) { return preferred }
    if let line = capture(
        "/usr/bin/find",
        [".build/artifacts", "-path", "*Sparkle.xcframework/macos*/Sparkle.framework", "-type", "d"]
    )?.split(separator: "\n").first {
        return root.appendingPathComponent(String(line))
    }
    return nil
}
guard let sparkleSource = findSparkleFramework() else {
    fail("Sparkle.framework not found under .build; run swift build first")
}
let sparkleFramework = frameworks.appendingPathComponent("Sparkle.framework")
try? fileManager.removeItem(at: sparkleFramework)
try run("/usr/bin/ditto", [sparkleSource.path, sparkleFramework.path])
try run(
    "/usr/bin/install_name_tool",
    ["-add_rpath", "@executable_path/../Frameworks", macOS.appendingPathComponent("Honeycrisp").path])

// 7. Sign. Ad-hoc signatures change every build, and macOS binds grants
// like Full Disk Access to the signature, so ad-hoc rebuilds orphan them.
// Prefer a stable identity: HONEYCRISP_SIGN_IDENTITY if set, else the
// first Apple Development certificate, else ad-hoc with a warning. After
// the signing identity changes, Full Disk Access needs one off-and-on
// toggle in System Settings to rebind.
func signingIdentity() -> String {
    if let forced = ProcessInfo.processInfo.environment["HONEYCRISP_SIGN_IDENTITY"],
        !forced.isEmpty
    {
        return forced
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    process.arguments = ["find-identity", "-v", "-p", "codesigning"]
    let pipe = Pipe()
    process.standardOutput = pipe
    do {
        try process.run()
    } catch {
        return "-"
    }
    process.waitUntilExit()
    let output = String(
        decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    for line in output.split(separator: "\n") where line.contains("Apple Development") {
        if let hash = line.split(separator: " ").first(where: { $0.count == 40 }) {
            return String(hash)
        }
    }
    print(
        "warning: no stable signing identity found; ad-hoc signatures reset TCC grants on every rebuild"
    )
    return "-"
}

/// Submits the signed app to Apple and staples the ticket, but only when
/// notarytool credentials are in the environment (the release workflow sets
/// them). A local build without them signs and stops, which is correct: a
/// developer's own machine runs an un-notarized build it built itself.
func notarizeAndStaple() {
    let env = ProcessInfo.processInfo.environment
    guard let keyID = env["NOTARYTOOL_KEY_ID"], !keyID.isEmpty,
        let issuer = env["NOTARYTOOL_ISSUER_ID"], !issuer.isEmpty,
        let keyPath = env["NOTARYTOOL_KEY_PATH"], !keyPath.isEmpty
    else {
        print(
            "notarization: skipped (set NOTARYTOOL_KEY_ID, NOTARYTOOL_ISSUER_ID, NOTARYTOOL_KEY_PATH)"
        )
        return
    }
    print("notarizing (submits to Apple and waits)...")
    let zip = root.appendingPathComponent("dist/Honeycrisp.zip")
    try? fileManager.removeItem(at: zip)
    do {
        try run("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, zip.path])
        try run(
            "/usr/bin/xcrun",
            [
                "notarytool", "submit", zip.path,
                "--key", keyPath, "--key-id", keyID, "--issuer", issuer, "--wait",
            ])
        try run("/usr/bin/xcrun", ["stapler", "staple", app.path])
        print("notarized and stapled")
    } catch {
        fail("notarization failed")
    }
}

let identity = signingIdentity()
let isDeveloperID = identity.contains("Developer ID")
print(identity == "-" ? "signing ad-hoc..." : "signing with \(identity)...")

if isDeveloperID {
    // Distribution build: hardened runtime and a secure timestamp throughout.
    // Sign deepest first (Sparkle's nested code, then its framework, then the
    // helper CLI), and the bundle last; notarization rejects the --deep
    // shortcut. Only Honeycrisp itself carries the Apple Events entitlement.
    let entitlements = root.appendingPathComponent("scripts/Honeycrisp.entitlements")
    guard fileManager.fileExists(atPath: entitlements.path) else {
        fail("missing entitlements: scripts/Honeycrisp.entitlements")
    }
    func signRuntime(_ target: String) throws {
        try run(
            "/usr/bin/codesign",
            ["--force", "--options", "runtime", "--timestamp", "--sign", identity, target])
    }
    func signEntitled(_ target: String) throws {
        try run(
            "/usr/bin/codesign",
            [
                "--force", "--options", "runtime", "--timestamp",
                "--entitlements", entitlements.path, "--sign", identity, target,
            ])
    }
    for kind in ["*.xpc", "*.app"] {
        if let out = capture("/usr/bin/find", [sparkleFramework.path, "-name", kind, "-depth"]) {
            for line in out.split(separator: "\n") { try signRuntime(String(line)) }
        }
    }
    let autoupdate = sparkleFramework.appendingPathComponent("Versions/B/Autoupdate")
    if fileManager.fileExists(atPath: autoupdate.path) { try signRuntime(autoupdate.path) }
    try signRuntime(sparkleFramework.path)
    try signEntitled(macOS.appendingPathComponent("honeycrisp-cli").path)
    try signEntitled(app.path)
    notarizeAndStaple()
} else {
    // Local build: the simple, FDA-stable Apple Development (or ad-hoc) sign.
    // --deep reaches Sparkle's nested code, which is fine off the notarized
    // path.
    try run("/usr/bin/codesign", ["--force", "--deep", "--sign", identity, app.path])
}

print("done: \(app.path)")
