import Foundation

@main
struct PreviewPolicyTests {
    static func main() {
        func expect(_ result: @autoclosure () -> Bool, _ message: String) {
            precondition(result(), "FAIL: \(message)")
            print("PASS: \(message)")
        }
        let expiry = 103.5
        expect(PreviewPolicy.shouldShow(unread: 1, text: "Done", expanded: false,
                eligible: true, now: 100, expiresAt: expiry), "new unread response shows a preview")
        expect(!PreviewPolicy.shouldShow(unread: 1, text: "Done", expanded: false,
                eligible: true, now: 103.5, expiresAt: expiry), "preview expires despite unread badge")
        expect(!PreviewPolicy.shouldShow(unread: 0, text: "Done", expanded: false,
                eligible: true, now: 100, expiresAt: expiry), "read chat does not show preview")
        expect(!PreviewPolicy.shouldShow(unread: 1, text: "Done", expanded: true,
                eligible: true, now: 100, expiresAt: expiry), "open chat hides preview")
        expect(!PreviewPolicy.shouldShow(unread: 1, text: "Done", expanded: false,
                eligible: false, now: 100, expiresAt: expiry), "hidden stack member cannot show preview")
        expect(!PreviewPolicy.shouldShow(unread: 1, text: "", expanded: false,
                eligible: true, now: 100, expiresAt: expiry), "empty preview cannot show")
        expect(PreviewPolicy.shouldShow(unread: 2, text: "Next reply", expanded: false,
                eligible: true, now: 104, expiresAt: 107.5), "new reply renews preview window")
        print("Preview lifetime and unread separation tests passed")
    }
}
