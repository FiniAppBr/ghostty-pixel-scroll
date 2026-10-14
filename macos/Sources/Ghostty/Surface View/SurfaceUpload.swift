#if os(macOS)
import AppKit
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

// Local to this build: pasting or dropping a file, folder or image uploads it
// to wherever the splits actually run and types the remote path, because a
// local path means nothing to a program on the other end of an ssh.
//
// The transfer itself is ~/bin/ghostty-upload's business; this file decides
// what gets uploaded, feeds it the bytes, and shows the upload happening. When
// that script does not exist none of this is active and paste and drop behave
// as they always have.
//
// Nothing here depends on the rest of Ghostty: the surface hands over a
// pasteboard and a closure that types text. That keeps it testable on its own.

/// One thing to upload.
enum UploadSource: Equatable {
    /// A file or folder on disk, uploaded as is.
    case file(URL)

    /// Image bytes straight off the pasteboard, a screenshot most often. These
    /// are re-encoded before they go (see `UploadImageEncoder`).
    case bitmap(Data, UTType)
}

// MARK: - Deciding what a paste is

enum UploadClassifier {
    /// Image types worth uploading, most preferred first. PNG and TIFF are what
    /// screenshots and most apps put on the pasteboard.
    static let imageTypes: [UTType] = [.png, .tiff, .jpeg, .heic, .gif, .webP]

    /// What a paste should upload, or nil to paste text as usual.
    ///
    /// Files win: Finder puts the file name on the pasteboard as text beside
    /// the file itself. Otherwise text wins over an image, because apps that
    /// copy text often add a picture of it (a spreadsheet's cells, a styled
    /// document), and that should paste as the text. The exception is text
    /// that is only the image's own address, which is what a browser's "copy
    /// image" adds.
    static func sources(from pb: NSPasteboard) -> [UploadSource]? {
        let files = fileURLs(on: pb)
        if !files.isEmpty { return files.map { .file($0) } }

        guard let (data, type) = image(on: pb) else { return nil }
        if let text = pb.string(forType: .string),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !isBareURL(text) {
            return nil
        }
        return [.bitmap(data, type)]
    }

    /// Cheap enough for every Cmd+V: looks at the declared types only.
    static func mightUpload(_ pb: NSPasteboard) -> Bool {
        guard let types = pb.types else { return false }
        if types.contains(.fileURL) { return true }
        return imageTypes.contains { types.contains(NSPasteboard.PasteboardType($0.identifier)) }
    }

    static func fileURLs(on pb: NSPasteboard) -> [URL] {
        (pb.pasteboardItems ?? []).compactMap { item in
            guard let plist = item.propertyList(forType: .fileURL),
                  let url = NSURL(pasteboardPropertyList: plist, ofType: .fileURL) as URL?,
                  url.isFileURL else { return nil }
            return url
        }
    }

    static func image(on pb: NSPasteboard) -> (Data, UTType)? {
        for type in imageTypes {
            if let data = pb.data(forType: NSPasteboard.PasteboardType(type.identifier)), !data.isEmpty {
                return (data, type)
            }
        }
        return nil
    }

    static func isBareURL(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.contains(where: \.isWhitespace),
              let url = URL(string: t),
              let scheme = url.scheme?.lowercased() else { return false }
        return ["http", "https", "file", "data"].contains(scheme)
    }
}

// MARK: - Making images small enough to send

/// Screenshots come off the pasteboard as full-resolution PNG or TIFF: a Retina
/// screenshot is several megabytes, which is seconds over a home uplink. What
/// reads it on the other end is a model that bills an image by its pixel
/// count (about width x height / 750 tokens) and scales anything past 1568 on
/// the long edge down anyway. So the size is a token budget: shrink until the
/// image is at most `maxPixels` (about 1,000 tokens), which keeps UI text
/// readable, and never past `maxEdge`. Smaller images go untouched. Then keep
/// whichever of PNG or JPEG is smaller, with a thumb on the scale for PNG,
/// which keeps text crisp.
enum UploadImageEncoder {
    static let maxEdge = 1568
    static let maxPixels = 750_000
    static let jpegQuality = 0.86

