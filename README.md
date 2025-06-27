# Madrid

Madrid is a Swift package that provides read-only access to
your iMessage® `chat.db` database.

It comprises the following two modules:

- **iMessage**:
  Core functionality for querying an iMessage database.
- **TypedStream**:
  A Swift implementation for decoding Apple's `typedstream` format,
  adapted from [Christopher Sardegna's work](https://chrissardegna.com/blog/reverse-engineering-apples-typedstream-format/) on
  [imessage-exporter](https://github.com/ReagentX/imessage-exporter).

## Requirements

- Xcode 16+
- Swift 6.0+
- macOS 13.0+

## Installation

### Swift Package Manager

Add Madrid as a dependency to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/loopwork/Madrid.git", from: "0.1.2")
]
```

Then add the modules you need to your target's dependencies:

```swift
targets: [
    .target(
        name: "YourTarget",
        dependencies: [
            .product(name: "iMessage", package: "Madrid"),
            .product(name: "TypedStream", package: "Madrid")
        ]
    )
]
```

## Usage

### Fetching Messages

```swift
import iMessage

// Create a database (uses `~/Library/Messages/chat.db` by default)
let db = try iMessage.Database()

// Fetch recent messages
let recentMessages = try db.fetchMessages(limit: 10)

// Fetch messages from select individuals in time range
let pastWeek = Date.now.addingTimeInterval(-7*24*60*60)..<Date.now

let aliases = [
    "johnny.appleseed@mac.com",
    "+18002752273"
]
let handles = try db.fetchParticipant(matching: aliases)

for message in try db.fetchMessages(with: Set(handles), in: pastWeek) {
    print("From: \(message.sender)")
    print("Content: \(message.content)")
    print("Sent at: \(message.timestamp)")
}
```

### Decoding TypedStream Data

```swift
import TypedStream

let decoder = TypedStreamDecoder()
let data = // ... your typedstream data ...
let result = try decoder.decode(data)
print(result.stringValue)
```

## FAQ

### "Database Disk Image is Malformed"

If you get the error message
"database disk image is malformed"
when attempting to connect to your iMessage database,
it typically indicates corruption in the SQLite file.
The error most often occurs when attempting to read the database
while another process (like the Messages app) is actively using it.

To check if the database file is corrupt,
you can use SQLite's [built-in integrity check`](https://www.sqlite.org/pragma.html#pragma_integrity_check):

```sh
sqlite3 ~/Library/Messages/chat.db "PRAGMA integrity_check;
```

If the original database file is corrupt,
restore from a Time Machine backup or other backup source.

The most reliable way to prevent this error is to operate on a copy of the iMessage database:

1. **Quit Messages:**
   Ensure the Messages app is completely closed.

2. **Copy All Database Files:**
   ```sh
   # Create destination directory
   mkdir -p ~/imessage_db_copy
   # Copy main database and supporting files
   cp -p ~/Library/Messages/chat.db ~/imessage_db_copy/
   # Copy WAL and shared memory files if they exist
   cp -p ~/Library/Messages/chat.db-* ~/imessage_db_copy/ 2>/dev/null || true
   ```
   **Always include the `-shm` and `-wal` files when copying a SQLite database using WAL mode**

3. **Use the Copied Database:**
   ```swift
   let homeURL = FileManager.default.homeDirectoryForCurrentUser
   let dbURL = homeURL.appendingPathComponent("imessage_db_copy/chat.db")
   let db = try iMessage.Database(path: dbURL.path)
   ```

## Acknowledgments

- [Christopher Sardegna](https://chrissardegna.com)
  ([@ReagentX](https://github.com/ReagentX))
  for reverse-engineering the `typedstream` format.

## License

This project is licensed under the Apache License, Version 2.0.

## Legal

iMessage® is a registered trademark of Apple Inc.
This project is not affiliated with, endorsed, or sponsored by Apple Inc.
