import Foundation

private struct ReleaseVersion: Comparable {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ text: Substring) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count),
              parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }),
              let major = Int(parts[0]), let minor = Int(parts[1]),
              let patch = parts.count == 3 ? Int(parts[2]) : 0 else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

struct GitHubRelease: Decodable {
    let tag: String

    private enum CodingKeys: String, CodingKey { case tag = "tag_name" }

    var version: Substring { tag.first == "v" ? tag.dropFirst() : tag[...] }
    var url: URL { URL(string: "https://github.com/yz778/wheresmymouse/releases/tag/")!.appendingPathComponent(tag) }
}

enum UpdateChecker {
    private static let endpoint = URL(string: "https://api.github.com/repos/yz778/wheresmymouse/releases/latest")!

    static func newerRelease(installedVersion: String) async throws -> GitHubRelease? {
        var request = URLRequest(url: endpoint, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try newerRelease(in: data, installedVersion: installedVersion)
    }

    static func newerRelease(in data: Data, installedVersion: String) throws -> GitHubRelease? {
        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard let installed = ReleaseVersion(installedVersion[...]), let latest = ReleaseVersion(release.version) else {
            throw URLError(.cannotParseResponse)
        }
        return latest > installed ? release : nil
    }
}
