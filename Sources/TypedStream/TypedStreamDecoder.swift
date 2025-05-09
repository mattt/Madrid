import Foundation

/**
 Contains logic and data used to deserialize data from a `typedstream`.

 `typedstream` is a binary serialization format developed by NeXT and later adopted by Apple.
 It's designed to serialize and deserialize complex object graphs and data structures in C and Objective-C.

 A `typedstream` begins with a header that includes format version and architecture information,
 followed by a stream of typed data elements. Each element is prefixed with type information,
 allowing the `TypedStreamDecoder` to understand the original data structures.
 */
public final class TypedStreamDecoder {
    /// Errors that can happen when parsing `typedstream` data.
    /// This corresponds to the new `typedstream` deserializer.
    enum Error: Swift.Error, CustomStringConvertible {
        case outOfBounds(index: Int, length: Int)
        case invalidHeader
        case sliceError(Swift.Error)
        case stringParseError(Swift.Error)
        case invalidArray
        case invalidPointer(UInt8)

        var description: String {
            switch self {
            case .outOfBounds(let index, let length):
                return String(format: "Index %x is outside of range %x!", index, length)
            case .invalidHeader:
                return "Invalid typedstream header!"
            case .sliceError(let error):
                return "Unable to slice source stream: \(error)"
            case .stringParseError(let error):
                return "Failed to parse string: \(error)"
            case .invalidArray:
                return "Failed to parse array data"
            case .invalidPointer(let value):
                return String(format: "Failed to parse pointer: %x", value)
            }
        }
    }
    
    /// Represents data that results from attempting to parse a class from the `typedstream`
    private enum ClassResult {
        /// A reference to an already-seen class in the `TypedStreamReader`'s object table
        case index(Int)
        /// A new class hierarchy to be inserted into the `TypedStreamReader`'s object table
        case classHierarchy([Archivable])
    }
    
    // MARK: - Constants

    /// Indicates an `Int16` in the byte stream
    private let I_16: UInt8 = 0x81
    /// Indicates an `Int32` in the byte stream
    private let I_32: UInt8 = 0x82
    /// Indicates a `Float` or `Double` in the byte stream; the `Type` determines the size
    private let DECIMAL: UInt8 = 0x83
    /// Indicates the start of a new object
    private let START: UInt8 = 0x84
    /// Indicates that there is no more data to parse, for example the end of a class inheritance chain
    private let EMPTY: UInt8 = 0x85
    /// Indicates the last byte of an object
    private let END: UInt8 = 0x86
    /// Bytes equal or greater in value than the reference tag indicate an index in the table of already-seen types
    private let REFERENCE_TAG: UInt64 = 0x92

    // MARK: - Properties

    /// The `typedstream` we want to parse
    let stream: [UInt8]
    /// The current index we are at in the stream
    var idx: Int
    /// As we parse the `typedstream`, build a table of seen `Type`s to reference in the future
    ///
    /// The first time a `Type` is seen, it is present in the stream literally,
    /// but afterwards are only referenced by index in order of appearance.
    var typesTable: [[Type]]
    /// As we parse the `typedstream`, build a table of seen archivable data to reference in the future
    var objectTable: [Archivable]
    /// We want to copy embedded types the first time they are seen, even if the types were resolved through references
    var seenEmbeddedTypes: Set<UInt32>
    /// Stores the position of the current `Archivable.placeholder`
    var placeholder: Int?
    
    // MARK: - Static Methods
    
    /// Decode typedstream data into an array of Archivable objects
    /// - Parameter data: The data to decode
    /// - Returns: An array of decoded Archivable objects
    /// - Throws: TypedStreamError if decoding fails
    public static func decode(_ data: Data) throws -> [Archivable] {
        let bytes = [UInt8](data)
        let decoder = TypedStreamDecoder(stream: bytes)
        return try decoder.parse()
    }

    // MARK: - Initialization

    /// Initialize the decoder with a stream of bytes
    init(stream: [UInt8]) {
        self.stream = stream
        self.idx = 0
        self.typesTable = []
        self.objectTable = []
        self.seenEmbeddedTypes = Set()
        self.placeholder = nil
    }

