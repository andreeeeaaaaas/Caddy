import Foundation

/// A problem report from Help › Report an issue…, sent to the issue relay
/// (`relay/` in the repo), which files it as a GitHub issue so reporters need
/// no GitHub account. The relay's address and optional key are
/// `CaddyReportURL` and `CaddyReportKey` in Info.plist.
nonisolated struct IssueReport: Codable, Sendable {
    /// What's sent along with every report. Never the scripts or videos.
    struct System: Codable, Sendable {
        var version: String
        var build: String
        var os: String
        var model: String

        static var current: System {
            let info = Bundle.main.infoDictionary ?? [:]
            let os = ProcessInfo.processInfo.operatingSystemVersion
            return System(version: info["CFBundleShortVersionString"] as? String ?? "?",
                          build: info["CFBundleVersion"] as? String ?? "?",
                          os: "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
                          model: hardwareModel)
        }

        var summary: String { "Caddy \(version) (\(build)), \(os), \(model)" }

        /// The Mac's model identifier, such as Mac16,1.
        private static var hardwareModel: String {
            var size = 0
            guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "Mac" }
            var bytes = [UInt8](repeating: 0, count: size)
            guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return "Mac" }
            return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    enum Failure: LocalizedError {
        case notSetUp
        case refused(String)

        var errorDescription: String? {
            switch self {
            case .notSetUp: "This build can’t send reports yet. Copy the report and email it instead."
            case .refused(let reason): "The report couldn’t be sent. \(reason)"
            }
        }
    }

    var title: String
    var description: String
    var contact: String
    var system = System.current

    /// The report as plain text, for copying when it can't be sent.
    var plainText: String {
        """
        \(title)

        \(description)

        Reported by: \(contact.isEmpty ? "Not given" : contact)
        \(system.summary)
        """
    }

    static var isSetUp: Bool { endpoint != nil }

    private static var endpoint: URL? {
        guard let address = Bundle.main.object(forInfoDictionaryKey: "CaddyReportURL") as? String,
              !address.isEmpty else { return nil }
        return URL(string: address)
    }

    /// Sends the report and returns the new issue's number.
    @concurrent func send() async throws -> Int {
        guard let endpoint = Self.endpoint else { throw Failure.notSetUp }
        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = Bundle.main.object(forInfoDictionaryKey: "CaddyReportKey") as? String, !key.isEmpty {
            request.setValue(key, forHTTPHeaderField: "X-Caddy-Key")
        }
        request.httpBody = try JSONEncoder().encode(self)

        let (data, response) = try await URLSession.shared.data(for: request)
        struct Reply: Decodable {
            var number: Int?
            var error: String?
        }
        let reply = try? JSONDecoder().decode(Reply.self, from: data)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let number = reply?.number else {
            throw Failure.refused(reply?.error ?? "Try again in a minute.")
        }
        return number
    }
}
