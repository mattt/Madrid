public struct GUID: RawRepresentable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

// MARK: - Comparable

extension GUID: Comparable {
    public static func < (lhs: GUID, rhs: GUID) -> Bool {
        return lhs.rawValue < rhs.rawValue
    }
}

// MARK: - Codable

extension GUID: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - CustomStringConvertible

extension GUID: ExpressibleByStringLiteral {
    public init(stringLiteral value: StringLiteralType) {
        self.init(rawValue: value)
    }
}

// MARK: - CustomStringConvertible

extension GUID: CustomStringConvertible {
    public var description: String {
        return rawValue
    }
}
