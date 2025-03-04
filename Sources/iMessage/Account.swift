public struct Account: Identifiable, Hashable, Codable, Sendable {
    public struct Handle: RawRepresentable, Hashable, Sendable {
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }
    }

    public let id: Handle

    public enum Service: String, CaseIterable, Hashable, Codable, Sendable {
        case iMessage = "iMessage"
        case sms = "SMS"
    }

    public let service: Service?
}

// MARK: - RawRepresentable

extension Account.Service: RawRepresentable {
    public init(rawValue: String) {
        switch rawValue.lowercased() {
        case "imessage": self = .iMessage
        default: self = .sms
        }
    }
}

// MARK: - Codable

extension Account.Handle: Codable {
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

extension Account.Handle: CustomStringConvertible {
    public var description: String {
        return rawValue
    }
}

// MARK: - ExpressibleByStringLiteral

extension Account.Handle: ExpressibleByStringLiteral {
    public init(stringLiteral value: StringLiteralType) {
        self.init(rawValue: value)
    }
}
