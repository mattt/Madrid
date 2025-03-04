import Foundation

private let nsecPerSec: Int64 = 1_000_000_000

extension Date {
    init(nanosecondsSinceReferenceDate ns: Int64) {
        self.init(timeIntervalSinceReferenceDate: TimeInterval(Double(ns) / Double(nsecPerSec)))
    }

    var nanosecondsSinceReferenceDate: Int64? {
        let seconds = timeIntervalSinceReferenceDate
        let nanoseconds = seconds * Double(nsecPerSec)
        return Int64(exactly: nanoseconds)
    }
}
