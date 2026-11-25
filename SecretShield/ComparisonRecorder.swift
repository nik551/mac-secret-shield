#if DEBUG
import AVFoundation
import CoreMedia
import os

/// Debug builds only, explicit opt-in, synthetic test secrets only: records two videos of one mirroring session
/// so you can compare them, `raw.mov` (what the display really showed, straight from capture) and `shield.mov`
/// (what the mirror window showed viewers). Each frame is stamped with the time it appeared, so the shield video
/// also shows the delay. Folder 0700, files 0600, under ~/Library/Caches/SecretShield/Recordings/<time>/.
final class ComparisonRecorder: @unchecked Sendable { // all writer state is touched only on `queue`
    static let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appending(path: "SecretShield/Recordings")

    let folder: URL
    private let queue = DispatchQueue(label: "SecretShield.recorder")
    private var tracks: [String: Track] = [:]
    private var start: CFTimeInterval?
    private var finished = false

    private final class Track: @unchecked Sendable { // used only on `queue`, then finished once
        let writer: AVAssetWriter
        let input: AVAssetWriterInput
        let adaptor: AVAssetWriterInputPixelBufferAdaptor
        var dropped = 0
        var lastTime = -1.0

        init?(url: URL, width: Int, height: Int) {
            guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return nil }
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            ])
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { return nil }
            writer.add(input)
            adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
            guard writer.startWriting() else { return nil }
            writer.startSession(atSourceTime: .zero)
            self.writer = writer
            self.input = input
        }
    }

    init() {
        let name = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        folder = Self.root.appending(path: name)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: Self.root.path)
    }

    /// `time`: when the frame appeared (capture time for raw, release time for shield), host clock seconds.
    func append(_ frame: Frame, to name: String, at time: CFTimeInterval) {
        queue.async { [self] in
            guard !finished else { return }
            let start = self.start ?? time
            self.start = start
            if tracks[name] == nil {
                tracks[name] = Track(url: folder.appending(path: "\(name).mov"),
                                     width: CVPixelBufferGetWidth(frame.pixelBuffer), height: CVPixelBufferGetHeight(frame.pixelBuffer))
            }
            guard let track = tracks[name] else { return }
            let seconds = time - start
            // Frames must be in time order and the encoder must keep up; otherwise skip (the video just holds).
            guard seconds > track.lastTime, track.input.isReadyForMoreMediaData,
                  track.adaptor.append(frame.pixelBuffer, withPresentationTime: CMTime(seconds: seconds, preferredTimescale: 600))
            else { track.dropped += 1; return }
            track.lastTime = seconds
        }
    }

    /// Closes both files; returns how many frames each track skipped.
    func finish() async -> [String: Int] {
        let tracks: [String: Track] = await withCheckedContinuation { done in
            queue.async { [self] in
                finished = true
                done.resume(returning: self.tracks)
            }
        }
        for (name, track) in tracks {
            track.input.markAsFinished()
            await track.writer.finishWriting()
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: folder.appending(path: "\(name).mov").path)
        }
        return tracks.mapValues(\.dropped)
    }
}
#endif
