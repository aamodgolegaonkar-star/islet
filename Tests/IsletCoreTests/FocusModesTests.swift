import Foundation
import Testing
@testable import IsletCore

struct FocusModesTests {
    private func assertions(_ records: [(String, Double)]) -> Data {
        let list = records.map { id, start in
            ["assertionStartDateTimestamp": start,
             "assertionDetails": ["assertionDetailsModeIdentifier": id]] as [String: Any]
        }
        return try! JSONSerialization.data(withJSONObject: ["data": [["storeAssertionRecords": list, "storeInvalidationRecords": []]]])
    }

    @Test func noRecordsMeansNoFocus() {
        let data = try! JSONSerialization.data(withJSONObject: ["data": [["storeInvalidationRecords": []]]])
        #expect(FocusModes.activeIdentifier(assertions: data) == nil)
        #expect(FocusModes.activeIdentifier(assertions: Data("garbage".utf8)) == nil)
    }

    @Test func newestAssertionWins() {
        let data = assertions([("com.apple.focus.work", 100), ("com.apple.focus.gaming", 200), ("com.apple.focus.sleep", 150)])
        #expect(FocusModes.activeIdentifier(assertions: data) == "com.apple.focus.gaming")
    }

    @Test func readsModeConfigurations() {
        let json = """
        {"data":[{"modeConfigurations":{"com.apple.focus.work":{"mode":{"name":"Work","symbolImageName":"person.lanyardcard.fill","tintColorName":"systemTealColor","modeIdentifier":"com.apple.focus.work"}}}}]}
        """
        let modes = FocusModes.modes(configurations: Data(json.utf8))
        #expect(modes["com.apple.focus.work"] == FocusMode(identifier: "com.apple.focus.work", name: "Work",
                                                            symbol: "person.lanyardcard.fill", tint: "systemTealColor"))
        #expect(FocusModes.mode("com.apple.donotdisturb.mode.default", in: modes).name == "Do Not Disturb")
    }
}
