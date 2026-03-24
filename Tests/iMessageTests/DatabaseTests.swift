import Foundation
import SQLite3
import Testing

@testable import TypedStream
@testable import iMessage

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
        let filtered = try db.fetchChats(in: yesterday ..< now)
        #expect(filtered.count == 1)
        #expect(filtered.first?.id.rawValue == "chat-guid-1")

        // Test with older date range - should get the second chat
        let threeDaysAgo = now.addingTimeInterval(-86400 * 3)
        let twoDaysAgo = now.addingTimeInterval(-86400 * 2)
        let oldFiltered = try db.fetchChats(in: threeDaysAgo ..< twoDaysAgo)
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
        #expect(chatMessages[0].readAt == nil)
        #expect(chatMessages[0].isRead == false)

        #expect(chatMessages[1].id.rawValue == "msg-guid-2")
        #expect(chatMessages[1].text == "Hi there")
        #expect(chatMessages[1].readAt != nil)
        #expect(chatMessages[1].isRead == true)

        #expect(chatMessages[2].id.rawValue == "msg-guid-3")
        #expect(chatMessages[2].text == "Hello")
        #expect(chatMessages[2].readAt != nil)
        #expect(chatMessages[2].isRead == true)

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
            in: yesterday ..< today
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
        #expect(messages[0].isRead == false)
        #expect(messages[0].readAt == nil)
        #expect(messages[0].sender?.rawValue == "+1234567890")

        // Test with date range
        let yesterday = Date().addingTimeInterval(-86400)
        let today = Date()
        let rangeMessages = try db.fetchMessages(
            with: [handle],
            in: yesterday ..< today
        )
        #expect(!rangeMessages.isEmpty)
    }

    @Test
    func testFetchWithDefaultPredicates() async throws {
        let chats = try db.fetch(Database.ChatFetchRequest())
        #expect(chats.count == 2)

        let messages = try db.fetch(Database.MessageFetchRequest())
        #expect(messages.count == 5)
    }

    @Test
    func testMessageFetchRequestSortAndPagination() async throws {
        let request = Database.MessageFetchRequest(
            predicate: .all,
            sortDescriptors: [
                .date(.ascending),
                .id(.ascending),
            ],
            limit: 2,
            offset: 1
        )

        let messages = try db.fetch(request)
        #expect(messages.count == 2)
        #expect(messages[0].id.rawValue == "msg-guid-5")
        #expect(messages[1].id.rawValue == "msg-guid-1")
    }

    @Test
    func testMessagePredicateComposition() async throws {
        let request = Database.MessageFetchRequest(
            predicate: .or([
                .chatID("chat-guid-2"),
                .participantHandles(["person@example.com"]),
            ]),
            limit: 10
        )

        let messages = try db.fetch(request)
        let messageIDs = Set(messages.map(\.id.rawValue))
        #expect(messageIDs == ["msg-guid-3", "msg-guid-4", "msg-guid-5"])
    }

    @Test
    func testChatParticipantMatchModes() async throws {
        let anyMatchRequest = Database.ChatFetchRequest(
            predicate: .participantHandles(["+1234567890", "third@example.com"], match: .any),
            limit: 10
        )
        let anyMatch = try db.fetch(anyMatchRequest)
        #expect(Set(anyMatch.map(\.id.rawValue)) == ["chat-guid-1", "chat-guid-2"])

        let allMatchRequest = Database.ChatFetchRequest(
            predicate: .participantHandles(["+1234567890", "third@example.com"], match: .all),
            limit: 10
        )
        let allMatch = try db.fetch(allMatchRequest)
        #expect(allMatch.count == 1)
        #expect(allMatch[0].id.rawValue == "chat-guid-2")
    }

    @Test
    func testPredicateEmptyCompoundSemantics() async throws {
        let allMessages = try db.fetch(
            Database.MessageFetchRequest(predicate: .and([]), limit: 10)
        )
        #expect(allMessages.count == 5)

        let noMessages = try db.fetch(
            Database.MessageFetchRequest(predicate: .or([]), limit: 10)
        )
        #expect(noMessages.isEmpty)

        let orWithAllMessages = try db.fetch(
            Database.MessageFetchRequest(
                predicate: .or([
                    .all,
                    .chatID("chat-guid-1"),
                ]),
                limit: 10
            )
        )
        #expect(orWithAllMessages.count == 5)

        let orWithAllChats = try db.fetch(
            Database.ChatFetchRequest(
                predicate: .or([
                    .all,
                    .participantHandles(["nonexistent@example.com"], match: .all),
                ]),
                limit: 10
            )
        )
        #expect(orWithAllChats.count == 2)

        let nestedOrWithAllMessages = try db.fetch(
            Database.MessageFetchRequest(
                predicate: .or([
                    .and([]),
                    .chatID("chat-guid-1"),
                ]),
                limit: 10
            )
        )
        #expect(nestedOrWithAllMessages.count == 5)

        let nestedOrWithAllChats = try db.fetch(
            Database.ChatFetchRequest(
                predicate: .or([
                    .and([.all]),
                    .none,
                ]),
                limit: 10
            )
        )
        #expect(nestedOrWithAllChats.count == 2)
    }

    @Test
    func testOrWithMatchAllDoesNotDuplicateMessagesFromChatJoinRows() async throws {
        // Create a duplicate chat join row for one message.
        try db.execute(
            """
                INSERT INTO chat_message_join (chat_id, message_id)
                VALUES (2, 1);
            """
        )

        let allMessages = try db.fetch(
            Database.MessageFetchRequest(
                predicate: .all,
                sortDescriptors: [.id(.ascending)],
                limit: 20
            )
        )
        #expect(allMessages.count == 5)

        let orWithAll = try db.fetch(
            Database.MessageFetchRequest(
                predicate: .or([
                    .all,
                    .chatID("chat-guid-1"),
                ]),
                sortDescriptors: [.id(.ascending)],
                limit: 20
            )
        )

        #expect(orWithAll.count == 5)
        #expect(Set(orWithAll.map(\.id)) == Set(allMessages.map(\.id)))
    }

    @Test
    func testLegacyWrappersMatchTypedRequests() async throws {
        let legacyMessages = try db.fetchMessages(
            for: "chat-guid-1",
            with: ["+1234567890", "person@example.com"],
            limit: 10
        )
        let requestMessages = try db.fetch(
            Database.MessageFetchRequest(
                predicate: .and([
                    .chatID("chat-guid-1"),
                    .participantHandles(["+1234567890", "person@example.com"]),
                ]),
                limit: 10
            )
        )
        #expect(legacyMessages.map(\.id) == requestMessages.map(\.id))

        let legacyChats = try db.fetchChats(
            with: ["+1234567890", "person@example.com"],
            limit: 10
        )
        let requestChats = try db.fetch(
            Database.ChatFetchRequest(
                predicate: .participantHandles(["+1234567890", "person@example.com"], match: .all),
                limit: 10
            )
        )
        #expect(legacyChats.map(\.id) == requestChats.map(\.id))
    }

    @Test
    func testInvalidPaginationThrows() async throws {
        do {
            _ = try db.fetch(
                Database.MessageFetchRequest(limit: -1)
            )
            Issue.record("Expected negative limit to throw")
        } catch Database.Error.queryError {
            // Expected.
        }
    }
}
