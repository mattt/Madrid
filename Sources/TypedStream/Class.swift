/// Represents a class stored in the `typedstream`
public struct Class: Hashable, Sendable {
    /// The name of the class
    public let name: String
    /// The encoded version of the class
    public let version: UInt64

    public init(name: String, version: UInt64) {
        self.name = name
        self.version = version
    }
}
