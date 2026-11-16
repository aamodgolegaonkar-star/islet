import AVFoundation
import CoreImage
import CoreML
import IsletCore
import Vision

/// What one camera frame says about the face in it.
struct FaceSample: Sendable {
    var time: TimeInterval
    /// The face's fingerprint (nil: no face, or it couldn't be lined up).
    var embedding: [Float]?
    var eyes: Double?
    var yaw = 0.0, pitch = 0.0, roll = 0.0
    /// A rectangle (a phone screen or a photo's edge) surrounds the face.
    var framed = false
    /// Seconds the analysis took (for the timing log).
    var cost = 0.0
    /// Mean red, green and blue of the middle of the face and of the whole frame, for the
    /// light check (nil: no face).
    var faceColor: [Double]?
    var sceneColor: [Double]?
    /// Where the face is (normalized, y up).
    var faceBox: CGRect?
    /// The anti-spoofing models' chance this is a live face (nil: they didn't run).
    var realness: Double?

    var liveness: LivenessTracker.Frame {
        .init(time: time, eyes: eyes, yaw: yaw, pitch: pitch, roll: roll, framed: framed, realness: realness)
    }

    var flashReading: FlashChallenge.Reading? {
        guard let faceColor, let sceneColor else { return nil }
        return .init(time: time, face: faceColor, scene: sceneColor)
    }
}

/// Finds the face in a frame with Vision, lines it up the way SFace was trained (eyes,
/// nose tip and mouth corners on fixed points of a 112×112 image) and turns it into a
/// 128-number fingerprint with the Core ML model. Used on the camera's queue only.
final class FaceEngine: @unchecked Sendable {
    private let model: MLModel
    /// Minivision's MiniFASNet pair (anti-spoofing), each with how far it widens the face
    /// box. Optional: without them liveness is the blink alone.
    private let antiSpoof: [(model: MLModel, scale: Double)]
    private let context = CIContext(options: [.cacheIntermediates: false])
    /// The anti-spoofing models' input side, in pixels.
    private static let patchSide = 80

    init?() {
        guard let url = Bundle.main.url(forResource: "SFace", withExtension: "mlmodelc") else { return nil }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        guard let model = try? MLModel(contentsOf: url, configuration: configuration) else { return nil }
        self.model = model
        let pair: [(model: MLModel, scale: Double)] = [("AntiSpoof27", 2.7), ("AntiSpoof40", 4.0)].compactMap { name, scale in
            guard let url = Bundle.main.url(forResource: name, withExtension: "mlmodelc"),
                  let model = try? MLModel(contentsOf: url, configuration: configuration) else { return nil }
            return (model, scale)
        }
        antiSpoof = pair.count == 2 ? pair : []
    }

    var hasAntiSpoofing: Bool { !antiSpoof.isEmpty }