    struct Encoded {
        var data: Data
        var ext: String
        var pixels: (Int, Int)
    }

    static func encode(_ data: Data, type: UTType) -> Encoded? {
        // An animated GIF would lose its animation; send it untouched.
        if type == .gif { return Encoded(data: data, ext: "gif", pixels: (0, 0)) }

        guard let rep = NSBitmapImageRep(data: data), let cg = rep.cgImage else { return nil }
        let w = cg.width, h = cg.height
        let scale = min(
            1.0,
            Double(maxEdge) / Double(max(w, h)),
            (Double(maxPixels) / Double(w * h)).squareRoot())

        let image: CGImage
        if scale < 1 {
            let nw = max(1, Int((Double(w) * scale).rounded()))
            let nh = max(1, Int((Double(h) * scale).rounded()))
            guard let ctx = CGContext(
                data: nil, width: nw, height: nh, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            ctx.interpolationQuality = .high
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: nw, height: nh))
            guard let scaled = ctx.makeImage() else { return nil }
            image = scaled
        } else {
            // Already small, and already compact: leave it be.
            if type == .png || type == .jpeg {
                return Encoded(data: data, ext: type == .png ? "png" : "jpg", pixels: (w, h))
            }
            image = cg
        }

        let out = NSBitmapImageRep(cgImage: image)
        let png = out.representation(using: .png, properties: [:])
        let hasAlpha = ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        let jpeg = hasAlpha && imageUsesAlpha(image) ? nil :
            out.representation(using: .jpeg, properties: [.compressionFactor: jpegQuality])

        switch (png, jpeg) {
        case let (p?, j?):
            return Double(p.count) <= Double(j.count) * 1.25
                ? Encoded(data: p, ext: "png", pixels: (image.width, image.height))
                : Encoded(data: j, ext: "jpg", pixels: (image.width, image.height))
        case let (p?, nil):
            return Encoded(data: p, ext: "png", pixels: (image.width, image.height))
        case let (nil, j?):
            return Encoded(data: j, ext: "jpg", pixels: (image.width, image.height))
        default:
            return nil
        }
    }

    /// Whether any pixel is actually see-through. Screenshots carry an alpha
    /// channel that is opaque everywhere, and should not be kept from JPEG
    /// for it; a window shadow or a cut-out icon should.
    private static func imageUsesAlpha(_ image: CGImage) -> Bool {
        // Sample on a coarse grid rather than reading every pixel.
        let side = 64
        guard let ctx = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return true }
        ctx.clear(CGRect(x: 0, y: 0, width: side, height: side))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let px = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return true }
        for i in stride(from: 3, to: side * side * 4, by: 4) where px[i] < 250 { return true }
        return false
    }
}

// MARK: - One upload

final class UploadJob: ObservableObject, Identifiable {
    enum Phase: Equatable {
        case preparing
        case uploading
        /// Every byte is across; the far side is putting it in place.
        case finishing
        case done(path: String)
        case failed(String)
        case cancelled

        var isTerminal: Bool {
            switch self {
            case .done, .failed, .cancelled: return true
            default: return false
            }
        }
    }

    let id = UUID()
    let source: UploadSource
    let createdAt = Date()

    @Published private(set) var name: String
    @Published private(set) var detail: String?
    @Published private(set) var thumbnail: NSImage?
    @Published private(set) var phase: Phase = .preparing
    @Published private(set) var sent: Int64 = 0
    @Published private(set) var total: Int64?
    /// Bytes per second, smoothed. Nil until there is something to measure.
    @Published private(set) var rate: Double?

    /// Set once the path has been typed, or skipped because it failed.
    var settled = false

    var onFinish: ((UploadJob) -> Void)?

    private let helper: URL
    private var process: Process?
    private var feeder: Process?
    private var cancelRequested = false
    private var lastSample: (Date, Int64)?

    init(source: UploadSource, helper: URL) {
        self.source = source
        self.helper = helper
        switch source {
        case .file(let url):
            name = url.lastPathComponent
        case .bitmap(_, let type):
            let f = DateFormatter()
            f.dateFormat = "HHmmss"
            name = "clipboard-\(f.string(from: Date())).\(type.preferredFilenameExtension ?? "png")"
        }
    }

