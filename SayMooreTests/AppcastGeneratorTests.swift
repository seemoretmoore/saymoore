import XCTest

final class AppcastGeneratorTests: XCTestCase {
    func test_singleItemAppcast_matchesGolden() throws {
        let xml = AppcastGenerator.item(
            version: "1.0.0",
            buildNumber: "10",
            minSystemVersion: "14.0",
            zipURL: "https://github.com/seemoretmoore/saymoore/releases/download/v1.0.0/SayMoore-1.0.0.zip",
            edSignature: "fakeSigBase64==",
            length: 12345678,
            pubDate: "Wed, 20 May 2026 12:00:00 +0000"
        )
        let expected = """
        <item>
            <title>Version 1.0.0</title>
            <pubDate>Wed, 20 May 2026 12:00:00 +0000</pubDate>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <enclosure
                url="https://github.com/seemoretmoore/saymoore/releases/download/v1.0.0/SayMoore-1.0.0.zip"
                sparkle:version="10"
                sparkle:shortVersionString="1.0.0"
                length="12345678"
                type="application/octet-stream"
                sparkle:edSignature="fakeSigBase64==" />
        </item>
        """
        XCTAssertEqual(
            xml.trimmingCharacters(in: .whitespacesAndNewlines),
            expected.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    func test_fullAppcast_wrapsItemInRSSChannel() throws {
        let item = "<item>X</item>"
        let xml = AppcastGenerator.feed(items: [item])
        XCTAssertTrue(xml.contains("<rss version=\"2.0\""))
        XCTAssertTrue(xml.contains("xmlns:sparkle=\"http://www.andymatuschak.org/xml-namespaces/sparkle\""))
        XCTAssertTrue(xml.contains("<channel>"))
        XCTAssertTrue(xml.contains("<title>SayMoore</title>"))
        XCTAssertTrue(xml.contains("<item>X</item>"))
        XCTAssertTrue(xml.contains("</channel>"))
        XCTAssertTrue(xml.contains("</rss>"))
    }
}