    func analyze(_ buffer: CVPixelBuffer, time: TimeInterval, lookForFrames: Bool) -> FaceSample {
        var sample = FaceSample(time: time)
        // Faces first (this revision reports head pose), then their landmarks.
        let faces = VNDetectFaceRectanglesRequest()
        faces.revision = VNDetectFaceRectanglesRequestRevision3
        let landmarks = VNDetectFaceLandmarksRequest()
        let rectangles = VNDetectRectanglesRequest()
        rectangles.maximumObservations = 4
        rectangles.minimumConfidence = 0.6
        rectangles.minimumSize = 0.25
        rectangles.minimumAspectRatio = 0.3
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up)
        try? handler.perform(lookForFrames ? [faces, rectangles] : [faces])
        // The biggest face is the one in front of the Mac.
        guard let found = faces.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width }) else { return sample }
        landmarks.inputFaceObservations = [found]
        try? handler.perform([landmarks])
        guard let face = landmarks.results?.first, let marks = face.landmarks else { return sample }
        let width = Double(CVPixelBufferGetWidth(buffer)), height = Double(CVPixelBufferGetHeight(buffer))
        let size = CGSize(width: width, height: height)
        // Vision's points have y going up; the alignment works with y going down.
        func points(_ region: VNFaceLandmarkRegion2D?) -> [FaceID.Point] {
            region?.pointsInImage(imageSize: size).map { FaceID.Point(x: Double($0.x), y: height - Double($0.y)) } ?? []
        }
        sample.yaw = (found.yaw?.doubleValue ?? 0) * 180 / .pi
        sample.pitch = (found.pitch?.doubleValue ?? 0) * 180 / .pi
        sample.roll = (found.roll?.doubleValue ?? 0) * 180 / .pi
        let eyes = [FaceID.eyeOpenness(points(marks.leftEye)), FaceID.eyeOpenness(points(marks.rightEye))].compactMap { $0 }
        sample.eyes = eyes.isEmpty ? nil : eyes.reduce(0, +) / Double(eyes.count)
        // Nose and cheeks (Vision's box has y going up from the chin): skin, not hair or background.
        let box = found.boundingBox
        sample.faceBox = box
        sample.faceColor = Self.meanColor(buffer, in: CGRect(x: box.minX + box.width * 0.25, y: box.minY + box.height * 0.2,
                                                             width: box.width * 0.5, height: box.height * 0.4))
        sample.sceneColor = Self.meanColor(buffer, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        if lookForFrames, let rects = rectangles.results {
            sample.framed = rects.contains { rect in
                let frame = rect.boundingBox
                // A frame clearly around the face, but not just the edges of the picture.
                return frame.insetBy(dx: -0.02, dy: -0.02).contains(box) && frame.width * frame.height < 0.9
                    && box.width * box.height < frame.width * frame.height * 0.7
            }
        }
        let image = CIImage(cvPixelBuffer: buffer)
        guard let frame = context.createCGImage(image, from: image.extent) else { return sample }
        if lookForFrames, hasAntiSpoofing {
            sample.realness = realness(frame, box: box, width: width, height: height)
        }
        let pupils = points(marks.leftPupil) + points(marks.rightPupil)
        guard let keys = FaceID.keyPoints(pupils: pupils, nose: points(marks.nose), outerLips: points(marks.outerLips)),
              let transform = FaceID.similarityTransform(from: keys, to: FaceID.template),
              let pixels = render(frame, transform: transform, side: Int(FaceID.inputSide), height: height) else { return sample }
        sample.embedding = embed(Self.planes(pixels, order: [0, 1, 2]))
        return sample
    }

    /// How live the face looks rather than printed or on a screen, 0…1: both models' chance
    /// of "real", averaged, each on its own wider cut around the face, as Minivision crops.
    private func realness(_ frame: CGImage, box: CGRect, width: Double, height: Double) -> Double? {
        let side = Double(Self.patchSide)
        var total = 0.0
        for (model, scale) in antiSpoof {
            // Vision's box (normalized, y up) as pixels with y down, as the models were trained.
            let crop = FaceID.spoofCrop(x: box.minX * width, y: (1 - box.maxY) * height,
                                        width: box.width * width, height: box.height * height,
                                        scale: scale, frameWidth: width, frameHeight: height)
            let squeeze = [side / crop.width, 0, -crop.x * side / crop.width,
                           0, side / crop.height, -crop.y * side / crop.height]
            guard let pixels = render(frame, transform: squeeze, side: Self.patchSide, height: height),
                  let input = Self.multiArray(Self.planes(pixels, order: [2, 1, 0]), side: Self.patchSide),
                  let output = try? model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["patch": input])),
                  let probabilities = output.featureValue(for: "probabilities")?.multiArrayValue,
                  probabilities.count == 3 else { return nil }
            // [printed, real, screen]
            total += probabilities[1].doubleValue
        }
        return total / Double(antiSpoof.count)
    }

    /// Mean red, green and blue (0–255) of part of a BGRA frame (`rect` normalized, y up),
    /// from every fourth pixel of every fourth row: plenty for an average, and cheap.
    private static func meanColor(_ buffer: CVPixelBuffer, in rect: CGRect) -> [Double]? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
              let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let x0 = max(0, Int(rect.minX * Double(width))), x1 = min(width, Int(rect.maxX * Double(width)))
        let y0 = max(0, Int((1 - rect.maxY) * Double(height))), y1 = min(height, Int((1 - rect.minY) * Double(height)))
        guard x1 > x0, y1 > y0 else { return nil }
        var red = 0, green = 0, blue = 0, count = 0
        for y in stride(from: y0, to: y1, by: 4) {
            let row = base + y * rowBytes
            for x in stride(from: x0, to: x1, by: 4) {
                blue += Int(row[x * 4]); green += Int(row[x * 4 + 1]); red += Int(row[x * 4 + 2])
                count += 1
            }
        }
        guard count > 0 else { return nil }
        return [Double(red), Double(green), Double(blue)].map { $0 / Double(count) }
    }

    /// Part of the frame drawn into a `side`×`side` RGBA bitmap: `m` (`[a, b, tx, c, d, ty]`)
    /// maps frame pixels to bitmap pixels, both with y going down.
    private func render(_ cgImage: CGImage, transform m: [Double], side: Int, height: Double) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let ctx = CGContext(data: bytes.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .high
            // y-down output space, then the alignment, then the frame drawn y-down too.
            ctx.translateBy(x: 0, y: CGFloat(side))
            ctx.scaleBy(x: 1, y: -1)
            ctx.concatenate(CGAffineTransform(a: m[0], b: m[3], c: m[1], d: m[4], tx: m[2], ty: m[5]))
            ctx.translateBy(x: 0, y: CGFloat(height))
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
            return true
        }
        return drawn ? pixels : nil
    }

    /// RGBA pixels as three planes of 0–255 values, in `order` (`[0, 1, 2]` RGB, `[2, 1, 0]` BGR).
    private static func planes(_ pixels: [UInt8], order: [Int]) -> [Float] {
        let count = pixels.count / 4
        var planes = [Float](repeating: 0, count: 3 * count)
        for index in 0..<count {
            for (plane, channel) in order.enumerated() { planes[plane * count + index] = Float(pixels[index * 4 + channel]) }
        }
        return planes
    }

    private static func multiArray(_ planes: [Float], side: Int) -> MLMultiArray? {
        let n = NSNumber(value: side)
        guard let input = try? MLMultiArray(shape: [1, 3, n, n], dataType: .float32) else { return nil }
        planes.withUnsafeBufferPointer { source in
            input.withUnsafeMutableBytes { target, _ in
                target.copyMemory(from: UnsafeRawBufferPointer(source))
            }
        }
        return input
    }

    private func embed(_ planes: [Float]) -> [Float]? {
        guard let input = Self.multiArray(planes, side: Int(FaceID.inputSide)) else { return nil }
        guard let output = try? model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["face": input])),
              let vector = output.featureValue(for: "embedding")?.multiArrayValue else { return nil }
        let count = vector.count
        var result = [Float](repeating: 0, count: count)
        for index in 0..<count { result[index] = vector[index].floatValue }
        return FaceID.normalized(result)
    }
}

/// The front camera, delivering every frame it can (up to 30 a second) to `onFrame` on its
/// own queue. A blink lasts a tenth of a second or so, so fewer frames miss it; frames that
/// arrive while one is still being analysed are dropped.
final class FaceCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "local.islet.faceid.camera")
    private var onFrame: (@Sendable (CVPixelBuffer, TimeInterval) -> Void)?

    static var authorized: Bool { AVCaptureDevice.authorizationStatus(for: .video) == .authorized }

    /// Starts the camera; false if there's none (lid closed) or no permission.
    func start(onFrame: @escaping @Sendable (CVPixelBuffer, TimeInterval) -> Void) -> Bool {
        guard Self.authorized,
              let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
                ?? AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else { return false }
        self.onFrame = onFrame
        session.beginConfiguration()
        session.sessionPreset = .vga640x480
        guard session.canAddInput(input) else { session.commitConfiguration(); return false }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { session.commitConfiguration(); return false }
        session.addOutput(output)
        session.commitConfiguration()
        queue.async { self.session.startRunning() }
        return true
    }

    func stop() {
        queue.async {
            self.onFrame = nil
            self.session.stopRunning()
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame?(buffer, ProcessInfo.processInfo.systemUptime)
    }
}
