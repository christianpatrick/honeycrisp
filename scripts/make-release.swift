#!/usr/bin/env swift
// Turns the notarized dist/Honeycrisp.app into a versioned zip, signs it
// with the Sparkle EdDSA key, and writes dist/appcast.xml. Run after
// package-app.swift. Native Swift; it shells out only to ditto and to
// Sparkle's sign_update, which have no API form.
//
// Required environment:
//   HONEYCRISP_VERSION        the release version (no leading v)
//   SPARKLE_SIGN_UPDATE       path to Sparkle's sign_update tool
//   SPARKLE_PRIVATE_KEY_PATH  path to the exported Sparkle private key
//   GITHUB_REPOSITORY         owner/repo (GitHub Actions sets this)

import Foundation

let fileManager = FileManager.default
let root = URL(fileURLWithPath: fileManager.currentDirectoryPath)
let env = ProcessInfo.processInfo.environment

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("make-release: " + message + "\n").utf8))
    exit(1)
}

func run(_ tool: String, _ arguments: [String]) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    process.currentDirectoryURL = root
    do { try process.run() } catch { fail("\(tool) failed to launch") }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        fail("\(tool) \(arguments.joined(separator: " ")) failed")
    }
}

func capture(_ tool: String, _ arguments: [String]) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    process.currentDirectoryURL = root
    let pipe = Pipe()
    process.standardOutput = pipe
    do { try process.run() } catch { fail("\(tool) failed to launch") }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { fail("\(tool) failed") }
    return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

func require(_ key: String) -> String {
    guard let value = env[key], !value.isEmpty else { fail("\(key) is required") }
    return value
}

let version = require("HONEYCRISP_VERSION")
let app = root.appendingPathComponent("dist/Honeycrisp.app")
guard fileManager.fileExists(atPath: app.path) else {
    fail("dist/Honeycrisp.app not found; run package-app.swift first")
}

// 1. Versioned zip via ditto, the archive format Sparkle and notarization
//    both expect.
let zipName = "Honeycrisp-\(version).zip"
let zip = root.appendingPathComponent("dist/\(zipName)")
try? fileManager.removeItem(at: zip)
run("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, zip.path])

// 2. Sparkle EdDSA signature, using the sign_update tool SwiftPM already
//    fetched into Sparkle's checksum-verified artifact, not a separate
//    download. sign_update prints the enclosure attributes:
//    sparkle:edSignature="..." length="...".
func findSignUpdate() -> String {
    let preferred = root.appendingPathComponent(
        ".build/artifacts/sparkle/Sparkle/bin/sign_update")
    if fileManager.fileExists(atPath: preferred.path) { return preferred.path }
    for line in capture("/usr/bin/find", [".build/artifacts", "-name", "sign_update", "-type", "f"])
        .split(separator: "\n") where !line.contains("old_dsa") {
        return root.appendingPathComponent(String(line)).path
    }
    fail("sign_update not found under .build/artifacts; build first so SwiftPM resolves Sparkle")
}
let signUpdate = findSignUpdate()
let keyPath = require("SPARKLE_PRIVATE_KEY_PATH")
let signatureAttributes = capture(signUpdate, ["-f", keyPath, zip.path])

// 3. The enclosure lives on the GitHub release for this tag.
let repo = env["GITHUB_REPOSITORY"] ?? "christianpatrick/honeycrisp"
let downloadURL =
    "https://github.com/\(repo)/releases/download/v\(version)/\(zipName)"

// 4. The appcast Sparkle reads. One item for this release is enough for the
//    updater to compare versions and offer the download.
let pubDate: String = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
    return formatter.string(from: Date())
}()

let appcast = """
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Honeycrisp</title>
    <description>Updates for Honeycrisp.</description>
    <item>
      <title>Version \(version)</title>
      <pubDate>\(pubDate)</pubDate>
      <sparkle:version>\(version)</sparkle:version>
      <sparkle:shortVersionString>\(version)</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <enclosure url="\(downloadURL)" type="application/octet-stream" \(signatureAttributes) />
    </item>
  </channel>
</rss>

"""

try! appcast.write(
    to: root.appendingPathComponent("dist/appcast.xml"), atomically: true, encoding: .utf8)

// 5. A SHA-256 checksum for people who download the zip by hand. Sparkle's
//    EdDSA signature already protects the auto-update path.
let shaLine = capture("/usr/bin/shasum", ["-a", "256", zip.path])
let hash = shaLine.split(separator: " ").first.map(String.init) ?? ""
try! "\(hash)  \(zipName)\n".write(
    to: root.appendingPathComponent("dist/\(zipName).sha256"), atomically: true, encoding: .utf8)

print("release: \(zipName), appcast.xml, and \(zipName).sha256 for \(version)")