    var fraction: Double? {
        guard let total, total > 0 else { return nil }
        return min(1, max(0, Double(sent) / Double(total)))
    }

    var secondsLeft: Double? {
        guard let total, let rate, rate > 0, phase == .uploading else { return nil }
        return Double(max(0, total - sent)) / rate
    }

    // MARK: Running

    func start() {
        cancelRequested = false
        phase = .preparing
        sent = 0
        rate = nil
        lastSample = nil
        detail = nil
        loadThumbnail()
        let source = source
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.run(source)
        }
    }

    func cancel() {
        guard !phase.isTerminal else { return }
        cancelRequested = true
        feeder?.terminate()
        // SIGTERM: the helper tells the far side to throw the partial away.
        process?.terminate()
        if process == nil { finish(.cancelled) }
    }

    func retry() {
        guard case .failed = phase else { return }
        settled = false
        start()
    }

    /// Off the main thread from here on.
    private func run(_ source: UploadSource) {
        let proc = Process()
        proc.executableURL = helper
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        // What gets written to the helper, and how.
        enum Body { case data(Data), file(URL), tar(URL) }
        let body: Body
        var size: Int64?
        var remoteName = name

        switch source {
        case .bitmap(let data, let type):
            guard let enc = UploadImageEncoder.encode(data, type: type) else {
                return finishOnMain(.failed("couldn't read the image"))
            }
            remoteName = (name as NSString).deletingPathExtension + "." + enc.ext
            body = .data(enc.data)
            size = Int64(enc.data.count)
            let px = enc.pixels.0 > 0 ? "\(enc.pixels.0)×\(enc.pixels.1) " : ""
            let detail = "\(px)\(enc.ext.uppercased())"
            DispatchQueue.main.async { self.name = remoteName; self.detail = detail }

        case .file(let url):
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
                return finishOnMain(.failed("file is gone"))
            }
            if isDir.boolValue {
                body = .tar(url)
                // A tar runs a little over the sum of what is in it: a 512
                // byte header per entry and padding to 512 per file.
                let (bytes, count) = Self.folderSize(url)
                size = bytes + Int64(count) * 1024 + 10240
                let detail = "\(count) item\(count == 1 ? "" : "s")"
                DispatchQueue.main.async { self.detail = detail }
            } else {
                body = .file(url)
                size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
            }
        }

        switch body {
        case .tar: proc.arguments = ["--tar", remoteName]
        default: proc.arguments = [remoteName, String(size ?? -1)]
        }

        let total = size
        DispatchQueue.main.async {
            self.total = total
            self.phase = .uploading
        }

        // Progress and errors come back on stderr; see ghostty-upload.
        var errorLines: [String] = []
        var buffer = Data()
        let lock = NSLock()
        stderr.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            guard !chunk.isEmpty else { return }
            lock.lock()
            buffer.append(chunk)
            var progress: Int64?
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...nl)
                if line.hasPrefix("P "), let n = Int64(line.dropFirst(2)) {
                    progress = n
                } else if !line.isEmpty {
                    errorLines.append(line)
                }
            }
            lock.unlock()
            if let progress {
                DispatchQueue.main.async { self?.progressed(progress) }
            }
        }

        var outData = Data()
        let outDone = DispatchGroup()
        outDone.enter()
        DispatchQueue.global(qos: .utility).async {
            outData = stdout.fileHandleForReading.readDataToEndOfFile()
            outDone.leave()
        }

        do {
            try proc.run()
        } catch {
            stderr.fileHandleForReading.readabilityHandler = nil
            return finishOnMain(.failed("couldn't start the uploader"))
        }
        DispatchQueue.main.async { self.process = proc }
        if cancelRequested { proc.terminate() }

        // Feed it. A write after the helper has gone must fail rather than
        // raise SIGPIPE, which would take the whole app with it.
        let fd = stdin.fileHandleForWriting.fileDescriptor
        _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        switch body {
        case .data(let data):
            _ = data.withUnsafeBytes { Self.writeAll(fd, $0, cancelled: { self.cancelRequested }) }
        case .file(let url):
            if let h = try? FileHandle(forReadingFrom: url) {
                while !cancelRequested {
                    guard let chunk = try? h.read(upToCount: 256 * 1024), !chunk.isEmpty else { break }
                    let ok = chunk.withUnsafeBytes { Self.writeAll(fd, $0, cancelled: { self.cancelRequested }) }
                    if !ok { break }
                }
                try? h.close()
            }
        case .tar(let url):
            let tar = Process()
            tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            tar.arguments = ["-cf", "-", "-C", url.deletingLastPathComponent().path, url.lastPathComponent]
            // No AppleDouble ._ files: they are Finder metadata, meaningless
            // on Linux, and they would clutter the folder that arrives.
            var env = ProcessInfo.processInfo.environment
            env["COPYFILE_DISABLE"] = "1"
            tar.environment = env
            tar.standardOutput = stdin.fileHandleForWriting
            tar.standardError = FileHandle.nullDevice
            DispatchQueue.main.async { self.feeder = tar }
            if (try? tar.run()) != nil { tar.waitUntilExit() }
        }
        try? stdin.fileHandleForWriting.close()

        proc.waitUntilExit()
        outDone.wait()
        stderr.fileHandleForReading.readabilityHandler = nil

        let path = String(decoding: outData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let status = proc.terminationStatus
        lock.lock()
        let message = errorLines.last
        lock.unlock()

        if cancelRequested || status == 143 || status == 6 {
            finishOnMain(.cancelled)
        } else if status == 0, !path.isEmpty {
            finishOnMain(.done(path: path))
        } else {
            finishOnMain(.failed(message ?? "upload failed (\(status))"))
        }
    }

    private func progressed(_ bytes: Int64) {
        guard !phase.isTerminal else { return }
        let now = Date()
        if let (t0, b0) = lastSample, now.timeIntervalSince(t0) > 0.05 {
            let r = Double(bytes - b0) / now.timeIntervalSince(t0)
            rate = rate.map { $0 * 0.7 + r * 0.3 } ?? r
            lastSample = (now, bytes)
        } else if lastSample == nil {
            lastSample = (now, bytes)
        }
        sent = max(sent, bytes)
        if let total, sent >= total, phase == .uploading { phase = .finishing }
    }

    private func finishOnMain(_ phase: Phase) {
        DispatchQueue.main.async { self.finish(phase) }
    }

    private func finish(_ phase: Phase) {
        guard !self.phase.isTerminal else { return }
        if case .done = phase, let total { sent = total }
        self.phase = phase
        process = nil
        feeder = nil
        onFinish?(self)
    }

    private static func writeAll(_ fd: Int32, _ buf: UnsafeRawBufferPointer, cancelled: () -> Bool) -> Bool {
        guard var p = buf.baseAddress else { return true }
        var left = buf.count
        while left > 0 {
            if cancelled() { return false }
            let n = Darwin.write(fd, p, min(left, 64 * 1024))
            if n < 0 {
                if errno == EINTR { continue }
                return false
            }
            p += n
            left -= n
        }
        return true
    }

    static func folderSize(_ url: URL) -> (Int64, Int) {
        var bytes: Int64 = 0, count = 0
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else {
            return (0, 0)
        }
        for case let f as URL in e {
            count += 1
            let v = try? f.resourceValues(forKeys: Set(keys))
            if v?.isRegularFile == true { bytes += Int64(v?.fileSize ?? 0) }
        }
        return (bytes, count)
    }

    // MARK: Thumbnail

    private func loadThumbnail() {
        guard thumbnail == nil else { return }
        switch source {
        case .bitmap(let data, _):
            DispatchQueue.global(qos: .userInitiated).async {
                let thumb = Self.downsample(data, to: 480)
                DispatchQueue.main.async { self.thumbnail = thumb }
            }
        case .file(let url):
            thumbnail = NSWorkspace.shared.icon(forFile: url.path)
            let req = QLThumbnailGenerator.Request(
                fileAt: url, size: CGSize(width: 240, height: 240), scale: 2,
                representationTypes: .thumbnail)
            QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { rep, _ in
                guard let rep else { return }
                DispatchQueue.main.async { self.thumbnail = rep.nsImage }
            }
        }
    }

    static func downsample(_ data: Data, to px: Int) -> NSImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: px,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

