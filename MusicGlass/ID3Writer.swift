import Foundation

enum ID3Writer {
    struct Fields {
        var title: String?
        var artist: String?
        var album: String?
        var year: String?
        var genre: String?
        var cover: Data?
    }

    enum WriteError: LocalizedError {
        case unsupported
        var errorDescription: String? {
            "Запись тегов пока поддерживается только для MP3-файлов."
        }
    }

    static func write(_ fields: Fields, to url: URL) throws {
        guard url.pathExtension.lowercased() == "mp3" else { throw WriteError.unsupported }
        let data = try Data(contentsOf: url)

        let title = clean(fields.title)
        let artist = clean(fields.artist)
        let album = clean(fields.album)
        let year = String((clean(fields.year) ?? "").prefix(4))
        let genre = clean(fields.genre)

        var overridden = Set<String>()
        if title != nil { overridden.insert("TIT2") }
        if artist != nil { overridden.insert("TPE1") }
        if album != nil { overridden.insert("TALB") }
        if !year.isEmpty { overridden.insert("TYER"); overridden.insert("TDRC") }
        if genre != nil { overridden.insert("TCON") }
        if fields.cover != nil { overridden.insert("APIC") }

        var audioStart = 0
        var preserved = Data()
        var preservedYear: String?

        if data.count >= 10, data[0] == 0x49, data[1] == 0x44, data[2] == 0x33 {
            let version = Int(data[3])
            let flags = data[5]
            let size = syncsafe(data, 6)
            let footer = (version == 4 && (flags & 0x10) != 0) ? 10 : 0
            let tagEnd = min(10 + size, data.count)
            audioStart = min(10 + size + footer, data.count)

            if (version == 3 || version == 4) && (flags & 0x80) == 0 {
                var pos = 10
                if (flags & 0x40) != 0, pos + 4 <= tagEnd {
                    pos += version == 4 ? syncsafe(data, pos) : be32(data, pos) + 4
                }
                while pos + 10 <= tagEnd {
                    if data[pos] == 0 { break }
                    guard let id = String(data: data.subdata(in: pos..<(pos + 4)), encoding: .isoLatin1) else { break }
                    let fsize = version == 4 ? syncsafe(data, pos + 4) : be32(data, pos + 4)
                    let flag1 = data[pos + 8]
                    let flag2 = data[pos + 9]
                    let bodyStart = pos + 10
                    let bodyEnd = bodyStart + fsize
                    if fsize < 0 || bodyEnd > tagEnd { break }
                    pos = bodyEnd
                    guard flag1 == 0, flag2 == 0, fsize > 0 else { continue }
                    let body = data.subdata(in: bodyStart..<bodyEnd)
                    if id == "TDRC" {
                        if year.isEmpty, preservedYear == nil {
                            preservedYear = String((decodeText(body) ?? "").prefix(4))
                        }
                        continue
                    }
                    if overridden.contains(id) || !isKeepable(id: id, body: body) { continue }
                    preserved.append(frame(id, body))
                }
            }
        }

        var frames = Data()
        if let title { frames.append(textFrame("TIT2", title)) }
        if let artist { frames.append(textFrame("TPE1", artist)) }
        if let album { frames.append(textFrame("TALB", album)) }
        if !year.isEmpty {
            frames.append(textFrame("TYER", year))
        } else if let py = preservedYear, !py.isEmpty {
            frames.append(textFrame("TYER", py))
        }
        if let genre { frames.append(textFrame("TCON", genre)) }
        frames.append(preserved)
        if let cover = fields.cover { frames.append(apicFrame(cover)) }

        let padding = 512
        var out = Data([0x49, 0x44, 0x33, 0x03, 0x00, 0x00])
        out.append(contentsOf: syncsafeBytes(frames.count + padding))
        out.append(frames)
        out.append(Data(count: padding))
        out.append(data.subdata(in: audioStart..<data.count))
        try out.write(to: url, options: .atomic)
    }

    // MARK: Помощники

    private static func clean(_ s: String?) -> String? {
        guard let s else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private static func be32(_ d: Data, _ o: Int) -> Int {
        (Int(d[o]) << 24) | (Int(d[o + 1]) << 16) | (Int(d[o + 2]) << 8) | Int(d[o + 3])
    }

    private static func syncsafe(_ d: Data, _ o: Int) -> Int {
        (Int(d[o] & 0x7F) << 21) | (Int(d[o + 1] & 0x7F) << 14) | (Int(d[o + 2] & 0x7F) << 7) | Int(d[o + 3] & 0x7F)
    }

    private static func syncsafeBytes(_ n: Int) -> [UInt8] {
        [UInt8((n >> 21) & 0x7F), UInt8((n >> 14) & 0x7F), UInt8((n >> 7) & 0x7F), UInt8(n & 0x7F)]
    }

    private static let v24Only: Set<String> = [
        "TDEN", "TDOR", "TDRL", "TDTG", "TIPL", "TMCL", "TMOO", "TPRO",
        "TSOA", "TSOP", "TSOT", "TSST", "ASPI", "EQU2", "RVA2", "SEEK", "SIGN"
    ]

    private static func isKeepable(id: String, body: Data) -> Bool {
        guard id.count == 4, id.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }) else { return false }
        if v24Only.contains(id) { return false }
        let hasEncoding = id.hasPrefix("T") || ["COMM", "USLT", "APIC", "WXXX", "USER", "COMR"].contains(id)
        if hasEncoding, let first = body.first, first > 1 { return false }
        return true
    }

    private static func decodeText(_ body: Data) -> String? {
        guard let enc = body.first else { return nil }
        let payload = Data(body.dropFirst())
        let encoding: String.Encoding
        switch enc {
        case 0: encoding = .isoLatin1
        case 1: encoding = .utf16
        case 2: encoding = .utf16BigEndian
        default: encoding = .utf8
        }
        return String(data: payload, encoding: encoding)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
    }

    private static func frame(_ id: String, _ body: Data) -> Data {
        var d = Data(id.utf8)
        let n = body.count
        d.append(contentsOf: [UInt8((n >> 24) & 0xFF), UInt8((n >> 16) & 0xFF),
                              UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)])
        d.append(contentsOf: [0, 0])
        d.append(body)
        return d
    }

    private static func textFrame(_ id: String, _ text: String) -> Data {
        var body = Data([0x01, 0xFF, 0xFE])
        body.append(text.data(using: .utf16LittleEndian) ?? Data())
        return frame(id, body)
    }

    private static func apicFrame(_ image: Data) -> Data {
        let isPNG = image.starts(with: [0x89, 0x50, 0x4E, 0x47])
        let mime = isPNG ? "image/png" : "image/jpeg"
        var body = Data([0x00])
        body.append(Data(mime.utf8))
        body.append(contentsOf: [0x00, 0x03, 0x00])
        body.append(image)
        return frame("APIC", body)
    }
}
