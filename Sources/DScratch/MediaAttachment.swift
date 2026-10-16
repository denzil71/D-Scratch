import AppKit
import AVKit
import UniformTypeIdentifiers

/// Text attachment that sizes images to the page width and plays video/audio inline.
final class MediaAttachment: NSTextAttachment {
    enum Kind { case image, video, audio }

    let kind: Kind
    private var naturalSize: CGSize = .zero
    private var cachedURL: URL?

    init(fileWrapper: FileWrapper, kind: Kind) {
        self.kind = kind
        super.init(data: nil, ofType: nil)
        self.fileWrapper = fileWrapper
        if kind == .image, let data = fileWrapper.regularFileContents, let img = NSImage(data: data) {
            image = img
            naturalSize = img.size
        }
    }

    required init?(coder: NSCoder) {
        kind = .image
        super.init(coder: coder)
    }

    static func kind(forFilename name: String) -> Kind? {
        guard let type = UTType(filenameExtension: (name as NSString).pathExtension) else { return nil }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) { return .video }
        if type.conforms(to: .audio) { return .audio }
        return nil
    }

    /// AVPlayer needs a file URL, so media bytes are written to a temp cache on demand.
    var playbackURL: URL? {
        if let url = cachedURL, FileManager.default.fileExists(atPath: url.path) { return url }
        guard let wrapper = fileWrapper, let data = wrapper.regularFileContents else { return nil }
        let ext = ((wrapper.preferredFilename ?? wrapper.filename ?? "") as NSString).pathExtension
        cachedURL = MediaCache.write(data, ext: ext)
        return cachedURL
    }

    override func viewProvider(
        for parentView: NSView?, location: NSTextLocation, textContainer: NSTextContainer?
    ) -> NSTextAttachmentViewProvider? {
        guard kind != .image else { return super.viewProvider(for: parentView, location: location, textContainer: textContainer) }
        let provider = PlayerViewProvider(
            textAttachment: self, parentView: parentView,
            textLayoutManager: textContainer?.textLayoutManager, location: location)
        provider.tracksTextAttachmentViewBounds = true
        return provider
    }

    override func attachmentBounds(
        for attributes: [NSAttributedString.Key: Any], location: NSTextLocation,
        textContainer: NSTextContainer?, proposedLineFragment: CGRect, position: CGPoint
    ) -> CGRect {
        let maxWidth = max(120, proposedLineFragment.width - 12)
        switch kind {
        case .image:
            guard naturalSize.width > 0 else {
                return super.attachmentBounds(
                    for: attributes, location: location, textContainer: textContainer,
                    proposedLineFragment: proposedLineFragment, position: position)
            }
            let scale = min(1, maxWidth / naturalSize.width)
            return CGRect(x: 0, y: 0, width: naturalSize.width * scale, height: naturalSize.height * scale)
        case .video:
            let width = min(maxWidth, 560)
            return CGRect(x: 0, y: 0, width: width, height: width * 9 / 16)
        case .audio:
            return CGRect(x: 0, y: 0, width: min(maxWidth, 420), height: 54)
        }
    }

    /// Swaps plain attachments (from drag, paste or a loaded file) for MediaAttachments.
    static func upgrade(_ storage: NSTextStorage) {
        var swaps: [(NSRange, MediaAttachment)] = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let plain = value as? NSTextAttachment, !(plain is MediaAttachment),
                  let wrapper = plain.fileWrapper, wrapper.isRegularFile,
                  let name = wrapper.preferredFilename ?? wrapper.filename,
                  let kind = kind(forFilename: name) else { return }
            swaps.append((range, MediaAttachment(fileWrapper: wrapper, kind: kind)))
        }
        guard !swaps.isEmpty else { return }
        storage.beginEditing()
        for (range, attachment) in swaps { storage.addAttribute(.attachment, value: attachment, range: range) }
        storage.endEditing()
    }
}

final class PlayerViewProvider: NSTextAttachmentViewProvider {
    override func loadView() {
        let playerView = AVPlayerView()
        playerView.controlsStyle = .inline
        if let url = (textAttachment as? MediaAttachment)?.playbackURL {
            playerView.player = AVPlayer(url: url)
        }
        view = playerView
    }
}

enum MediaCache {
    static let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("D-Scratch-media", isDirectory: true)

    static func write(_ data: Data, ext: String) -> URL? {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    static func clear() { try? FileManager.default.removeItem(at: dir) }
}