// MARK: - A split's uploads

/// The uploads started from one split, in the order they were started. Paths
/// are typed in that order too, whatever order the uploads finish in, so that
/// pasting two screenshots puts them in the prompt the way they were pasted.
final class SurfaceUploads: ObservableObject {
    static let helper = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("bin/ghostty-upload")

    static var available: Bool {
        FileManager.default.isExecutableFile(atPath: helper.path)
    }

    /// What is on screen.
    @Published private(set) var jobs: [UploadJob] = []

    /// Uploads whose path has not been typed yet, oldest first. Kept apart
    /// from `jobs` because a card can leave the screen (a finished one,
    /// after a moment) while its path still waits on an earlier upload.
    private var unsettled: [UploadJob] = []

    /// Types text into the split.
    var insert: ((String) -> Void)?

    /// How long a finished card stays up, so the eye can catch that it worked.
    var doneLinger: TimeInterval = 1.4

    /// Uploads `sources`, returning false (doing nothing) if uploading is
    /// unavailable and the caller should handle them the old way.
    @discardableResult
    func start(_ sources: [UploadSource]) -> Bool {
        guard !sources.isEmpty, Self.available else { return false }
        for source in sources {
            let job = UploadJob(source: source, helper: Self.helper)
            job.onFinish = { [weak self] job in self?.finished(job) }
            jobs.append(job)
            unsettled.append(job)
            job.start()
        }
        return true
    }

