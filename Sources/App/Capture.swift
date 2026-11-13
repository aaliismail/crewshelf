import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Records `--ctl record` frames (the composite of the shelf and the bubble) into an animated GIF with ImageIO,
/// so making the README GIF needs no ffmpeg. Frames are taken on the main run loop while the UI keeps animating,
/// and each one is encoded as it comes, so memory stays flat.
final class GifRecorder {
    let path: String
    let frames: Int
    let fps: Double
    private var dest: CGImageDestination?
    private var taken = 0
    private var timer: Timer?

    init(path: String, frames: Int, fps: Double) {
        self.path = path
        self.frames = max(1, frames)
        self.fps = max(1, fps)
    }

    func start(frame: @escaping () -> NSBitmapImageRep?, done: @escaping (Bool) -> Void) {
        guard let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.gif.identifier as CFString,
                                                      frames, nil) else { return done(false) }
        CGImageDestinationSetProperties(d, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        dest = d
        let props = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary
        timer = Timer.scheduledTimer(withTimeInterval: 1 / fps, repeats: true) { [weak self] t in
            guard let self = self, let d = self.dest else { t.invalidate(); return }
            if let img = autoreleasepool(invoking: { frame()?.cgImage }) {
                CGImageDestinationAddImage(d, img, props)
                self.taken += 1
            }
            if self.taken >= self.frames {
                t.invalidate()
                let ok = CGImageDestinationFinalize(d)
                self.dest = nil
                done(ok)
            }
        }
    }
}