    // MARK: - Methods
    
    /// Attempt to get the data from the `typedstream`.
    ///
    /// Given a stream, construct a decoder object to parse it. `typedstream` data doesn't include property
    /// names, so data is stored on `object`s in order of appearance.
    ///
    /// Yields a new `Archivable` as they occur in the stream, but does not retain the object's inheritance hierarchy.
    /// Callers are responsible for assembling the deserialized stream into a useful data structure.
    ///
    /// - Returns: An array of `Archivable` objects parsed from the stream.
    func parse() throws -> [Archivable] {
        var output: [Archivable] = []

        try validateHeader()

        while idx < stream.count {
            if try getCurrentByte() == END {
                idx += 1
                continue
            }
            // First, get the current type
            if let foundTypes = try getType(embedded: false) {
                if let result = try readTypes(foundTypes: foundTypes) {
                    output.append(result)
                }
            }
        }

        return output
    }
    
    /// Validate the `typedstream` header to ensure correct format
    private func validateHeader() throws {
        // Encoding type
        let typedstreamVersion = try readUnsignedInt()
        // Encoding signature
        let signature = try readString()
        // System version
        let systemVersion = try readSignedInt()

        if typedstreamVersion != 4 || signature != "streamtyped" || systemVersion != 1000 {
            throw Error.invalidHeader
        }
    }

    /// Read a signed integer from the stream.
    /// Because we don't know the size of the integer ahead of time, we store it in the largest possible value.
    private func readSignedInt() throws -> Int64 {
        switch try getCurrentByte() {
        case I_16:
            idx += 1
            let size = 2
            let bytes = try readExactBytes(size: size)
            let value = Int16(littleEndian: bytes.withUnsafeBytes { $0.load(as: Int16.self) })
            return Int64(value)
        case I_32:
            idx += 1
            let size = 4
            let bytes = try readExactBytes(size: size)
            let value = Int32(littleEndian: bytes.withUnsafeBytes { $0.load(as: Int32.self) })
            return Int64(value)
        default:
            let currentByte = try getCurrentByte()
            if currentByte > UInt8(REFERENCE_TAG) {
                let nextByte = try getNextByte()
                if nextByte != END {
                    idx += 1
                    return try readSignedInt()
                }
            }
            let value = Int8(bitPattern: currentByte)
            idx += 1
            return Int64(value)
        }
    }

    /// Read an unsigned integer from the stream.
    /// Because we don't know the size of the integer ahead of time, we store it in the largest possible value.
    private func readUnsignedInt() throws -> UInt64 {
        switch try getCurrentByte() {
        case I_16:
            idx += 1
            let size = 2
            let bytes = try readExactBytes(size: size)
            let value = UInt16(littleEndian: bytes.withUnsafeBytes { $0.load(as: UInt16.self) })
            return UInt64(value)
        case I_32:
            idx += 1
            let size = 4
            let bytes = try readExactBytes(size: size)
            let value = UInt32(littleEndian: bytes.withUnsafeBytes { $0.load(as: UInt32.self) })
            return UInt64(value)
        default:
            let value = try getCurrentByte()
            idx += 1
            return UInt64(value)
        }
    }

    /// Read a single-precision float from the byte stream
    private func readFloat() throws -> Float {
        switch try getCurrentByte() {
        case DECIMAL:
            idx += 1
            let size = 4
            let bytes = try readExactBytes(size: size)
            let value = Float(bitPattern: bytes.withUnsafeBytes { $0.load(as: UInt32.self) })
            return value
        case I_16, I_32:
            let intValue = try readSignedInt()
            return Float(intValue)
        default:
            idx += 1
            let intValue = try readSignedInt()
            return Float(intValue)
        }
    }

    /// Read a double-precision float from the byte stream
    private func readDouble() throws -> Double {
        switch try getCurrentByte() {
        case DECIMAL:
            idx += 1
            let size = 8
            let bytes = try readExactBytes(size: size)
            let value = Double(bitPattern: bytes.withUnsafeBytes { $0.load(as: UInt64.self) })
            return value
        case I_16, I_32:
            let intValue = try readSignedInt()
            return Double(intValue)
        default:
            idx += 1
            let intValue = try readSignedInt()
            return Double(intValue)
        }
    }

