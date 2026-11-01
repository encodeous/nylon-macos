import Foundation
import Testing
@testable import NylonApp

private func tempLog(_ text: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("nylon-\(UUID()).log")
    try Data(text.utf8).write(to: url)
    return url
}

private func append(_ text: String, to url: URL) throws {
    let file = try FileHandle(forWritingTo: url)
    try file.seekToEnd()
    try file.write(contentsOf: Data(text.utf8))
    try file.close()
}

// The first read starts at a whole line near the end; later reads follow from there, a whole line at a time.
@Test func followsALog() throws {
    let url = try tempLog("old line\nrecent one\nrecent two\npartial")
    let first = try readLog(url, from: nil, tail: 32)
    #expect(first.text == "recent one\nrecent two\n") // the tail began partway into "old line"; "partial" isn't finished
    try append(" line done\nnext\n", to: url)
    let second = try readLog(url, from: first.next)
    #expect(second == LogChunk(text: "partial line done\nnext\n", next: second.next, restarted: false))
    #expect(try readLog(url, from: second.next).text == "")
}

// Rotated or truncated: start again from the top.
@Test func noticesATruncatedLog() throws {
    let url = try tempLog("a long first life of the log\n")
    let first = try readLog(url, from: nil)
    try Data("new\n".utf8).write(to: url)
    #expect(try readLog(url, from: first.next) == LogChunk(text: "new\n", next: 4, restarted: true))
}

// A full chunk still ends at a whole line, and a huge line never ends partway into a character.
@Test func endsFullChunksCleanly() throws {
    let url = try tempLog("one\ntwo\nthr")
    #expect(try readLog(url, from: 0, limit: 10).text == "one\ntwo\n")
    let wide = try tempLog(String(repeating: "é", count: 10)) // 2 bytes each
    let chunk = try readLog(wide, from: 0, limit: 7)
    #expect(chunk.text == "ééé" && chunk.next == 6)
}

@Test func passesHugeLinesAndMissingLogs() throws {
    let url = try tempLog(String(repeating: "x", count: 100))
    #expect(try readLog(url, from: 0, limit: 10) == LogChunk(text: String(repeating: "x", count: 10), next: 10, restarted: false))
    #expect(try readLog(URL(fileURLWithPath: "/tmp/no-such-nylon.log"), from: nil) == LogChunk(text: "", next: 0, restarted: false))
}
