import Foundation

/// A pair of headphones Islet recognises, for the connection card in the island.
public struct HeadphoneModel: Sendable, Equatable {
    public enum Brand: String, Sendable {
        case apple, beats, sony, soundcore, bose, other
    }

    public enum Kind: Sendable {
        case earbuds, overEar
    }

    public var name: String
    public var brand: Brand
    public var kind: Kind
    /// SF Symbol drawn on the card (Apple's own glyphs for AirPods and Beats).
    public var symbol: String

    public init(name: String, brand: Brand, kind: Kind, symbol: String) {
        self.name = name
        self.brand = brand
        self.kind = kind
        self.symbol = symbol
    }

    /// File name (without extension) of a 3D model the user can add for this model,
    /// e.g. "sony-ult-wear.usdz".
    public var modelFileName: String {
        name.lowercased()
            .replacing(/[^a-z0-9]+/, with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

/// Identifies headphones from what macOS reports: the maker and model numbers first (they
/// survive renaming, e.g. a Sony called "WWIII survivor"), then the device name.
public enum HeadphoneCatalog {
    static let appleVendor = 0x004C
    static let sonyVendor = 0x054C
    static let boseVendor = 0x009E

    private static let apple: [Int: HeadphoneModel] = [
        0x2002: .init(name: "AirPods", brand: .apple, kind: .earbuds, symbol: "airpods"),
        0x200F: .init(name: "AirPods", brand: .apple, kind: .earbuds, symbol: "airpods"),
        0x2013: .init(name: "AirPods (3rd generation)", brand: .apple, kind: .earbuds, symbol: "airpods.gen3"),
        0x2019: .init(name: "AirPods 4", brand: .apple, kind: .earbuds, symbol: "airpods.gen4"),
        0x201B: .init(name: "AirPods 4", brand: .apple, kind: .earbuds, symbol: "airpods.gen4"),
        0x200E: .init(name: "AirPods Pro", brand: .apple, kind: .earbuds, symbol: "airpods.pro"),
        0x2014: .init(name: "AirPods Pro", brand: .apple, kind: .earbuds, symbol: "airpods.pro"),
        0x2024: .init(name: "AirPods Pro", brand: .apple, kind: .earbuds, symbol: "airpods.pro"),
        0x200A: .init(name: "AirPods Max", brand: .apple, kind: .overEar, symbol: "airpods.max"),
        0x201F: .init(name: "AirPods Max", brand: .apple, kind: .overEar, symbol: "airpods.max"),
        0x2006: .init(name: "Beats Solo³", brand: .beats, kind: .overEar, symbol: "beats.headphones"),
        0x200C: .init(name: "Beats Solo Pro", brand: .beats, kind: .overEar, symbol: "beats.headphones"),
        0x2025: .init(name: "Beats Solo 4", brand: .beats, kind: .overEar, symbol: "beats.headphones"),
        0x2009: .init(name: "Beats Studio³", brand: .beats, kind: .overEar, symbol: "beats.headphones"),
        0x2017: .init(name: "Beats Studio Pro", brand: .beats, kind: .overEar, symbol: "beats.headphones"),
        0x2026: .init(name: "Beats Solo Buds", brand: .beats, kind: .earbuds, symbol: "beats.solobuds"),
        0x2011: .init(name: "Beats Studio Buds", brand: .beats, kind: .earbuds, symbol: "beats.studiobuds"),
        0x2016: .init(name: "Beats Studio Buds +", brand: .beats, kind: .earbuds, symbol: "beats.studiobuds"),
        0x2012: .init(name: "Beats Fit Pro", brand: .beats, kind: .earbuds, symbol: "beats.fitpro"),
        0x200B: .init(name: "Powerbeats Pro", brand: .beats, kind: .earbuds, symbol: "beats.powerbeats.pro"),
        0x201D: .init(name: "Powerbeats Pro 2", brand: .beats, kind: .earbuds, symbol: "beats.powerbeats.pro"),
    ]

    private static let sony: [Int: HeadphoneModel] = [
        0x0EAF: .init(name: "Sony WH-CH720N", brand: .sony, kind: .overEar, symbol: "headphones"),
        0x0F1E: .init(name: "Sony ULT WEAR", brand: .sony, kind: .overEar, symbol: "headphones"),
    ]

    private static let bose: [Int: HeadphoneModel] = [
        0x4066: .init(name: "Bose QuietComfort Ultra", brand: .bose, kind: .overEar, symbol: "headphones"),
    ]

    /// Name fragments for devices without model numbers (or unknown ones), most specific first.
    private static let names: [(fragment: String, model: HeadphoneModel)] = [
        ("airpods max", .init(name: "AirPods Max", brand: .apple, kind: .overEar, symbol: "airpods.max")),
        ("airpods pro", .init(name: "AirPods Pro", brand: .apple, kind: .earbuds, symbol: "airpods.pro")),
        ("airpods", .init(name: "AirPods", brand: .apple, kind: .earbuds, symbol: "airpods")),
        ("solo buds", .init(name: "Beats Solo Buds", brand: .beats, kind: .earbuds, symbol: "beats.solobuds")),
        ("beats solo", .init(name: "Beats Solo", brand: .beats, kind: .overEar, symbol: "beats.headphones")),
        ("beats studio buds", .init(name: "Beats Studio Buds", brand: .beats, kind: .earbuds, symbol: "beats.studiobuds")),
        ("beats studio", .init(name: "Beats Studio", brand: .beats, kind: .overEar, symbol: "beats.headphones")),
        ("ult wear", .init(name: "Sony ULT WEAR", brand: .sony, kind: .overEar, symbol: "headphones")),
        ("wh-ult900n", .init(name: "Sony ULT WEAR", brand: .sony, kind: .overEar, symbol: "headphones")),
        ("ch720n", .init(name: "Sony WH-CH720N", brand: .sony, kind: .overEar, symbol: "headphones")),
        ("space q45", .init(name: "soundcore Space Q45", brand: .soundcore, kind: .overEar, symbol: "headphones")),
        ("space one", .init(name: "soundcore Space One", brand: .soundcore, kind: .overEar, symbol: "headphones")),
        ("qc45", .init(name: "Bose QC45", brand: .bose, kind: .overEar, symbol: "headphones")),
        ("qc 45", .init(name: "Bose QC45", brand: .bose, kind: .overEar, symbol: "headphones")),
        ("quietcomfort 45", .init(name: "Bose QC45", brand: .bose, kind: .overEar, symbol: "headphones")),
        ("qc ultra", .init(name: "Bose QuietComfort Ultra", brand: .bose, kind: .overEar, symbol: "headphones")),
        ("quietcomfort ultra", .init(name: "Bose QuietComfort Ultra", brand: .bose, kind: .overEar, symbol: "headphones")),
    ]

    /// The model, or nil for audio devices Islet doesn't know (shown with a generic glyph).
    public static func identify(name: String, vendorID: Int?, productID: Int?) -> HeadphoneModel? {
        if let vendorID, let productID {
            let table: [Int: HeadphoneModel]? = switch vendorID {
            case appleVendor: apple
            case sonyVendor: sony
            case boseVendor: bose
            default: nil
            }
            if let model = table?[productID] { return model }
        }
        let lowered = name.lowercased()
        return names.first { lowered.contains($0.fragment) }?.model
    }

    /// Parses system_profiler's "0x054C" style numbers.
    public static func number(_ text: String?) -> Int? {
        guard let text else { return nil }
        let digits = text.lowercased().hasPrefix("0x") ? String(text.dropFirst(2)) : text
        return Int(digits, radix: 16)
    }
}
