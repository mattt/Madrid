import Foundation

extension Data {
    init?(hexString: String) {
        let string = hexString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var data = Data(capacity: string.count / 2)

        var index = string.startIndex
        while index < string.endIndex {
            let nextIndex = string.index(index, offsetBy: 2)
            guard nextIndex <= string.endIndex,
                let byte = UInt8(string[index..<nextIndex], radix: 16)
            else {
                return nil
            }
            data.append(byte)
            index = nextIndex
        }

        self = data
    }
}