    /// The paste entry point: uploads what is on `pb` if it is files or an
    /// image, and says whether it did.
    func paste(from pb: NSPasteboard) -> Bool {
        guard Self.available, UploadClassifier.mightUpload(pb),
              let sources = UploadClassifier.sources(from: pb) else { return false }
        return start(sources)
    }

    func dismiss(_ job: UploadJob) {
        job.cancel()
        remove(job)
    }

    func retry(_ job: UploadJob) {
        guard case .failed = job.phase else { return }
        // It was settled as a failure; it types its path when it lands now.
        unsettled.append(job)
        job.retry()
    }

    private func finished(_ job: UploadJob) {
        settle()
        switch job.phase {
        case .done:
            DispatchQueue.main.asyncAfter(deadline: .now() + doneLinger) { [weak self, weak job] in
                guard let job, case .done = job.phase else { return }
                self?.remove(job)
            }
        case .cancelled:
            remove(job)
        default:
            break
        }
    }

    /// Type the paths of every finished upload that is not waiting behind an
    /// unfinished one. A failure does not hold up what comes after it.
    private func settle() {
        var paths: [String] = []
        while let job = unsettled.first, job.phase.isTerminal {
            unsettled.removeFirst()
            job.settled = true
            if case .done(let path) = job.phase { paths.append(path) }
        }
        guard !paths.isEmpty else { return }
        insert?(paths.joined(separator: " ") + " ")
    }

    private func remove(_ job: UploadJob) {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) {
            jobs.removeAll { $0 === job }
        }
        settle()
    }

    // MARK: Warm connection

    private static var lastWarm: Date?

    /// Opens the shared ssh connection if it is not already up, so the first
    /// upload does not pay for a handshake. Cheap when it is up already.
    static func warm() {
        guard available else { return }
        if let lastWarm, Date().timeIntervalSince(lastWarm) < 300 { return }
        lastWarm = Date()
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = helper
            p.arguments = ["--warm"]
            p.standardInput = FileHandle.nullDevice
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
        }
    }
}

// MARK: - What it looks like

struct UploadTray: View {
    @ObservedObject var uploads: SurfaceUploads

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(uploads.jobs) { job in
                UploadCard(
                    job: job,
                    onClose: { uploads.dismiss(job) },
                    onRetry: { uploads.retry(job) })
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .opacity.combined(with: .scale(scale: 0.96))))
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.9), value: uploads.jobs.map(\.id))
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    }
}

struct UploadCard: View {
    @ObservedObject var job: UploadJob
    var onClose: () -> Void
    var onRetry: () -> Void = {}

    @State private var hovering = false

