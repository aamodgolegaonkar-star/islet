import AppKit
import IsletCore
import RealityKit
import SwiftUI

/// The picture on the headphones card: a 3D model the user added to Islet's Models folder
/// (e.g. "sony-ult-wear.usdz"); otherwise Apple's glyph for the model (exact ones for
/// AirPods and Beats, headphones for everything else), turning gently in 3D.
struct Headphone3DView: View {
    let model: HeadphoneModel?
    @Environment(\.isSnapshotRendering) private var snapshot
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// ~/Library/Application Support/Islet/Models
    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Islet/Models")
    }

    @State private var turned = false

    var body: some View {
        if !snapshot, let url = modelFile {
            RealityView { content in
                guard let entity = try? await Entity(contentsOf: url) else { return }
                let fitted = Self.fitted(entity)
                content.add(fitted)
                if let studio = await Self.studio() {
                    fitted.components.set(ImageBasedLightComponent(source: .single(studio), intensityExponent: 1.4))
                    Self.receiveLight(from: fitted, in: fitted)
                }
                for (intensity, from) in [(2600, SIMD3<Float>(0.6, 1, 1.2)), (1400, [-1, 0.4, 0.8]), (1800, [0, 0.6, -1.2])] as [(Float, SIMD3<Float>)] {
                    let light = DirectionalLight()
                    light.light.intensity = intensity
                    light.look(at: .zero, from: from, relativeTo: nil)
                    content.add(light)
                }
                let camera = PerspectiveCamera()
                camera.camera.fieldOfViewInDegrees = 38
                camera.look(at: .zero, from: [0, 0.08, 1.3], relativeTo: nil)
                content.add(camera)
                if !reduceMotion, !LiveTuning.shared.batterySaving { Self.swing(entity) }
            }
        } else {
            Image(systemName: model?.symbol ?? "headphones")
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(LinearGradient(colors: [.white, Color(white: 0.72)], startPoint: .top, endPoint: .bottom))
                .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
                .rotation3DEffect(.degrees(turned ? 24 : -24), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
                .symbolEffect(.bounce, options: .nonRepeating)
                .onAppear {
                    guard !snapshot, !reduceMotion, !LiveTuning.shared.batterySaving else { return }
                    withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) { turned = true }
                }
        }
    }

    /// A soft studio environment (bright overhead softbox, side strips, dark floor) so
    /// glossy user models get real reflections.
    private static func studio() async -> EnvironmentResource? {
        let width = 512, height = 256
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let gradient = CGGradient(colorsSpace: space,
                                        colors: [NSColor(white: 0.55, alpha: 1).cgColor, NSColor(white: 0.12, alpha: 1).cgColor,
                                                 NSColor(white: 0.05, alpha: 1).cgColor] as CFArray,
                                        locations: [0, 0.55, 1])
        else { return nil }
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: height), end: .zero, options: [])
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 180, y: 200, width: 150, height: 40))
        context.setFillColor(NSColor(white: 0.85, alpha: 1).cgColor)
        context.fill(CGRect(x: 40, y: 110, width: 30, height: 90))
        context.fill(CGRect(x: 300, y: 110, width: 30, height: 90))
        guard let image = context.makeImage() else { return nil }
        return try? await EnvironmentResource(equirectangular: image, withName: "studio")
    }

    /// The user's model for this headphone, if there is one (.usdz or .reality).
    private var modelFile: URL? {
        guard let name = model?.modelFileName else { return nil }
        return ["usdz", "reality"].lazy
            .map { Self.folder.appending(path: "\(name).\($0)") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Every model in the tree reflects the studio environment.
    private static func receiveLight(from source: Entity, in entity: Entity) {
        entity.components.set(ImageBasedLightReceiverComponent(imageBasedLight: source))
        for child in entity.children { receiveLight(from: source, in: child) }
    }

    /// Centred and scaled to a one-unit box, whatever size and origin the file uses.
    private static func fitted(_ entity: Entity) -> Entity {
        let bounds = entity.visualBounds(relativeTo: nil)
        let size = max(bounds.extents.x, bounds.extents.y, bounds.extents.z)
        let pivot = Entity()
        pivot.addChild(entity)
        if size > 0 {
            entity.position = -bounds.center
            pivot.scale = SIMD3(repeating: 0.85 / size)
        }
        pivot.orientation = simd_quatf(angle: 0.12, axis: [1, 0, 0])
        return pivot
    }

    /// A slow swing, like the iPhone's pairing card.
    private static func swing(_ entity: Entity) {
        var from = entity.transform
        from.rotation = simd_quatf(angle: -0.75, axis: [0, 1, 0])
        var to = entity.transform
        to.rotation = simd_quatf(angle: 0.35, axis: [0, 1, 0])
        let animation = FromToByAnimation(from: from, to: to, duration: 2.4, timing: .easeInOut,
                                          bindTarget: .transform, repeatMode: .autoReverse)
        if let resource = try? AnimationResource.generate(with: animation) {
            entity.playAnimation(resource)
        }
    }
}
