/// Represents an account used by Messages.
public struct Account: Identifiable, Hashable, Codable, Sendable {
    /// Represents a stable identifier for an account handle.
    public struct Handle: RawRepresentable, Hashable, Sendable {
        /// The raw handle value.
        public let rawValue: String

        /// Creates a handle from a raw string value.
        ///
        /// - Parameter rawValue: The raw handle value.
        public init(rawValue: String) {
            self.rawValue = rawValue
        }
    }

    /// The account identifier.
    public let id: Handle

    /// Defines supported messaging services.
    public enum Service: String, CaseIterable, Hashable, Codable, Sendable {
        /// Apple's iMessage service.
        case iMessage = "iMessage"
        /// Carrier-based SMS service.
        case sms = "SMS"
    }

    /// The service associated with this account.
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
