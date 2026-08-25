import Foundation
import WebKit

struct ProfileScrapeResult: Sendable {
    let handle: String
    let platform: String
    let postCount: Int
    let mdURL: URL
    let scrapedAt: Date
}

@MainActor
final class ProfileScraper: NSObject {
    private let log: LogSink
    private let maxScrolls = 200
    private let scrollWait: UInt64 = 2_500_000_000
    private let initialRenderWait: UInt64 = 4_000_000_000

    private var webView: WKWebView?
    private var hiddenWindow: NSWindow?

    // Stealth scraper configuration
    var useStealthForThreads: Bool = true
    var stealthMaxPosts: Int = 50
    var stealthHeadless: Bool = true
    var stealthProxy: String?
    var stealthUserDataDir: String?

    init(log: LogSink) {
        self.log = log
        super.init()
    }

    // MARK: - Stealth Threads Scraping

    private func scrapeThreadsWithStealth(handle: String, sourceURL: String) async throws -> [String] {
        log.emit(.info, "scraper", "starting stealth threads scrape for @\(handle)")

        // Find python and script path
        let pythonPath = findPython()
        let scriptPath = findStealthScript()

        var arguments = [
            scriptPath,
            handle,
            "--max-posts", String(stealthMaxPosts),
        ]

        if stealthHeadless {
            arguments.append("--headless")
        } else {
            arguments.append("--no-headless")
        }

        if let proxy = stealthProxy {
            arguments.append(contentsOf: ["--proxy", proxy])
        }

        if let userDataDir = stealthUserDataDir {
            arguments.append(contentsOf: ["--user-data-dir", userDataDir])
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()

            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

            if process.terminationStatus != 0 {
                let error = String(data: errorData, encoding: .utf8) ?? "unknown error"
                log.emit(.error, "scraper", "stealth scrape failed: \(error)")
                throw ScraperError.stealthFailed(error)
            }

            guard let output = String(data: outputData, encoding: .utf8),
                  let json = try JSONSerialization.jsonObject(with: outputData) as? [String: Any] else {
                log.emit(.error, "scraper", "stealth scrape: invalid JSON output")
                throw ScraperError.stealthFailed("invalid JSON output")
            }

            if let error = json["error"] as? String {
                log.emit(.error, "scraper", "stealth scrape error: \(error)")
                throw ScraperError.stealthFailed(error)
            }

            guard let posts = json["posts"] as? [String] else {
                log.emit(.warn, "scraper", "stealth scrape returned no posts")
                return []
            }

            log.emit(.success, "scraper", "stealth scrape complete — \(posts.count) posts extracted")
            return posts

        } catch let error as ScraperError {
            throw error
        } catch {
            log.emit(.error, "scraper", "stealth scrape exception: \(error)")
            throw ScraperError.stealthFailed(error.localizedDescription)
        }
    }