    /// Read exactly `size` bytes from the stream
    private func readExactBytes(size: Int) throws -> Data {
        guard idx + size <= stream.count else {
            throw Error.outOfBounds(index: idx + size, length: stream.count)
        }
        let data = Data(stream[idx..<(idx + size)])
        idx += size
        return data
    }

    /// Read `size` bytes as a String
    private func readExactAsString(length: Int) throws -> String {
        let bytes = try readExactBytes(size: length)
        guard let string = String(data: bytes, encoding: .utf8) else {
            throw Error.stringParseError(NSError(domain: "Invalid UTF-8", code: 0))
        }
        return string
    }

    /// Get the byte at a given index, if the index is within the bounds of the `typedstream`
    private func getByte(at index: Int) throws -> UInt8 {
        guard index < stream.count else {
            throw Error.outOfBounds(index: index, length: stream.count)
        }
        return stream[index]
    }

    /// Read the current byte
    private func getCurrentByte() throws -> UInt8 {
        return try getByte(at: idx)
    }

    /// Read the next byte
    private func getNextByte() throws -> UInt8 {
        return try getByte(at: idx + 1)
    }

    /// Read some bytes as an array
    private func readArray(size: Int) throws -> [UInt8] {
        let data = try readExactBytes(size: size)
        return [UInt8](data)
    }

    /// Determine the current types
    private func readType() throws -> [Type] {
        let length = try readUnsignedInt()
        let typesData = try readExactBytes(size: Int(length))
        let typesBytes = [UInt8](typesData)

        // Handle array size
        if typesBytes.first == 0x5B {  // '[' character
            if let (arrayTypes, _) = Type.getArrayLength(types: typesBytes) {
                return arrayTypes
            } else {
                throw Error.invalidArray
            }
        }

        return typesBytes.map { Type.fromByte($0) }
    }

    /// Read a reference pointer for a Type
    private func readPointer() throws -> UInt32 {
        let pointer = try getCurrentByte()
        idx += 1
        guard let result = UInt32(exactly: pointer &- UInt8(REFERENCE_TAG)) else {
            throw Error.invalidPointer(pointer)
        }
        return result
    }

    /// Read a class
    private func readClass() throws -> ClassResult {
        var output: [Archivable] = []
        switch try getCurrentByte() {
        case START:
            // Skip some header bytes
            while try getCurrentByte() == START {
                idx += 1
            }
            let length = try readUnsignedInt()

            if length >= REFERENCE_TAG {
                let index = length - REFERENCE_TAG
                return .index(Int(index))
            }

            let className = try readExactAsString(length: Int(length))
            let version = try readUnsignedInt()

            typesTable.append([.newString(className)])
            output.append(.class(Class(name: className, version: version)))

            let parentClassResult = try readClass()
            if case .classHierarchy(let parent) = parentClassResult {
                output.append(contentsOf: parent)
            }
        case EMPTY:
            idx += 1
        default:
            let index = try readPointer()
            return .index(Int(index))
        }
        return .classHierarchy(output)
    }

    /// Read an object into the cache and emit, or emit an already-cached object
    private func readObject() throws -> Archivable? {
        switch try getCurrentByte() {
        case START:
            let classResult = try readClass()
            switch classResult {
            case .index(let idx):
                return objectTable[safe: idx]
            case .classHierarchy(let classes):
                objectTable.append(contentsOf: classes)
            }
            return nil
        case EMPTY:
            idx += 1
            return nil
        default:
            let index = try readPointer()
            return objectTable[safe: Int(index)]
        }
    }

    /// Read String data
    private func readString() throws -> String {
        let length = try readUnsignedInt()
        let string = try readExactAsString(length: Int(length))
        return string
    }

    /// `Archivable` data can be embedded on a class or in a C String marked as `Type.embeddedData`
    private func readEmbeddedData() throws -> Archivable? {
        // Skip the 0x84
        idx += 1
        if let types = try getType(embedded: true) {
            return try readTypes(foundTypes: types)
        }
        return nil
    }

