import Foundation

// Part of a network's log. Ask again from next to follow it.
struct LogChunk: Codable, Equatable {
    var text: String
    var next: UInt64
    var restarted: Bool // the log was rotated or truncated, so text starts from its beginning, not from where asked
}

// Whole lines of the log at url from offset from, or from about tail bytes before its end; at most limit bytes.
func readLog(_ url: URL, from: UInt64?, tail: UInt64 = 64 << 10, limit: Int = 1 << 20) throws -> LogChunk {
    guard let file = try? FileHandle(forReadingFrom: url) else { return LogChunk(text: "", next: 0, restarted: false) }
    defer { try? file.close() }
    let size = try file.seekToEnd()
    let restarted = from.map { $0 > size } ?? false
    var start = restarted ? 0 : from ?? size - min(size, tail)
    try file.seek(toOffset: start)
    var data = try file.read(upToCount: limit) ?? Data()
    if from == nil, start > 0, let newline = data.firstIndex(of: 10) { // begin at a line, not partway into one
        start += UInt64(data.distance(from: data.startIndex, to: newline) + 1)
        data = data[(newline + 1)...]
    }
    // End at the last whole line; the rest comes next time, once nylon has finished writing it. A full chunk with no
    // newline at all is one huge line, so it goes as it is, ending at a whole UTF-8 character.
    if let newline = data.lastIndex(of: 10) {
        data = data[...newline]
    } else if data.count < limit {
        data = Data()
    } else {
        // cut a last character that's split: find where it starts (continuation bytes are 10xxxxxx), and how long
        // its first byte says it is
        if let lead = data.indices.suffix(4).last(where: { data[$0] & 0xC0 != 0x80 }) {
            let length = data[lead] >= 0xF0 ? 4 : data[lead] >= 0xE0 ? 3 : data[lead] >= 0xC0 ? 2 : 1
            if data.distance(from: lead, to: data.endIndex) < length { data = data[..<lead] }
        }
    }
    return LogChunk(text: String(decoding: data, as: UTF8.self), next: start + UInt64(data.count), restarted: restarted)
}
