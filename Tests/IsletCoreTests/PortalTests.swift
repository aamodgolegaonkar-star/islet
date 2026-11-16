import Foundation
import Testing
@testable import IsletCore

@Suite("Portal: requests, file names, secrets")
struct PortalTests {
    @Test func parsesHeadAndBodyStart() {
        let raw = Data("POST /send?kind=file HTTP/1.1\r\nHost: mac.local\r\nX-Islet-Token: abc\r\nContent-Length: 5\r\n\r\nhello".utf8)
        guard case let .complete(head, headLength) = PortalRequestHead.parse(raw) else { Issue.record("not parsed"); return }
        #expect(head.method == "POST")
        #expect(head.path == "/send")
        #expect(head.query["kind"] == "file")
        #expect(head.header("x-islet-token") == "abc")
        #expect(head.contentLength == 5)
        #expect(String(data: raw[headLength...], encoding: .utf8) == "hello")
    }

    @Test func waitsForTheWholeHead() {
        #expect(PortalRequestHead.parse(Data("GET / HTTP/1.1\r\nHost: x".utf8)) == .incomplete)
    }

    @Test func rejectsBadRequests() {
        #expect(PortalRequestHead.parse(Data("GARBAGE\r\n\r\n".utf8)) == .invalid)
        #expect(PortalRequestHead.parse(Data("POST /send HTTP/1.1\r\nContent-Length: -4\r\n\r\n".utf8)) == .invalid)
        #expect(PortalRequestHead.parse(Data("POST /send HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)) == .invalid)
        #expect(PortalRequestHead.parse(Data("GET http://evil/ HTTP/1.1\r\n\r\n".utf8)) == .invalid)
        // A head that never ends is cut off rather than buffered forever.
        #expect(PortalRequestHead.parse(Data(repeating: 65, count: Portal.maxHeadBytes + 1)) == .invalid)
    }

    @Test func fileNamesCannotEscapeTheFolder() {
        #expect(PortalFilename.sanitize("../../.ssh/authorized_keys") == "authorized_keys")
        #expect(PortalFilename.sanitize("..\\..\\boot.ini") == "boot.ini")
        #expect(PortalFilename.sanitize(".zshrc") == "zshrc")
        #expect(PortalFilename.sanitize("...") == "Portal Item")
        #expect(PortalFilename.sanitize("") == "Portal Item")
        #expect(PortalFilename.sanitize("a\u{0}b\nc.jpg") == "abc.jpg")
        #expect(PortalFilename.sanitize("IMG_0042.HEIC") == "IMG_0042.HEIC")
        let long = PortalFilename.sanitize(String(repeating: "x", count: 400) + ".mov")
        #expect(long.hasSuffix(".mov") && long.utf8.count < 200)
    }

    @Test func uniqueNamesNumberDuplicates() {
        let folder = URL(fileURLWithPath: "/tmp/portal")
        let taken: Set<String> = ["/tmp/portal/Photo.jpg", "/tmp/portal/Photo 2.jpg"]
        let url = PortalFilename.unique("Photo.jpg", in: folder) { taken.contains($0.path) }
        #expect(url.lastPathComponent == "Photo 3.jpg")
    }

    @Test func tokensMatchOnlyTheirHash() {
        let token = PortalSecret.make()
        let stored = PortalSecret.hash(token)
        #expect(token.count >= 43)
        #expect(PortalSecret.matches(token, hash: stored))
        #expect(!PortalSecret.matches(token + "x", hash: stored))
        #expect(!PortalSecret.matches("", hash: stored))
        #expect(PortalSecret.make() != token)
    }

    @Test func pairingCodesWorkOnceAndExpire() {
        let start = Date()
        var code = PortalPairingCode(now: start)
        let wrong = code.redeem("wrong", now: start)
        let first = code.redeem(code.code, now: start.addingTimeInterval(10))
        let again = code.redeem(code.code, now: start.addingTimeInterval(11))
        #expect(!wrong && first && !again)
        var late = PortalPairingCode(now: start)
        let expired = late.redeem(late.code, now: start.addingTimeInterval(Portal.pairingLifetime + 1))
        #expect(!expired)
    }

    @Test func onlyWebLinksOpen() {
        #expect(portalOpenableLink(" https://example.com/a?b=1 ")?.host == "example.com")
        #expect(portalOpenableLink("http://example.com") != nil)
        #expect(portalOpenableLink("file:///etc/passwd") == nil)
        #expect(portalOpenableLink("javascript:alert(1)") == nil)
        #expect(portalOpenableLink("x-apple.systempreferences:com.apple") == nil)
        #expect(portalOpenableLink("hello world https://a.com") == nil)
    }
}