    private var isImage: Bool {
        if case .bitmap = job.source { return true }
        if case .file(let url) = job.source,
           let type = UTType(filenameExtension: url.pathExtension) {
            return type.conforms(to: .image)
        }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Hovering an image shows it properly, to check it is the one
            // you meant before it lands in the prompt.
            if hovering, isImage, let thumb = job.thumbnail {
                Image(nsImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 256, maxHeight: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .frame(maxWidth: .infinity)
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .bottom)))
            }

            HStack(spacing: 10) {
                thumbnail
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(job.name)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                        statusIcon
                    }
                    UploadProgressBar(fraction: job.fraction, phase: job.phase)
                    Text(statusText)
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(statusColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                button
            }
        }
        .padding(10)
        .frame(width: 300)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.22), radius: 12, y: 4)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
        .help(helpText)
    }

    @ViewBuilder private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.06))
            if let thumb = job.thumbnail {
                Image(nsImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: isImage ? .fill : .fit)
                    .padding(isImage ? 0 : 3)
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    @ViewBuilder private var statusIcon: some View {
        switch job.phase {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .transition(.scale.combined(with: .opacity))
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var button: some View {
        switch job.phase {
        case .failed:
            HStack(spacing: 2) {
                iconButton("arrow.clockwise", help: "Try again") { onRetry() }
                iconButton("xmark", help: "Dismiss") { onClose() }
            }
        case .done, .cancelled:
            EmptyView()
        default:
            iconButton("xmark", help: "Cancel upload") { onClose() }
        }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }

    private var statusText: String {
        switch job.phase {
        case .preparing:
            return job.detail.map { "Preparing · \($0)" } ?? "Preparing…"
        case .uploading:
            guard let total = job.total else { return "Uploading…" }
            var s = "\(Self.bytes(job.sent)) of \(Self.bytes(total))"
            if let left = job.secondsLeft, left >= 1.5 { s += " · \(Self.duration(left)) left" }
            return s
        case .finishing:
            return "Finishing…"
        case .done(let path):
            return path
        case .failed(let message):
            return message
        case .cancelled:
            return "Cancelled"
        }
    }

    private var statusColor: Color {
        switch job.phase {
        case .failed: return .orange
        default: return .secondary
        }
    }

    private var helpText: String {
        if case .done(let path) = job.phase { return path }
        if case .file(let url) = job.source { return url.path }
        return job.name
    }

    static func bytes(_ n: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = n < 1_000_000 ? [.useKB] : [.useMB, .useGB]
        return f.string(fromByteCount: n)
    }

    static func duration(_ s: Double) -> String {
        s < 60 ? "\(Int(s.rounded())) s" : "\(Int(s / 60)) min \(Int(s.truncatingRemainder(dividingBy: 60))) s"
    }
}

/// A slim bar. Indeterminate while there is nothing to measure yet, a sweep
/// rather than a spinner so it reads as the same bar that is about to fill.
struct UploadProgressBar: View {
    var fraction: Double?
    var phase: UploadJob.Phase

    @State private var sweep = false

    private var isDone: Bool {
        if case .done = phase { return true }
        return false
    }

    private var tint: Color {
        switch phase {
        case .done: return .green
        case .failed: return .orange
        default: return .accentColor
        }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                if case .failed = phase {
                    // Just the empty track: a failed upload has no progress
                    // worth showing, and a sliver of fill reads as a dot.
                    EmptyView()
                } else if let fraction, phase != .preparing {
                    Capsule()
                        .fill(tint)
                        .frame(width: max(4, geo.size.width * (isDone ? 1 : fraction)))
                        .animation(.easeOut(duration: 0.25), value: fraction)
                } else if !phase.isTerminal {
                    Capsule()
                        .fill(tint.opacity(0.8))
                        .frame(width: geo.size.width * 0.3)
                        .offset(x: sweep ? geo.size.width * 0.7 : 0)
                        .onAppear {
                            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                                sweep = true
                            }
                        }
                } else {
                    Capsule().fill(tint).frame(width: geo.size.width)
                }
            }
        }
        .frame(height: 4)
        .clipShape(Capsule())
    }
}
#endif
