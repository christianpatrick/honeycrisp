import Foundation
import Testing
import HoneycrispCore

@Suite("Approval broker")
struct ApprovalBrokerTests {
    private var prompt: ApprovalPrompt {
        ApprovalPrompt(
            app: .mail,
            action: "send",
            client: "Claude Desktop",
            message: "Claude Desktop wants to send a mail to alex@studio.com.",
            subtitle: "Sending is not auto approved."
        )
    }

    /// A broker whose surfaced requests arrive on an AsyncStream, so tests
    /// wait deterministically instead of polling.
    private func makeBroker(timeout: Duration = .seconds(5))
        -> (ApprovalBroker, AsyncStream<PendingApproval>)
    {
        let (stream, continuation) = AsyncStream.makeStream(of: PendingApproval.self)
        let broker = ApprovalBroker(timeout: timeout) { continuation.yield($0) }
        return (broker, stream)
    }

    @Test("allowing resolves the request true and clears pending")
    func allow() async throws {
        let (broker, requests) = makeBroker()
        async let answer = broker.requestApproval(prompt)
        let pending = try #require(await requests.first { _ in true })
        await broker.resolve(id: pending.id, approved: true)
        #expect(await answer == true)
        #expect(await broker.pending().isEmpty)
    }

    @Test("denying resolves the request false")
    func deny() async throws {
        let (broker, requests) = makeBroker()
        async let answer = broker.requestApproval(prompt)
        let pending = try #require(await requests.first { _ in true })
        await broker.resolve(id: pending.id, approved: false)
        #expect(await answer == false)
    }

    @Test("an unanswered request times out as denied")
    func timeout() async {
        let (broker, _) = makeBroker(timeout: .milliseconds(50))
        let answer = await broker.requestApproval(prompt)
        #expect(answer == false)
        #expect(await broker.pending().isEmpty)
    }

    @Test("the handler receives the pending approval with the original prompt")
    func handlerPayload() async throws {
        let (broker, requests) = makeBroker()
        async let answer = broker.requestApproval(prompt)
        let pending = try #require(await requests.first { _ in true })
        #expect(pending.prompt == prompt)
        #expect(await broker.pending().first?.id == pending.id)
        await broker.resolve(id: pending.id, approved: true)
        _ = await answer
    }

    @Test("concurrent requests resolve independently by id")
    func concurrent() async throws {
        let (broker, requests) = makeBroker()
        let second = ApprovalPrompt(
            app: .messages, action: "send", client: "Zed",
            message: "Zed wants to send a message to Maya.",
            subtitle: "Sending is not auto approved.")
        async let first = broker.requestApproval(prompt)
        async let other = broker.requestApproval(second)

        var seen: [PendingApproval] = []
        for await pending in requests {
            seen.append(pending)
            if seen.count == 2 { break }
        }
        let firstPending = try #require(seen.first { $0.prompt.client == "Claude Desktop" })
        let otherPending = try #require(seen.first { $0.prompt.client == "Zed" })
        await broker.resolve(id: otherPending.id, approved: true)
        await broker.resolve(id: firstPending.id, approved: false)
        #expect(await first == false)
        #expect(await other == true)
    }

    @Test("resolving an unknown id does nothing")
    func unknownID() async throws {
        let (broker, requests) = makeBroker()
        async let answer = broker.requestApproval(prompt)
        let pending = try #require(await requests.first { _ in true })
        await broker.resolve(id: UUID(), approved: true)
        #expect(await broker.pending().count == 1)
        await broker.resolve(id: pending.id, approved: true)
        #expect(await answer == true)
    }

    @Test("a second resolve of the same id is a no-op")
    func doubleResolve() async throws {
        let (broker, requests) = makeBroker()
        async let answer = broker.requestApproval(prompt)
        let pending = try #require(await requests.first { _ in true })
        await broker.resolve(id: pending.id, approved: true)
        await broker.resolve(id: pending.id, approved: false)
        #expect(await answer == true)
        #expect(await broker.pending().isEmpty)
    }
}
