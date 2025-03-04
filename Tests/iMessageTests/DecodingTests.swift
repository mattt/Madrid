import Foundation
import Testing

@testable import iMessage
@testable import TypedStream

@Suite
struct DecodingTests {
    @Test
    func testDecode() throws {
        let data = Data(hexString: Fixtures.attributedBody)!
        #expect(data.count == 232)

        let hexString = Array(data.prefix(16)).map { String(format: "%02X", $0) }.joined()
        #expect(hexString == "040B73747265616D747970656481E803")

        let decoded = try TypedStreamDecoder.decode(data)

        #expect(decoded.count == 6)

        // First element: NSString with "Hello"
        if case let .object(classInfo, data) = decoded[0] {
            #expect(classInfo.name == "NSString")
            #expect(classInfo.version == 1)
            #expect(data.count == 1)
            if case let .string(text) = data[0] {
                #expect(text == "Hello")
            }
        }

        // Second element: Data with [1, 9]
        if case let .data(data) = decoded[1] {
            #expect(data.count == 2)
            if case let .signedInteger(i1) = data[0] {
                #expect(i1 == 1)
            }
            if case let .unsignedInteger(i2) = data[1] {
                #expect(i2 == 9)
            }
        }

        // Third element: NSDictionary
        if case let .object(classInfo, data) = decoded[2] {
            #expect(classInfo.name == "NSDictionary")
            #expect(classInfo.version == 0)
            #expect(data.count == 1)
            if case let .signedInteger(i) = data[0] {
                #expect(i == 1)
            }
        }

        // Fourth element: NSNumber with -1
        if case let .object(classInfo, data) = decoded[3] {
            #expect(classInfo.name == "NSNumber")
            #expect(classInfo.version == 0)
            #expect(data.count == 1)
            if case let .signedInteger(i) = data[0] {
                #expect(i == -1)
            }
        }

        // Fifth element: NSString with "__kIMMessagePartAttributeName"
        if case let .object(classInfo, data) = decoded[4] {
            #expect(classInfo.name == "NSString")
            #expect(classInfo.version == 1)
            #expect(data.count == 1)
            if case let .string(text) = data[0] {
                #expect(text == "__kIMMessagePartAttributeName")
            }
        }

        // Sixth element: NSNumber with 0
        if case let .object(classInfo, data) = decoded[5] {
            #expect(classInfo.name == "NSNumber")
            #expect(classInfo.version == 0)
            #expect(data.count == 1)
            if case let .signedInteger(i) = data[0] {
                #expect(i == 0)
            }
        }
    }

    @Test
    func testExtractText() throws {
        let data = Data(hexString: Fixtures.attributedBody)!

        let decoded = try TypedStreamDecoder.decode(data)
        let text = decoded.compactMap { $0.stringValue }.filter { !$0.isEmpty }
        #expect(text.count == 1)
        #expect(text.contains("Hello"))
        #expect(!text.contains("NSString"))
        #expect(!text.contains("NSAttributedString"))
    }
}
