import Foundation

protocol OllamaClient: Sendable {
    func generate(model: String, prompt: String, timeout: TimeInterval) async throws -> String
    func tags() async throws -> [String]
}

struct OllamaGenerateRequest: Encodable {
    let model: String
    let prompt: String
    let stream: Bool
}

struct OllamaGenerateResponse: Decodable {
    let response: String
}

struct OllamaTagsResponse: Decodable {
    struct Model: Decodable { let name: String }
    let models: [Model]
}

final class OllamaService: OllamaClient, @unchecked Sendable {
    let baseURL: URL
    let session: URLSession

    init(baseURL: URL = URL(string: "http://localhost:11434")!, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    func generate(model: String, prompt: String, timeout: TimeInterval) async throws -> String {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/generate"))
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(
            OllamaGenerateRequest(model: model, prompt: prompt, stream: false)
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group in
                group.addTask { try await self.session.data(for: req) }
                group.addTask {
                    try await Task.sleep(for: .seconds(timeout))
                    throw SayMooreError.cleanupTimedOut
                }
                let result = try await group.next()!
                group.cancelAll()
                return result
            }
        } catch let urlErr as URLError {
            throw Self.mapURLError(urlErr)
        } catch let smErr as SayMooreError {
            throw smErr
        } catch {
            throw SayMooreError.cleanupFailed(underlying: error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw SayMooreError.cleanupFailed(underlying: URLError(.badServerResponse))
        }
        if http.statusCode == 404 {
            throw SayMooreError.ollamaModelNotPulled
        }
        guard (200..<300).contains(http.statusCode) else {
            let underlying = NSError(
                domain: "OllamaService",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"]
            )
            throw SayMooreError.cleanupFailed(underlying: underlying)
        }

        do {
            let decoded = try JSONDecoder().decode(OllamaGenerateResponse.self, from: data)
            return decoded.response
        } catch {
            throw SayMooreError.cleanupFailed(underlying: error)
        }
    }

    func tags() async throws -> [String] {
        let req = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group in
                group.addTask { try await self.session.data(for: req) }
                group.addTask {
                    try await Task.sleep(for: .seconds(3))
                    throw SayMooreError.ollamaUnreachable
                }
                let result = try await group.next()!
                group.cancelAll()
                return result
            }
        } catch let smErr as SayMooreError {
            throw smErr
        } catch let urlErr as URLError {
            throw Self.mapURLError(urlErr)
        } catch {
            throw SayMooreError.ollamaUnreachable
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SayMooreError.ollamaUnreachable
        }
        do {
            let decoded = try JSONDecoder().decode(OllamaTagsResponse.self, from: data)
            return decoded.models.map { $0.name }
        } catch {
            throw SayMooreError.cleanupFailed(underlying: error)
        }
    }

    static func mapURLError(_ err: URLError) -> SayMooreError {
        switch err.code {
        case .timedOut:
            return .cleanupTimedOut
        case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet:
            return .ollamaUnreachable
        default:
            return .cleanupFailed(underlying: err)
        }
    }
}
