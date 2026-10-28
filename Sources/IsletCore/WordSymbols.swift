import Foundation
import NaturalLanguage

/// Pictures for lyric words: "fire" → `flame.fill`, "love" → `heart.fill`, "rain" → `cloud.rain.fill`.
///
/// Built from macOS's own SF Symbols data in CoreGlyphs.bundle (every symbol's name, its
/// search keywords and its categories), so nothing leaves the Mac. A short hand-made list
/// covers words songs use a lot that the symbol names miss ("night", "money", "tears").
/// Other words only get a picture when they're nouns and match an everyday symbol (nature,
/// weather, people, objects…), never an editing or arrow glyph.
public final class WordSymbols: Sendable {
    /// Word → symbol, for every word that has one.
    private let curated: [String: String]
    private let byName: [String: String]
    private let byKeyword: [String: String]

    public init(names: Set<String>, keywords: [String: [String]], categories: [String: [String]]) {
        func friendly(_ name: String) -> Bool {
            let found = Set(categories[name] ?? [])
            return !found.isDisjoint(with: Self.everyday) && found.isDisjoint(with: Self.technical)
        }
        // The filled variant reads better at lyric sizes.
        func filled(_ name: String) -> String { names.contains(name + ".fill") ? name + ".fill" : name }

        curated = Self.common.compactMapValues { names.contains($0) ? filled($0) : nil }
        var byName: [String: String] = [:]
        for name in names where !name.contains(".") && friendly(name) {
            byName[name] = filled(name)
        }
        self.byName = byName
        var byKeyword: [String: (name: String, parts: Int)] = [:]
        for (name, words) in keywords where names.contains(name) && friendly(name) {
            let parts = name.split(separator: ".").count
            guard parts <= 2 else { continue }
            for word in words.map({ $0.lowercased() }) where parts < (byKeyword[word]?.parts ?? .max) {
                byKeyword[word] = (name, parts)
            }
        }
        self.byKeyword = byKeyword.mapValues { filled($0.name) }
    }

    /// The system's symbol data, or nil if this macOS keeps it somewhere else.
    public static let system: WordSymbols? = {
        let folder = URL(fileURLWithPath: "/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources")
        func plist(_ name: String) -> Any? {
            guard let data = try? Data(contentsOf: folder.appending(path: name)) else { return nil }
            return try? PropertyListSerialization.propertyList(from: data, format: nil)
        }
        guard let availability = plist("name_availability.plist") as? [String: Any],
              let symbols = availability["symbols"] as? [String: Any],
              let keywords = plist("symbol_search.plist") as? [String: [String]],
              let categories = plist("symbol_categories.plist") as? [String: [String]]
        else { return nil }
        return WordSymbols(names: Set(symbols.keys), keywords: keywords, categories: categories)
    }()

    /// The symbol for one word. `lemma` is its dictionary form ("burning" → "burn").
    public func symbol(for word: String, lemma: String? = nil, isNoun: Bool) -> String? {
        let forms = [Self.clean(word), lemma.map(Self.clean)].compactMap { $0 }.filter { $0.count >= 3 }
        if let found = forms.lazy.compactMap({ self.curated[$0] }).first { return found }
        guard isNoun else { return nil }
        return forms.lazy.compactMap { self.byName[$0] ?? self.byKeyword[$0] }.first
    }

    /// Gives each word of each line its symbol, using the line around it to tell nouns
    /// from verbs ("a fly" vs "I fly") and to find dictionary forms.
    public func annotate(_ lines: [LyricLine]) -> [LyricLine] {
        let tagger = NLTagger(tagSchemes: [.lexicalClass, .lemma])
        return lines.map { line in
            guard !line.words.isEmpty else { return line }
            var line = line
            var text = ""
            var starts: [String.Index?] = []
            for word in line.words {
                if !text.isEmpty { text += " " }
                let offset = text.count
                text += word.text
                // Tag at the first letter, past any "(" or quote.
                let letter = word.text.firstIndex(where: \.isLetter).map { word.text.distance(from: word.text.startIndex, to: $0) }
                starts.append(letter.map { text.index(text.startIndex, offsetBy: offset + $0) })
            }
            tagger.string = text
            for (index, start) in starts.enumerated() {
                guard let start else { continue }
                let lexical = tagger.tag(at: start, unit: .word, scheme: .lexicalClass).0
                let lemma = tagger.tag(at: start, unit: .word, scheme: .lemma).0?.rawValue
                line.words[index].symbol = symbol(for: line.words[index].text, lemma: lemma, isNoun: lexical == .noun)
            }
            return line
        }
    }

