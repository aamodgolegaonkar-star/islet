import IsletCore
import Testing

@Suite("Headphone identification")
struct HeadphoneCatalogTests {
    @Test func renamedSonyIsFoundByModelNumber() {
        let model = HeadphoneCatalog.identify(name: "WWIII survivor🫡", vendorID: 0x054C, productID: 0x0F1E)
        #expect(model?.name == "Sony ULT WEAR")
        #expect(model?.kind == .overEar)
    }

    @Test func modelNumbersWinOverNames() {
        #expect(HeadphoneCatalog.identify(name: "WH-CH720N", vendorID: 0x054C, productID: 0x0EAF)?.name == "Sony WH-CH720N")
        #expect(HeadphoneCatalog.identify(name: "Zidane's BOSE", vendorID: 0x009E, productID: 0x4066)?.brand == .bose)
        #expect(HeadphoneCatalog.identify(name: "Studio", vendorID: 0x004C, productID: 0x200A)?.symbol == "airpods.max")
    }

    @Test func namesWhenThereAreNoModelNumbers() {
        #expect(HeadphoneCatalog.identify(name: "soundcore Space One", vendorID: nil, productID: nil)?.name == "soundcore Space One")
        #expect(HeadphoneCatalog.identify(name: "Soundcore Space Q45", vendorID: nil, productID: nil)?.brand == .soundcore)
        #expect(HeadphoneCatalog.identify(name: "Paarth’s AirPods Max", vendorID: nil, productID: nil)?.kind == .overEar)
        #expect(HeadphoneCatalog.identify(name: "Paarth’s AirPods Pro", vendorID: nil, productID: nil)?.symbol == "airpods.pro")
        #expect(HeadphoneCatalog.identify(name: "Beats Solo 4", vendorID: nil, productID: nil)?.brand == .beats)
        #expect(HeadphoneCatalog.identify(name: "Bose QC Ultra Headphones", vendorID: nil, productID: nil)?.brand == .bose)
    }

    @Test func modelFileNames() {
        #expect(HeadphoneCatalog.identify(name: "", vendorID: 0x054C, productID: 0x0F1E)?.modelFileName == "sony-ult-wear")
        #expect(HeadphoneCatalog.identify(name: "WH-CH720N", vendorID: nil, productID: nil)?.modelFileName == "sony-wh-ch720n")
        #expect(HeadphoneCatalog.identify(name: "Bose QC45", vendorID: nil, productID: nil)?.modelFileName == "bose-qc45")
    }

    @Test func unknownDevices() {
        #expect(HeadphoneCatalog.identify(name: "JBL TUNE510BT", vendorID: 0x005D, productID: 0x223B) == nil)
        #expect(HeadphoneCatalog.number("0x054C") == 0x054C)
        #expect(HeadphoneCatalog.number(nil) == nil)
    }
}
