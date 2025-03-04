/// Structures containing data stored in the `typedstream`
public enum Object: Hashable, Sendable {
    /// Text data, denoted in the stream by `Type.utf8String`
    case string(String)
    /// Signed integer types, denoted in the stream by `Type.signedInt`
    case signedInteger(Int64)
    /// Unsigned integer types, denoted in the stream by `Type.unsignedInt`
    case unsignedInteger(UInt64)
    /// Floating point numbers, denoted in the stream by `Type.float`
    case float(Float)
    /// Double precision floats, denoted in the stream by `Type.double`
    case double(Double)
    /// Bytes whose type is not known, denoted in the stream by `Type.unknown`
    case byte(UInt8)
    /// Collection of bytes in an array, denoted in the stream by `Type.array`
    case array([UInt8])
    /// A found class, used by `Archivable.classCase`
    case `class`(Class)
}