    /// Lowercase letters only: "Fire!" → "fire", "heart's" → "heart".
    static func clean(_ word: String) -> String {
        var word = word.lowercased()
        if word.hasSuffix("'s") || word.hasSuffix("’s") { word.removeLast(2) }
        return String(word.filter(\.isLetter))
    }

    // MARK: - Data

    private static let everyday: Set<String> = [
        "nature", "weather", "transportation", "automotive", "human", "home", "fitness", "health",
        "gaming", "commerce", "time", "objectsandtools", "communication", "devices", "maps",
    ]
    private static let technical: Set<String> = [
        "textformatting", "arrows", "editing", "keyboard", "math", "indices", "shapes",
        "privacyandsecurity", "connectivity", "accessibility",
        // Player buttons: "play" in a lyric isn't ▶.
        "media",
    ]

    /// Words songs use a lot, for which the symbol names alone pick nothing or the wrong thing.
    private static let common: [String: String] = [
        "love": "heart", "kiss": "heart", "heart": "heart", "fire": "flame", "burn": "flame",
        "flame": "flame", "night": "moon.stars", "moon": "moon", "star": "star", "stars": "sparkles",
        "sun": "sun.max", "summer": "sun.max", "sunshine": "sun.max", "sunrise": "sunrise",
        "sunset": "sunset", "sky": "cloud", "cloud": "cloud", "rain": "cloud.rain",
        "storm": "cloud.bolt", "thunder": "cloud.bolt", "lightning": "bolt", "snow": "snowflake",
        "winter": "snowflake", "ice": "snowflake", "cold": "thermometer.snowflake",
        "wind": "wind", "ocean": "water.waves", "sea": "water.waves", "wave": "water.waves",
        "waves": "water.waves", "water": "drop", "tears": "drop", "tear": "drop", "cry": "drop",
        "money": "dollarsign", "cash": "dollarsign", "gold": "crown", "king": "crown",
        "queen": "crown", "crown": "crown", "diamond": "diamond", "dream": "sparkles",
        "heaven": "sparkles", "angel": "sparkles", "shine": "sparkles", "glow": "sparkles",
        "dance": "figure.dance", "run": "figure.run", "sing": "music.mic", "song": "music.note",
        "music": "music.note", "radio": "radio", "guitar": "guitars", "drive": "car",
        "car": "car", "ride": "car", "call": "phone", "phone": "phone", "sleep": "moon.zzz",
        "bed": "bed.double", "world": "globe", "earth": "globe.americas", "time": "clock",
        "clock": "clock", "road": "road.lanes", "fly": "bird", "wings": "bird", "bird": "bird",
        "plane": "airplane", "boat": "sailboat", "train": "tram", "home": "house",
        "house": "house", "city": "building.2", "eyes": "eye", "eye": "eye",
        "hand": "hand.raised", "hands": "hands.clap", "mind": "brain.head.profile",
        "brain": "brain", "breath": "lungs", "party": "party.popper", "key": "key",
        "lock": "lock", "door": "door.left.hand.open", "mountain": "mountain.2", "tree": "tree",
        "leaf": "leaf", "flower": "camera.macro", "rose": "camera.macro", "gift": "gift",
        "wine": "wineglass", "drink": "wineglass", "smile": "face.smiling", "light": "lightbulb",
        "lights": "lightbulb", "gun": "scope", "bullet": "scope", "game": "gamecontroller",
        "trophy": "trophy", "medal": "medal", "letter": "envelope", "book": "book",
        "picture": "photo", "photo": "photo", "camera": "camera", "shoes": "shoe",
        "dress": "tshirt", "shirt": "tshirt", "beach": "beach.umbrella", "island": "beach.umbrella",
        "umbrella": "umbrella", "dog": "dog", "cat": "cat", "fish": "fish", "bell": "bell",
        "pill": "pills", "pills": "pills", "hot": "thermometer.sun",
    ]
}
