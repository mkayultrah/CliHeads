import AppKit
import UniformTypeIdentifiers

/// An image waiting to go out with the next message (pasted, dropped or picked).
/// Kept small enough for the API: long edge at most 2000px, under ~3.7MB raw.
struct ImageAttachment: Identifiable, Equatable {
    let id = UUID()
    let mediaType: String
    let data: Data

    static func == (a: ImageAttachment, b: ImageAttachment) -> Bool { a.id == b.id }

    var image: NSImage? { NSImage(data: data) }

    var fileExtension: String {
        switch mediaType {
        case "image/jpeg": return "jpg"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        default: return "png"
        }
    }

    private static let maxBytes = 3_700_000
    private static let maxSide = 2000
    private static let sendable = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
                                   "gif": "image/gif", "webp": "image/webp"]

    static func from(fileURL: URL) -> ImageAttachment? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        if let type = sendable[fileURL.pathExtension.lowercased()], data.count <= maxBytes,
           let rep = NSBitmapImageRep(data: data), max(rep.pixelsWide, rep.pixelsHigh) <= maxSide {
            return ImageAttachment(mediaType: type, data: data)
        }
        guard let image = NSImage(data: data) else { return nil }
        return from(image: image)
    }

    static func from(image: NSImage) -> ImageAttachment? {
        guard var cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let longest = max(cg.width, cg.height)
        if longest > maxSide, let scaled = scale(cg, by: Double(maxSide) / Double(longest)) { cg = scaled }
        let rep = NSBitmapImageRep(cgImage: cg)
        if let png = rep.representation(using: .png, properties: [:]), png.count <= maxBytes {
            return ImageAttachment(mediaType: "image/png", data: png)
        }
        for quality in [0.85, 0.7, 0.5] {
            if let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: quality]),
               jpg.count <= maxBytes {
                return ImageAttachment(mediaType: "image/jpeg", data: jpg)
            }
        }
        return nil
    }

    /// A smaller JPEG copy for CLIs that take the image inline on the command line,
    /// where macOS caps the whole argument list at about 1MB.
    func shrunk(toFit limit: Int) -> ImageAttachment {
        guard data.count > limit, var cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return self }
        for side in [1600, 1200, 900, 600] {
            let longest = max(cg.width, cg.height)
            if longest > side, let scaled = Self.scale(cg, by: Double(side) / Double(longest)) { cg = scaled }
            let rep = NSBitmapImageRep(cgImage: cg)
            for quality in [0.8, 0.6] {
                if let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: quality]), jpg.count <= limit {
                    return ImageAttachment(mediaType: "image/jpeg", data: jpg)
                }
            }
        }
        return self
    }

    /// Image files first (Finder copy or drag), then raw image data (screenshots).
    /// Plain text on the pasteboard wins over raw image data so normal pastes still work.
    static func from(pasteboard: NSPasteboard) -> [ImageAttachment] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.image.identifier]
        ]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL], !urls.isEmpty {
            return urls.compactMap { from(fileURL: $0) }
        }
        if pasteboard.availableType(from: [.string]) != nil { return [] }
        if pasteboard.availableType(from: [.png, .tiff]) != nil, let image = NSImage(pasteboard: pasteboard),
           let attachment = from(image: image) {
            return [attachment]
        }
        return []
    }

    private static func scale(_ cg: CGImage, by factor: Double) -> CGImage? {
        let width = max(1, Int(Double(cg.width) * factor)), height = max(1, Int(Double(cg.height) * factor))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// Sent images are kept on disk so the chat bubble can still show them after a relaunch.
    static var storeDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("CliHeads/Images", isDirectory: true)
    }

    func save() -> String? {
        let dir = Self.storeDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(id.uuidString).\(fileExtension)")
        return (try? data.write(to: url)) != nil ? url.path : nil
    }
}