    /// Gets the current type from the stream, either by reading it from the stream or reading it from
    /// the specified index of `typesTable`.
    private func getType(embedded: Bool) throws -> [Type]? {
        switch try getCurrentByte() {
        case START:
            // Ignore repeated types, for example in a dict
            idx += 1
            let objectTypes = try readType()
            // Embedded data is stored as a C String in the objects table
            if embedded {
                objectTable.append(.type(objectTypes))
                seenEmbeddedTypes.insert(UInt32(typesTable.count))
            }
            typesTable.append(objectTypes)
            return typesTable.last
        case END:
            // This indicates the end of the current object
            return nil
        default:
            // Ignore repeated types, for example in a dict
            while try getCurrentByte() == getNextByte() {
                idx += 1
            }
            let refTag = try readPointer()
            let result = typesTable[safe: Int(refTag)]
            if embedded, let res = result {
                // We only want to include the first embedded reference tag, not subsequent references to the same embed
                if !seenEmbeddedTypes.contains(refTag) {
                    objectTable.append(.type(res))
                    seenEmbeddedTypes.insert(refTag)
                }
            }
            return result
        }
    }

    /// Given some `Type`s, look at the stream and parse the data according to the specified `Type`
    private func readTypes(foundTypes: [Type]) throws -> Archivable? {
        var output: [Object] = []
        var isObject = false

        for foundType in foundTypes {
            switch foundType {
            case .utf8String:
                let string = try readString()
                output.append(.string(string))
            case .embeddedData:
                if let embeddedData = try readEmbeddedData() {
                    return embeddedData
                }
            case .object:
                isObject = true
                let length = objectTable.count
                placeholder = length
                objectTable.append(.placeholder)
                if let object = try readObject() {
                    switch object {
                    case .object(_, let data):
                        // If this is a new object, i.e. one without any data, we add the data into it later
                        // If the object already has data in it, we just want to return that object
                        if !data.isEmpty {
                            placeholder = nil
                            objectTable.removeLast()
                            return object
                        }
                        output.append(contentsOf: data)
                    case .class(let cls):
                        output.append(.class(cls))
                    case .data(let data):
                        output.append(contentsOf: data)
                    default:
                        break
                    }
                }
            case .signedInt:
                let value = try readSignedInt()
                output.append(.signedInteger(value))
            case .unsignedInt:
                let value = try readUnsignedInt()
                output.append(.unsignedInteger(value))
            case .float:
                let value = try readFloat()
                output.append(.float(value))
            case .double:
                let value = try readDouble()
                output.append(.double(value))
            case .unknown(let byte):
                output.append(.byte(byte))
            case .string(let s):
                output.append(.string(s))
            case .array(let size):
                let array = try readArray(size: size)
                output.append(.array(array))
            }
        }

        // If we had reserved a place for an object, fill that spot
        if let spot = placeholder {
            if !output.isEmpty {
                // We got a class, but do not have its respective data yet
                if let last = output.last, case .class(let cls) = last {
                    objectTable[spot] = .object(cls, [])
                }
                // The spot after the current placeholder contains the class at the top of the class hierarchy
                else if let next = objectTable[safe: spot + 1], case .class(let cls) = next {
                    objectTable[spot] = .object(cls, output)
                    placeholder = nil
                    return objectTable[spot]
                }
                // We got some data for a class that was already seen
                else if case .object(let cls, var data) = objectTable[spot] {
                    data.append(contentsOf: output)
                    objectTable[spot] = .object(cls, data)
                    placeholder = nil
                    return objectTable[spot]
                }
                // We got some data that is not part of a class
                else {
                    objectTable[spot] = .data(output)
                    placeholder = nil
                    return objectTable[spot]
                }
            }
        }

        if !output.isEmpty && !isObject {
            return .data(output)
        }

        return nil
    }
}

// MARK: -

fileprivate extension Array {
    /// Safely access an array element to prevent index out of range errors
    subscript(safe index: Int) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}
