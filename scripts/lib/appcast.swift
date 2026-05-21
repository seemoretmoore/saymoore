import Foundation

enum AppcastGenerator {
    static func item(
        version: String,
        buildNumber: String,
        minSystemVersion: String,
        zipURL: String,
        edSignature: String,
        length: Int64,
        pubDate: String
    ) -> String {
        """
        <item>
            <title>Version \(version)</title>
            <pubDate>\(pubDate)</pubDate>
            <sparkle:minimumSystemVersion>\(minSystemVersion)</sparkle:minimumSystemVersion>
            <enclosure
                url="\(zipURL)"
                sparkle:version="\(buildNumber)"
                sparkle:shortVersionString="\(version)"
                length="\(length)"
                type="application/octet-stream"
                sparkle:edSignature="\(edSignature)" />
        </item>
        """
    }

    static func feed(items: [String]) -> String {
        """
        <?xml version="1.0" standalone="yes"?>
        <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
        <channel>
            <title>SayMoore</title>
            <link>https://github.com/seemoretmoore/saymoore</link>
            <description>SayMoore release feed.</description>
            <language>en</language>
        \(items.joined(separator: "\n"))
        </channel>
        </rss>
        """
    }
}
