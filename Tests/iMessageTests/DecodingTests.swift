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

    @Test
    func testTypeGetArrayLength() {
        #expect(Type.getArrayLength(types: []) == nil)
        #expect(Type.getArrayLength(types: [0x40]) == nil)

        let result1 = Type.getArrayLength(types: [0x5B, 0x31])
        #expect(result1?.0 == [.array(1)])
        #expect(result1?.1 == 2)

        let result10 = Type.getArrayLength(types: [0x5B, 0x31, 0x30])
        #expect(result10?.0 == [.array(10)])
        #expect(result10?.1 == 3)

        let result123 = Type.getArrayLength(types: [0x5B, 0x31, 0x32, 0x33])
        #expect(result123?.0 == [.array(123)])
        #expect(result123?.1 == 4)

        #expect(Type.getArrayLength(types: [0x5B, 0x5D]) == nil)
        #expect(Type.getArrayLength(types: [0x5B, 0x61]) == nil)
    }

    @Test
    func testArchivableIntegerValue() throws {
        let data = Data(hexString: Fixtures.attributedBody)!
        let decoded = try TypedStreamDecoder.decode(data)

        let nsNumberMinusOne = decoded[3]
        #expect(nsNumberMinusOne.integerValue == -1)

        let nsNumberZero = decoded[5]
        #expect(nsNumberZero.integerValue == 0)

        let nsString = decoded[0]
        #expect(nsString.integerValue == nil)
    }

    @Test
    func testArchivableDoubleValue() {
        let nsNumber = Archivable.object(
            Class(name: "NSNumber", version: 0),
            [.double(100.001)]
        )
        #expect(nsNumber.doubleValue == 100.001)

        let nsString = Archivable.object(
            Class(name: "NSString", version: 1),
            [.string("Hello")]
        )
        #expect(nsString.doubleValue == nil)

        let nsNumberWithInt = Archivable.object(
            Class(name: "NSNumber", version: 0),
            [.signedInteger(42)]
        )
        #expect(nsNumberWithInt.doubleValue == nil)
    }

    @Test
    func testDataHexStringInvalidReturnsNil() {
        #expect(Data(hexString: "0g") == nil)
        #expect(Data(hexString: "GG") == nil)
        #expect(Data(hexString: "") != nil)
    }

    @Test
    func testTypedStreamDecoderErrorDescriptions() {
        struct TestError: Error, CustomStringConvertible { var description: String { "test error" } }
        let testError = TestError()

        #expect(TypedStreamDecoderError.outOfBounds(index: 0xA, length: 5).errorDescription == "Index a is outside of range 5!")
        #expect(TypedStreamDecoderError.invalidHeader.errorDescription == "Invalid typedstream header!")
        #expect(TypedStreamDecoderError.sliceError(testError).errorDescription == "Unable to slice source stream: test error")
        #expect(TypedStreamDecoderError.stringParseError(testError).errorDescription == "Failed to parse string: test error")
        #expect(TypedStreamDecoderError.invalidArray.errorDescription == "Failed to parse array data")
        #expect(TypedStreamDecoderError.invalidPointer(0xFF).errorDescription == "Failed to parse pointer: ff")
    }
}
