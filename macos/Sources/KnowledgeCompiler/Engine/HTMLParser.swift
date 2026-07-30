import Foundation

struct ParsedPage: Sendable {
    let title: String
    let text: String
    let links: [URL]
}

struct HTMLParser: Sendable {
    private let strippedBlocks: [String]

    init(
        filterNav: Bool = true,
        filterFooter: Bool = true,
        filterScripts: Bool = true,
        filterStyles: Bool = true
    ) {
        var blocks: [String] = ["noscript", "svg"]
        if filterScripts { blocks.append("script") }
        if filterStyles { blocks.append("style") }
        if filterNav { blocks.append("nav") }
        if filterFooter { blocks.append("footer") }
        blocks.append("header")
        self.strippedBlocks = blocks
    }

    func rawText(from html: String) -> String {
        var cleaned = html
        cleaned = replace(in: cleaned, pattern: "<!--.*?-->", with: " ")
        for tag in strippedBlocks {
            cleaned = replace(in: cleaned, pattern: "<\(tag)\\b[^>]*>.*?</\(tag)>", with: " ")
        }
        var text = replace(in: cleaned, pattern: "<[^>]+>", with: " ")
        text = decodeEntities(text)
        text = collapse(text)
        return text
    }
    private static let skippedExtensions: Set<String> = [
        "pdf", "png", "jpg", "jpeg", "gif", "webp", "svg", "zip", "gz", "tar",
        "mp4", "mp3", "mov", "avi", "dmg", "exe", "ico", "css", "js", "xml", "rss", "woff", "woff2",
    ]

    func extract(html: String, baseURL: URL, sameDomainOnly: Bool) -> ParsedPage {
        let title = firstMatch(in: html, pattern: "<title[^>]*>(.*?)</title>")
            .map { decodeEntities(collapse($0)) } ?? ""

        var cleaned = html
        cleaned = replace(in: cleaned, pattern: "<!--.*?-->", with: " ")
        for tag in strippedBlocks {
            cleaned = replace(in: cleaned, pattern: "<\(tag)\\b[^>]*>.*?</\(tag)>", with: " ")
        }

        let links = extractLinks(from: cleaned, baseURL: baseURL, sameDomainOnly: sameDomainOnly)

        var text = replace(in: cleaned, pattern: "<[^>]+>", with: " ")
        text = decodeEntities(text)
        text = collapse(text)

        return ParsedPage(title: title, text: text, links: links)
    }

    private func extractLinks(from html: String, baseURL: URL, sameDomainOnly: Bool) -> [URL] {
        let pattern = "<a\\b[^>]*?href\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let ns = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        let baseHost = normalizedHost(baseURL.host)

        var seen = Set<String>()
        var links: [URL] = []

        for match in matches {
            var href: String?
            for group in 1...3 where match.range(at: group).location != NSNotFound {
                href = ns.substring(with: match.range(at: group))
                break
            }
            guard var raw = href?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { continue }
            raw = decodeEntities(raw)
            let lower = raw.lowercased()
            if lower.hasPrefix("mailto:") || lower.hasPrefix("javascript:") || lower.hasPrefix("tel:")
                || lower.hasPrefix("data:") || lower.hasPrefix("#") {
                continue
            }
            guard let resolved = URL(string: raw, relativeTo: baseURL)?.absoluteURL,
                  var comps = URLComponents(url: resolved, resolvingAgainstBaseURL: false) else { continue }

            comps.fragment = nil
            guard let scheme = comps.scheme?.lowercased(), scheme == "http" || scheme == "https" else { continue }
            if sameDomainOnly, normalizedHost(comps.host) != baseHost { continue }

            let ext = (comps.path as NSString).pathExtension.lowercased()
            if !ext.isEmpty, Self.skippedExtensions.contains(ext) { continue }

            guard let clean = comps.url else { continue }
            let key = clean.absoluteString
            if seen.insert(key).inserted {
                links.append(clean)
            }
        }
        return links
    }

    private func normalizedHost(_ host: String?) -> String {
        var h = (host ?? "").lowercased()
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return h
    }

    private func replace(in text: String, pattern: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return text }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: replacement)
    }

    private func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              match.range(at: 1).location != NSNotFound else { return nil }
        return ns.substring(with: match.range(at: 1))
    }

    private func decodeEntities(_ text: String) -> String {
        var out = text
        let entities: [(String, String)] = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
            ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " "), ("&mdash;", "—"),
            ("&ndash;", "–"), ("&hellip;", "…"), ("&rsquo;", "'"), ("&lsquo;", "'"),
            ("&rdquo;", "\u{201D}"), ("&ldquo;", "\u{201C}"), ("&copy;", "©"),
        ]
        for (entity, char) in entities {
            out = out.replacingOccurrences(of: entity, with: char)
        }
        return out
    }

    private func collapse(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
