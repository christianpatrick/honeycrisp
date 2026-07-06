import AppKit
import Foundation

/// Creates and extends notes with raw in-process Apple events to Notes
/// (tier 3 in the AGENTS.md hierarchy). Codes come straight from
/// Notes.sdef: class note with the HTML body property, folder cfol, the
/// app's default account dfac and its default folder dfol. Notes has no
/// append primitive, so append reads the body and sets it back extended;
/// locked notes and attachment carriers are refused before anything is
/// touched, because a body rewrite drops attachments. No osascript, no
/// AppleScript source, nothing written to a store Notes owns.
public struct AppleEventNoteWriter: NoteWriting {
    private static let notesBundleID = "com.apple.Notes"
    private let targets: any NotesDatabaseReading

    public init(targets: any NotesDatabaseReading) {
        self.targets = targets
    }

    // MARK: - Create

    public func create(title: String, body: String?, folder: String?) async throws
        -> NoteCreateReceipt
    {
        try await ensureNotesIsRunning()
        let html = NoteHTML.body(title: title, text: body)
        let specifier = try await withLaunchRetry {
            try Self.createEvent(html: html, folder: folder)
        }
        // The reply specifier carries the new note's x-coredata id; its
        // primary key reads back through the store so the receipt can
        // hand the model a real id and link. A store that is not
        // readable, or not caught up yet, degrades the receipt to nils
        // instead of failing a create that already happened.
        var summary: NoteSummary?
        if let primaryKey = Self.primaryKey(fromSpecifier: specifier) {
            summary = try? await targets.noteByPrimaryKey(primaryKey)
            if summary == nil {
                try? await Task.sleep(for: .milliseconds(300))
                summary = try? await targets.noteByPrimaryKey(primaryKey)
            }
        }
        return NoteCreateReceipt(
            id: summary?.id,
            url: summary.map { NoteLink.url(for: $0.id) },
            title: summary?.title ?? title,
            folder: summary?.folder ?? folder ?? ""
        )
    }

    /// core/crel: make new note at end of the target folder with the
    /// body as properties. Returns the object specifier Notes hands back.
    private static func createEvent(html: String, folder: String?) throws
        -> NSAppleEventDescriptor
    {
        let target = NSAppleEventDescriptor(bundleIdentifier: notesBundleID)
        let event = appleEvent(class: "core", id: "crel", target: target)
        event.setParam(NSAppleEventDescriptor(typeCode: code("note")), forKeyword: code("kocl"))

        let defaultAccount = try propertySpecifier(
            "dfac", from: NSAppleEventDescriptor.null())
        let container: NSAppleEventDescriptor
        if let folder {
            container = try nameSpecifier(class: "cfol", name: folder, from: defaultAccount)
        } else {
            container = try propertySpecifier("dfol", from: defaultAccount)
        }
        event.setParam(try insertionAtEnd(of: container), forKeyword: code("insh"))

        let properties = NSAppleEventDescriptor.record()
        properties.setDescriptor(NSAppleEventDescriptor(string: html), forKeyword: code("body"))
        event.setParam(properties, forKeyword: code("prdt"))

        let reply = try sendChecked(event, folder: folder)
        guard let specifier = reply.paramDescriptor(forKeyword: keyDirectObject) else {
            throw ToolFailure("Notes did not hand back the new note.")
        }
        return specifier
    }

    /// The p<N> primary key inside an x-coredata note id, read from the
    /// reply specifier directly when it uses the by-id form.
    private static func primaryKey(fromSpecifier specifier: NSAppleEventDescriptor) -> Int64? {
        let record = specifier.coerce(toDescriptorType: code("reco")) ?? specifier
        guard let seld = record.forKeyword(code("seld"))?.stringValue else { return nil }
        return primaryKey(fromScriptID: seld)
    }

    static func primaryKey(fromScriptID id: String) -> Int64? {
        guard let range = id.range(of: "/ICNote/p") else { return nil }
        return Int64(id[range.upperBound...])
    }

    // MARK: - Append

    public func append(id: String, body: String) async throws -> NoteAppendReceipt {
        guard let target = try await targets.scriptTarget(id: id) else {
            throw ToolFailure(
                "No note matched that id. Use the id notes_search returns.")
        }
        guard !target.locked else {
            throw ToolFailure(
                "\u{201C}\(target.title)\u{201D} is password protected, so Honeycrisp cannot change it."
            )
        }
        guard !target.hasAttachments else {
            throw ToolFailure(
                "\u{201C}\(target.title)\u{201D} has attachments, and rewriting its body over Apple events would drop them, so nothing was changed."
            )
        }
        try await ensureNotesIsRunning()
        let receipt = try await withLaunchRetry {
            let note = try Self.idSpecifier(class: "note", id: target.appleScriptID)
            let old = try Self.getBody(of: note)
            try Self.setBody(of: note, to: old + NoteHTML.paragraphs(body))
            return NoteAppendReceipt(id: id, title: target.title)
        }
        return receipt
    }

    /// core/getd of the note's body property.
    private static func getBody(of note: NSAppleEventDescriptor) throws -> String {
        let target = NSAppleEventDescriptor(bundleIdentifier: notesBundleID)
        let event = appleEvent(class: "core", id: "getd", target: target)
        event.setParam(try propertySpecifier("body", from: note), forKeyword: keyDirectObject)
        let reply = try sendChecked(event)
        guard let body = reply.paramDescriptor(forKeyword: keyDirectObject)?.stringValue else {
            throw ToolFailure("Notes did not hand back the note body.")
        }
        return body
    }

