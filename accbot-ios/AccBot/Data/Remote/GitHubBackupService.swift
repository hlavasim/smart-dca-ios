import Foundation

/// Záloha snapshot.json do private repa přes GitHub Contents API (potvrzený push = commit SHA).
final class GitHubBackupService {
    private let client: NetworkClient
    private let tokenStore: TokenStore
    private let repo = "hlavasim/smart-dca-data"
    private let path = "snapshot.json"

    init(client: NetworkClient, tokenStore: TokenStore) {
        self.client = client
        self.tokenStore = tokenStore
    }

    private var authHeaders: [String: String]? {
        guard let token = tokenStore.get() else { return nil }
        return [
            "Authorization": "Bearer \(token)",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
        ]
    }

    private var contentsUrl: String { contentsUrl(for: path) }
    private func contentsUrl(for path: String) -> String {
        "https://api.github.com/repos/\(repo)/contents/\(path)"
    }

    /// Vrátí (content, sha) snapshot.json — zkratka pro fetch(path:).
    func fetch() async -> (json: Data, sha: String)? { await fetch(path: path) }

    /// Vrátí (content, sha) libovolného souboru z repa (finance-baseline.json, standing-orders.json…),
    /// nebo nil když soubor neexistuje / chybí token.
    func fetch(path: String) async -> (json: Data, sha: String)? {
        guard let headers = authHeaders else { return nil }
        do {
            let (data, _) = try await client.get(url: contentsUrl(for: path), headers: headers)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let b64 = (json["content"] as? String)?.replacingOccurrences(of: "\n", with: ""),
                  let sha = json["sha"] as? String,
                  let decoded = Data(base64Encoded: b64) else { return nil }
            return (decoded, sha)
        } catch {
            return nil
        }
    }

    /// Push snapshot. Vrací commit SHA při úspěchu, nil při selhání/chybě tokenu.
    @discardableResult
    func push(_ snapshotJson: Data, message: String) async -> String? {
        guard let headers = authHeaders else { return nil }
        let existingSha = await fetch()?.sha
        var body: [String: Any] = [
            "message": message,
            "content": snapshotJson.base64EncodedString(),
        ]
        if let existingSha { body["sha"] = existingSha }
        do {
            let (data, _) = try await client.put(url: contentsUrl, body: body, headers: headers)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            return (json?["commit"] as? [String: Any])?["sha"] as? String
        } catch {
            return nil
        }
    }
}
