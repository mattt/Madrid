import Foundation
import SQLite3
import Testing

@testable import iMessage
@testable import TypedStream

@Suite(.serialized)
struct DatabaseTests {
    var db: Database = Fixtures.testDatabase
    
    @Test
    func testDatabaseNotFound() async throws {
        do {
            _ = try Database(path: "/nonexistent/path")
            Issue.record("Should have thrown an error")
        } catch Database.Error.databaseNotFound {
            // Expected error
        }
    }

    @Test
    func testFetchChats() async throws {
        // Test basic fetch - should get both chats ordered by last message
        let chats = try db.fetchChats(limit: 10)
        #expect(chats.count == 2)
        #expect(chats[0].id.rawValue == "chat-guid-1")  // Most recent chat first
        #expect(chats[1].id.rawValue == "chat-guid-2")  // Older chat second

        // Test with date filter - should only get chat with recent messages
        let now = Date()
        let yesterday = now.addingTimeInterval(-86400)
        let filtered = try db.fetchChats(in: yesterday..<now)
        #expect(filtered.count == 1)
        #expect(filtered.first?.id.rawValue == "chat-guid-1")

        // Test with older date range - should get the second chat
        let threeDaysAgo = now.addingTimeInterval(-86400 * 3)
        let twoDaysAgo = now.addingTimeInterval(-86400 * 2)
        let oldFiltered = try db.fetchChats(in: threeDaysAgo..<twoDaysAgo)
        #expect(oldFiltered.count == 1)
        #expect(oldFiltered.first?.id.rawValue == "chat-guid-2")

        // Test with participants filter - should only match exact participant set
        let participants: Set<Account.Handle> = [
            "+1234567890",
            "person@example.com",
        ]
        let filteredChats = try db.fetchChats(with: participants)
        #expect(filteredChats.count == 1)
        #expect(filteredChats[0].id.rawValue == "chat-guid-1")

        // Test partial participant match - should not return chat-guid-1
        let partialMatch = try db.fetchChats(with: ["+1234567890", "third@example.com"])
        #expect(partialMatch.count == 1)
        #expect(partialMatch[0].id.rawValue == "chat-guid-2")

        // Test with non-matching participants
        let nonMatching = try db.fetchChats(with: [
            "nonexistent@example.com"
        ])
        #expect(nonMatching.isEmpty)
    }

    @Test
    func testFetchMessages() async throws {
        let chatId: Chat.ID = "chat-guid-1"

        // Test fetch by chat
        let chatMessages = try db.fetchMessages(for: chatId, limit: 10).sorted()
        #expect(chatMessages.count == 3)

        #expect(chatMessages[0].id.rawValue == "msg-guid-1")
        #expect(chatMessages[0].text == "Hello!")

        #expect(chatMessages[1].id.rawValue == "msg-guid-2")
        #expect(chatMessages[1].text == "Hi there")

        #expect(chatMessages[2].id.rawValue == "msg-guid-3")
        #expect(chatMessages[2].text == "Hello")

        // Test fetch by participants
        let participants: Set<Account.Handle> = [
            "+1234567890",
            "person@example.com",
        ]
        let participantMessages = try db.fetchMessages(with: participants)
        #expect(participantMessages.count == 3)
        #expect(participantMessages.contains { $0.sender?.rawValue == "+1234567890" })
        #expect(participantMessages.contains { $0.sender?.rawValue == "person@example.com" })

        // Test with date range
        let yesterday = Date().addingTimeInterval(-86400)
        let today = Date()
        let rangeMessages = try db.fetchMessages(
            for: chatId,
            in: yesterday..<today
        )
        #expect(!rangeMessages.isEmpty)
    }

    @Test
    func testFetchMessagesByParticipant() async throws {
        let handle: Account.Handle = "+1234567890"

        // Test basic fetch
        let messages = try db.fetchMessages(with: [handle], limit: 10)
        #expect(messages.count == 2)
        #expect(messages[0].id.rawValue == "msg-guid-1")
        #expect(messages[0].text == "Hello!")
        #expect(messages[0].isFromMe == false)
        #expect(messages[0].sender?.rawValue == "+1234567890")

        // Test with date range
        let yesterday = Date().addingTimeInterval(-86400)
        let today = Date()
        let rangeMessages = try db.fetchMessages(
            with: [handle],
            in: yesterday..<today
        )
        #expect(!rangeMessages.isEmpty)
    }
}
