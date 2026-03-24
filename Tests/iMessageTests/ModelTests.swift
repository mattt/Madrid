import Foundation
import Testing

@testable import iMessage

@Suite
struct ModelTests {
    @Test
    func testChatComparable() {
        let older = Chat(
            id: "chat-1",
            displayName: nil,
            participants: [],
            lastMessageDate: Date.distantPast
        )
        let newer = Chat(
            id: "chat-2",
            displayName: nil,
            participants: [],
            lastMessageDate: Date.distantFuture
        )
        #expect(older < newer)
        #expect(!(newer < older))

        let noDate1 = Chat(id: "a", displayName: nil, participants: [], lastMessageDate: nil)
        let noDate2 = Chat(id: "b", displayName: nil, participants: [], lastMessageDate: nil)
        #expect(!(noDate1 < noDate2))
        #expect(!(noDate2 < noDate1))
    }

    @Test
    func testAccountServiceRawValue() {
        #expect(Account.Service(rawValue: "iMessage") == .iMessage)
        #expect(Account.Service(rawValue: "imessage") == .iMessage)
        #expect(Account.Service(rawValue: "iMESSAGE") == .iMessage)
        #expect(Account.Service(rawValue: "SMS") == .sms)
        #expect(Account.Service(rawValue: "sms") == .sms)
        #expect(Account.Service(rawValue: "other") == .sms)
    }

    @Test
    func testAccountHandleCodable() throws {
        let handle = Account.Handle(rawValue: "+1234567890")
        let data = try JSONEncoder().encode(handle)
        let decoded = try JSONDecoder().decode(Account.Handle.self, from: data)
        #expect(decoded.rawValue == handle.rawValue)
    }

    @Test
    func testAccountHandleStringLiteral() {
        let handle: Account.Handle = "+1234567890"
        #expect(handle.rawValue == "+1234567890")
    }

    @Test
    func testAccountHandleDescription() {
        let handle = Account.Handle(rawValue: "user@example.com")
        #expect(handle.description == "user@example.com")
    }

    @Test
    func testGUIDComparable() {
        #expect(GUID(rawValue: "a") < GUID(rawValue: "b"))
        #expect(!(GUID(rawValue: "b") < GUID(rawValue: "a")))
    }

    @Test
    func testGUIDCodable() throws {
        let guid = GUID(rawValue: "chat-guid-1")
        let data = try JSONEncoder().encode(guid)
        let decoded = try JSONDecoder().decode(GUID.self, from: data)
        #expect(decoded.rawValue == guid.rawValue)
    }

    @Test
    func testGUIDStringLiteral() {
        let guid: GUID = "msg-123"
        #expect(guid.rawValue == "msg-123")
    }

    @Test
    func testGUIDDescription() {
        let guid = GUID(rawValue: "chat-guid-1")
        #expect(guid.description == "chat-guid-1")
    }
}
