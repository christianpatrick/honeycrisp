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

// 4. Brand resources from the committed artwork in assets/ (the product
// spec itself is never committed and packaging must not depend on it).
// Keys are the resource names the app loads; values are repo paths.
let artwork: [String: String] = [
    "icon.svg": "assets/marks/honeycrisp-icon.svg",
    "glyph-black.svg": "assets/marks/honeycrisp-glyph-black.svg",
    "glyph-white.svg": "assets/marks/honeycrisp-glyph-white.svg",
    "mail.svg": "assets/app-icons/mail.svg",
    "reminders.svg": "assets/app-icons/reminders.svg",
    "messages.svg": "assets/app-icons/messages.svg",
    "contacts.svg": "assets/app-icons/contacts.svg",
    "seed.svg": "assets/marks/seed.svg",
    "star.svg": "assets/marks/star.svg",
]
for (name, path) in artwork {
    let source = root.appendingPathComponent(path)
    guard fileManager.fileExists(atPath: source.path) else {
        fail("missing artwork: \(path)")
    }
    try fileManager.copyItem(at: source, to: resources.appendingPathComponent(name))
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
// Keep in sync with HoneycrispInfo.version.
let version = "0.1.3"
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
    "NSAppleEventsUsageDescription":
        "Honeycrisp drives Mail and Messages only to save drafts and send what you approve. Nothing leaves your Mac without you.",
    "NSHumanReadableCopyright": "MIT licensed. Made with care by Christian.",
]
let plistData = try PropertyListSerialization.data(
    fromPropertyList: plist, format: .xml, options: 0)
try plistData.write(to: contents.appendingPathComponent("Info.plist"))

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

let identity = signingIdentity()
print(identity == "-" ? "signing ad-hoc..." : "signing with \(identity)...")
try run("/usr/bin/codesign", ["--force", "--deep", "--sign", identity, app.path])

print("done: \(app.path)")