    private func findPython() -> String {
        let candidates = [
            "/usr/bin/python3",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/Library/Developer/CommandLineTools/usr/bin/python3",
        ]
        for path in candidates {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        // Fallback to which python3
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        task.arguments = ["python3"]
        let pipe = Pipe()
        task.standardOutput = pipe
        try? task.run()
        task.waitUntilExit()
        if let path = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty {
            return path
        }
        return "/usr/bin/python3"
    }

    private func findStealthScript() -> String {
        // Look for the stealth_cli.py in the app bundle resources
        if let path = Bundle.module.path(forResource: "stealth_cli", ofType: "py") {
            return path
        }
        // Development fallback paths
        let candidates = [
            "/Users/stevenjackson/Documents/github/knowledge-tree-alpha/src/knowledge_compiler/ingestion/stealth_cli.py",
            "/Users/stevenjackson/Documents/github/knowledge-tree-alpha/macos/Sources/KnowledgeCompiler/Resources/stealth_cli.py",
        ]
        for path in candidates {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        // Fallback: try to run as module (requires PYTHONPATH)
        return "-m knowledge_compiler.ingestion.stealth_cli"
    }

    enum ScraperError: Error, LocalizedError {
    case stealthFailed(String)
    case noPostsFound
    case platformUnsupported(String)

    var errorDescription: String? {
        switch self {
        case .stealthFailed(let msg): return "Stealth scrape failed: \(msg)"
        case .noPostsFound: return "No posts extracted"
        case .platformUnsupported(let p): return "Platform not supported: \(p)"
        }
    }
}

func scrape(url: URL) async throws -> ProfileScrapeResult {
    let host = url.host ?? ""
    let platform = detectPlatform(host: host)
    let handle = extractHandle(url: url, platform: platform)

    log.emit(.info, "scraper", "beginning profile scrape — @\(handle) on \(platform)")

    let posts: [String]
    if platform == "threads" && useStealthForThreads {
        posts = try await scrapeThreadsWithStealth(handle: handle, sourceURL: url.absoluteString)
    } else {
        posts = try await scrapePosts(url: url, platform: platform)
    }

    guard !posts.isEmpty else {
        throw ScraperError.noPostsFound
    }

    let reversed = Array(posts.reversed())

    let mdContent = generateMarkdown(handle: handle, platform: platform, sourceURL: url.absoluteString, posts: reversed)
    let mdURL = try saveMarkdown(content: mdContent, handle: handle, platform: platform)

    log.emit(.success, "scraper", "profile scrape complete — \(reversed.count) posts → \(mdURL.lastPathComponent)")

    return ProfileScrapeResult(
        handle: handle,
        platform: platform,
        postCount: reversed.count,
        mdURL: mdURL,
        scrapedAt: Date()
    )
}

    func teardown() {
        webView?.stopLoading()
        webView = nil
        hiddenWindow?.close()
        hiddenWindow = nil
    }

    // MARK: - Auth session

    func openThreadsLogin() {
        let loginWin = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 480, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        loginWin.title = "login to threads"
        loginWin.isReleasedWhenClosed = true
        loginWin.center()

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let loginWV = WKWebView(frame: .zero, configuration: config)
        loginWV.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

        loginWin.contentView = loginWV
        loginWin.makeKeyAndOrderFront(nil)

        guard let loginURL = URL(string: "https://www.threads.net/login") else {
            log.emit(.error, "scraper", "failed to construct threads login url")
            loginWin.close()
            return
        }
        loginWV.load(URLRequest(url: loginURL))

        log.emit(.info, "scraper", "threads login window opened — log in then close the window")
    }

    static func hasThreadsCookies() async -> Bool {
        await withCheckedContinuation { continuation in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                let found = cookies.contains { cookie in
                    cookie.domain.contains("threads.net") || cookie.domain.contains("instagram.com")
                        || cookie.domain.contains("facebook.com")
                }
                continuation.resume(returning: found)
            }
        }
    }

    // MARK: - Platform detection

    private func detectPlatform(host: String) -> String {
        let lower = host.lowercased()
        if lower.contains("threads.net") { return "threads" }
        if lower.contains("twitter.com") || lower.contains("x.com") { return "x" }
        if lower.contains("nitter") { return "nitter" }
        if lower.contains("github.com") { return "github" }
        if lower.contains("reddit.com") { return "reddit" }
        return host
    }

    private func extractHandle(url: URL, platform: String) -> String {
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.isEmpty { return url.host ?? "unknown" }
        if path.hasPrefix("@") { return String(path.dropFirst()) }
        if let first = path.split(separator: "/").first { return String(first) }
        return path
    }

    // MARK: - Headless scraping

    private func scrapePosts(url: URL, platform: String) async throws -> [String] {
        let win = NSWindow(
            contentRect: NSRect(x: -4000, y: -4000, width: 1200, height: 900),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.isOpaque = false
        win.backgroundColor = .clear
        win.isReleasedWhenClosed = true
        win.orderOut(nil)
        hiddenWindow = win

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs

        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 1200, height: 900), configuration: config)
        wv.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        webView = wv

        let delegate = ScrapeNavDelegate()
        wv.navigationDelegate = delegate

        win.contentView?.addSubview(wv)

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            delegate.onFinish = { cont.resume() }
            delegate.onError = { cont.resume(throwing: $0) }
            let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
            wv.load(request)
        }