    /// core/setd of the note's body property.
    private static func setBody(of note: NSAppleEventDescriptor, to html: String) throws {
        let target = NSAppleEventDescriptor(bundleIdentifier: notesBundleID)
        let event = appleEvent(class: "core", id: "setd", target: target)
        event.setParam(try propertySpecifier("body", from: note), forKeyword: keyDirectObject)
        event.setParam(NSAppleEventDescriptor(string: html), forKeyword: code("data"))
        _ = try sendChecked(event)
    }

    // MARK: - Object specifiers

    /// property <four> of <container>.
    private static func propertySpecifier(
        _ four: String, from container: NSAppleEventDescriptor
    ) throws -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(NSAppleEventDescriptor(typeCode: code("prop")), forKeyword: code("want"))
        record.setDescriptor(container, forKeyword: code("from"))
        record.setDescriptor(NSAppleEventDescriptor(enumCode: code("prop")), forKeyword: code("form"))
        record.setDescriptor(NSAppleEventDescriptor(typeCode: code(four)), forKeyword: code("seld"))
        guard let specifier = record.coerce(toDescriptorType: code("obj ")) else {
            throw ToolFailure("Could not address Notes.")
        }
        return specifier
    }

    /// <class> named <name> of <container>.
    private static func nameSpecifier(
        class wanted: String, name: String, from container: NSAppleEventDescriptor
    ) throws -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(NSAppleEventDescriptor(typeCode: code(wanted)), forKeyword: code("want"))
        record.setDescriptor(container, forKeyword: code("from"))
        record.setDescriptor(NSAppleEventDescriptor(enumCode: code("name")), forKeyword: code("form"))
        record.setDescriptor(NSAppleEventDescriptor(string: name), forKeyword: code("seld"))
        guard let specifier = record.coerce(toDescriptorType: code("obj ")) else {
            throw ToolFailure("Could not address the Notes folder.")
        }
        return specifier
    }

    /// <class> id <id>, the by-id form over the x-coredata bridge id.
    private static func idSpecifier(class wanted: String, id: String) throws
        -> NSAppleEventDescriptor
    {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(NSAppleEventDescriptor(typeCode: code(wanted)), forKeyword: code("want"))
        record.setDescriptor(NSAppleEventDescriptor.null(), forKeyword: code("from"))
        record.setDescriptor(NSAppleEventDescriptor(enumCode: code("ID  ")), forKeyword: code("form"))
        record.setDescriptor(NSAppleEventDescriptor(string: id), forKeyword: code("seld"))
        guard let specifier = record.coerce(toDescriptorType: code("obj ")) else {
            throw ToolFailure("Could not address the note.")
        }
        return specifier
    }

    /// insertion location: at end of <container>.
    private static func insertionAtEnd(of container: NSAppleEventDescriptor) throws
        -> NSAppleEventDescriptor
    {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(container, forKeyword: code("kobj"))
        record.setDescriptor(NSAppleEventDescriptor(enumCode: code("end ")), forKeyword: code("kpos"))
        guard let location = record.coerce(toDescriptorType: code("insl")) else {
            throw ToolFailure("Could not address the end of the folder.")
        }
        return location
    }

    // MARK: - Plumbing

    private static func appleEvent(
        class eventClass: String, id eventID: String, target: NSAppleEventDescriptor
    ) -> NSAppleEventDescriptor {
        NSAppleEventDescriptor.appleEvent(
            withEventClass: code(eventClass),
            eventID: code(eventID),
            targetDescriptor: target,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
    }

    private static func sendChecked(
        _ event: NSAppleEventDescriptor, folder: String? = nil
    ) throws -> NSAppleEventDescriptor {
        do {
            return try event.sendEvent(options: [.waitForReply], timeout: 30)
        } catch let error as NSError where error.code == -1743 {
            throw ToolFailure(
                "macOS is blocking Honeycrisp from driving Notes. Grant Automation access in System Settings under Privacy & Security, Automation, then try again."
            )
        } catch let error as NSError where error.code == -1728 && folder != nil {
            throw ToolFailure(
                "There is no folder named \u{201C}\(folder ?? "")\u{201D} in your default Notes account. notes_folders lists the folder names."
            )
        }
    }

    /// procNotFound: Notes launched but was not ready yet, so try once
    /// more after a beat.
    private func withLaunchRetry<T>(_ work: () async throws -> T) async throws -> T {
        do {
            return try await work()
        } catch let error as NSError where error.code == -600 {
            try await Task.sleep(for: .seconds(1))
            return try await work()
        }
    }

    private static func code(_ four: String) -> FourCharCode {
        var result: FourCharCode = 0
        for byte in four.utf8 {
            result = (result << 8) | FourCharCode(byte)
        }
        return result
    }

    // MARK: - Launching

    private func ensureNotesIsRunning() async throws {
        let running = NSRunningApplication.runningApplications(
            withBundleIdentifier: Self.notesBundleID)
        guard running.isEmpty else { return }
        guard
            let url = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: Self.notesBundleID)
        else {
            throw ToolFailure("Notes is not installed on this Mac.")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }
}

private let keyDirectObject: AEKeyword = {
    var result: AEKeyword = 0
    for byte in "----".utf8 {
        result = (result << 8) | AEKeyword(byte)
    }
    return result
}()