        let sleepTask = Task { try? await Task.sleep(nanoseconds: initialRenderWait) }
        _ = await sleepTask.result

        let posts = await scrollAndExtract(webView: wv, platform: platform)

        teardown()
        return posts
    }

    // MARK: - Scroll loop

    private func scrollAndExtract(webView: WKWebView, platform: String) async -> [String] {
        var seen = Set<String>()
        var posts: [String] = []
        var noNewContentCount = 0
        let maxNoNewContent = 6

        for i in 1...maxScrolls {
            let js = extractionJS(platform: platform)
            guard let raw = try? await webView.evaluateJavaScript(js) as? [[String: Any]] else {
                log.emit(.warn, "scraper", "js evaluation failed at scroll \(i)")
                break
            }

            let before = posts.count
            for entry in raw {
                guard var text = entry["text"] as? String else { continue }
                text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard text.count > 10 else { continue }
                let key = String(text.prefix(120))
                if seen.insert(key).inserted {
                    posts.append(text)
                }
            }
            let added = posts.count - before
            log.emit(.info, "scraper", "scroll \(i): +\(added) posts (total \(posts.count))")

            _ = try? await webView.evaluateJavaScript("window.scrollTo(0, document.body.scrollHeight);")
            try? await Task.sleep(nanoseconds: scrollWait)

            let scrollY = (try? await webView.evaluateJavaScript("window.scrollY + window.innerHeight")) as? CGFloat ?? 0
            let bodyHeight = (try? await webView.evaluateJavaScript("document.body.scrollHeight")) as? CGFloat ?? 0

            if scrollY >= bodyHeight - 100 && added == 0 {
                noNewContentCount += 1
                if noNewContentCount >= maxNoNewContent {
                    log.emit(.info, "scraper", "bottom reached — no new posts after \(maxNoNewContent) scrolls")
                    break
                }
            } else {
                noNewContentCount = 0
            }
        }

        return posts
    }

    // MARK: - JS extraction

    private func extractionJS(platform: String) -> String {
        switch platform {
        case "threads":
            return """
            (function() {
                var results = [];
                var containers = document.querySelectorAll('div[role="article"], div[data-pressable-container], div[class*="x1lliihq"]');
                containers.forEach(function(el) {
                    var fullText = (el.innerText || el.textContent || '').trim();
                    if (fullText.length < 10) return;
                    var isReply = false;
                    var replyTo = '';
                    var replyEls = el.querySelectorAll('a[href*="/@"], span[class*="x1n2onr6"], a[class*="x1i10hfl"]');
                    replyEls.forEach(function(r) {
                        var t = (r.innerText || r.textContent || '').trim();
                        if (t.startsWith('@') && t.length > 1 && t.length < 40) {
                            isReply = true;
                            replyTo = t;
                        }
                    });
                    var spans = el.querySelectorAll('span');
                    var textParts = [];
                    spans.forEach(function(s) {
                        var txt = (s.innerText || s.textContent || '').trim();
                        if (txt.length > 3) textParts.push(txt);
                    });
                    var bodyText = textParts.join(' ');
                    if (bodyText.length < 8) bodyText = fullText;
                    if (isReply && replyTo) {
                        bodyText = '[reply to ' + replyTo + '] ' + bodyText;
                    }
                    results.push({ text: bodyText });
                });
                return results;
            })();
            """
        case "x", "nitter":
            return """
            (function() {
                var results = [];
                var containers = document.querySelectorAll('div.tweet-content, div.tweet-text, article div[lang], div[data-testid="tweetText"]');
                containers.forEach(function(el) {
                    var text = (el.innerText || el.textContent || '').trim();
                    text = text.replace(/\\s+/g, ' ').trim();
                    if (text.length > 10) results.push({ text: text });
                });
                return results;
            })();
            """
        case "github":
            return """
            (function() {
                var results = [];
                var containers = document.querySelectorAll('div.pinned-item-list-item-content, div[itemprop="description"], article.markdown-body');
                containers.forEach(function(el) {
                    var text = (el.innerText || el.textContent || '').trim();
                    text = text.replace(/\\s+/g, ' ').trim();
                    if (text.length > 10) results.push({ text: text });
                });
                return results;
            })();
            """
        case "reddit":
            return """
            (function() {
                var results = [];
                var containers = document.querySelectorAll('div.md, div[data-testid="comment"], div[class*="text-neutral-content"]');
                containers.forEach(function(el) {
                    var text = (el.innerText || el.textContent || '').trim();
                    text = text.replace(/\\s+/g, ' ').trim();
                    if (text.length > 10) results.push({ text: text });
                });
                return results;
            })();
            """
        default:
            return """
            (function() {
                var results = [];
                var containers = document.querySelectorAll('article, div.post, div[class*="post-"], div[class*="tweet"], div[class*="content"]');
                containers.forEach(function(el) {
                    var text = (el.innerText || el.textContent || '').trim();
                    text = text.replace(/\\s+/g, ' ').trim();
                    if (text.length > 10) results.push({ text: text });
                });
                return results;
            })();
            """
        }
    }

    // MARK: - Markdown generation

    private func generateMarkdown(handle: String, platform: String, sourceURL: String, posts: [String]) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        let dateStr = formatter.string(from: Date())

        let replies = posts.filter { $0.hasPrefix("[reply to") }
        let threads = posts.filter { !$0.hasPrefix("[reply to") }

        var md = ""
        md += "# @\(handle) on \(platform)\n\n"
        md += "**Source:** \(sourceURL)  \n"
        md += "**Total posts:** \(posts.count) (\(threads.count) threads, \(replies.count) replies)  \n"
        md += "**Scraped:** \(dateStr)  \n"
        md += "**Order:** chronological (oldest → newest)  \n\n"
        md += "---\n\n"

        for (index, post) in posts.enumerated() {
            let isReply = post.hasPrefix("[reply to")
            let typeLabel = isReply ? "Reply" : "Thread"
            md += "## \(typeLabel) \(index + 1)\n\n"
            md += "\(post)\n\n"
            md += "---\n\n"
        }

        return md
    }

    // MARK: - File persistence

    static var scrapesDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KnowledgeCompiler/profile_scrapes", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func saveMarkdown(content: String, handle: String, platform: String) throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmm"
        let timestamp = formatter.string(from: Date())
        let filename = "\(handle)_\(platform)_\(timestamp).md"
        let url = Self.scrapesDirectory.appendingPathComponent(filename)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func listSavedScrapes() -> [(url: URL, date: Date, handle: String, platform: String)] {
        let dir = scrapesDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return []
        }
        return files
            .filter { $0.pathExtension == "md" }
            .compactMap { url -> (URL, Date, String, String)? in
                guard let attrs = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                      let date = attrs.contentModificationDate else { return nil }
                let name = url.deletingPathExtension().lastPathComponent
                let parts = name.split(separator: "_")
                if parts.count >= 3 {
                    let handle = parts.dropLast(2).joined(separator: "_")
                    let platform = String(parts[parts.count - 2])
                    return (url, date, handle, platform)
                }
                return (url, date, name, "unknown")
            }
            .sorted { $0.1 > $1.1 }
    }
}

// MARK: - Navigation delegate

private final class ScrapeNavDelegate: NSObject, WKNavigationDelegate {
    var onFinish: (() -> Void)?
    var onError: ((Error) -> Void)?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onFinish?()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
        onError?(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
        onError?(error)
    }
}
