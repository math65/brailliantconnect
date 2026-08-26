import Foundation

/// HTTP client for the shared app backend (https://mathieumartin.ovh).
///
/// Two things live there: the feedback endpoints — error reports and contact
/// messages — and the launch announcements. The full contract is in the
/// app-backend repository, `docs/API.md`.
///
/// The Bearer secret is **not committed**: this repository is public, so it is
/// loaded from `AppBackendSecret.plist`, which is git-ignored and bundled at
/// build time. A build without that file reports `isConfigured == false`, and
/// everything that depends on the backend simply stays out of the menu. That is
/// deliberate: a contributor who clones the repository gets a working app, not
/// a build error and not a menu item that fails when pressed.
///
/// The secret is an app identifier and an anti-spam gate, not a credential —
/// it protects nothing that belongs to the user, and it grants nothing beyond
/// posting to these three routes as this app.
///
/// Only the agent compiles this file. The extension is sandboxed and parses
/// what the device sends; giving it a network client as well would widen the
/// one surface this project keeps deliberately narrow.
final class AppBackendClient {

    /// Registered in the backend's `config/apps.json`.
    static let appID = "brailliantconnect"

    private static let baseURL = URL(string: "https://mathieumartin.ovh")!

    /// Raw values are the server-side `contact_type` values.
    ///
    /// Never shown to anyone: what the window offers is `Feedback.Subject`,
    /// which names symptoms rather than categories and maps onto these.
    enum ContactType: String {
        case bug
        case suggestion
        case question
        case other
    }

    enum BackendError: Error {
        case notConfigured
        case network
        case rateLimited
        case validation
        case server

        var message: String {
            switch self {
            case .notConfigured:
                return L.t("This version of the app can't send messages.")
            case .network:
                return L.t("Unable to send the message. Check your internet connection.")
            case .rateLimited:
                return L.t("Too many messages sent. Try again in a few minutes.")
            case .validation:
                return L.t(
                    "The email address or message wasn't accepted. Check them, then try again.")
            case .server:
                return L.t("The server didn't accept the message. Try again later.")
            }
        }
    }

    /// One section of a report email, in the backend's ordered-array form
    /// (`type: "kv"`). The order of the sections is reproduced as-is in the
    /// email, and a Swift dictionary has none — arrays preserve it at both
    /// levels, which is why the array form exists at all.
    struct ReportSection {
        let title: String
        let rows: [(label: String, value: String)]

        var jsonObject: [String: Any] {
            [
                "title": title,
                "type": "kv",
                "rows": rows.map { ["label": $0.label, "value": $0.value] },
            ]
        }
    }

    struct Announcement: Decodable {
        let id: String
        let title: String
        let body: String
        let style: String
        let mode: String
        /// Optional secondary "link" button. Non-nil only when the announcement
        /// carries one; `label` arrives already translated.
        let link: Link?

        struct Link: Decodable {
            let label: String
            let url: String
        }
    }

    private static let bearerSecret: String? = {
        guard let url = Bundle.main.url(forResource: "AppBackendSecret", withExtension: "plist"),
            let data = try? Data(contentsOf: url),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any],
            let secret = plist["BearerSecret"] as? String,
            !secret.isEmpty
        else {
            return nil
        }
        return secret
    }()

    static var isConfigured: Bool { bearerSecret != nil }

    /// `Version.current` is not available here: the agent compiles two files
    /// out of BrailliantKit, and that is not one of them. The bundle carries
    /// the same number, written by the Xcode project.
    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    /// Ephemeral: nothing about these requests is worth writing to disk.
    private let session = URLSession(configuration: .ephemeral)

    // MARK: - Feedback

    func sendContact(
        email: String,
        type: ContactType,
        message: String,
        completion: @escaping (Result<Void, BackendError>) -> Void
    ) {
        let body: [String: Any] = [
            "app": Self.appID,
            "email": email,
            "contact_type": type.rawValue,
            "message": message,
            "app_version": Self.appVersion,
        ]
        guard var request = makeRequest(path: "/api/feedback/contact"),
            let data = try? JSONSerialization.data(withJSONObject: body)
        else {
            DispatchQueue.main.async { completion(.failure(.notConfigured)) }
            return
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        perform(request, completion: completion)
    }

    func sendReport(
        email: String,
        summary: String,
        subjectHint: String,
        sections: [ReportSection],
        logFile: (name: String, data: Data)?,
        completion: @escaping (Result<Void, BackendError>) -> Void
    ) {
        let report: [String: Any] = [
            "app": Self.appID,
            "email": email,
            "summary": summary,
            "subject_hint": subjectHint,
            "sections": sections.map(\.jsonObject),
        ]
        guard var request = makeRequest(path: "/api/feedback/report"),
            let reportData = try? JSONSerialization.data(withJSONObject: report)
        else {
            DispatchQueue.main.async { completion(.failure(.notConfigured)) }
            return
        }
        let boundary = "brailliantconnect-" + UUID().uuidString
        request.setValue(
            "multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = multipartBody(
            boundary: boundary, reportJSON: reportData, logFile: logFile)
        perform(request, completion: completion)
    }

    // MARK: - Announcements

    func checkAnnouncement(
        installID: String,
        language: String,
        completion: @escaping (Result<Announcement?, BackendError>) -> Void
    ) {
        let body: [String: Any] = [
            "app": Self.appID,
            "install_id": installID,
            "lang": language,
        ]
        guard var request = makeRequest(path: "/api/announce/check"),
            let data = try? JSONSerialization.data(withJSONObject: body)
        else {
            DispatchQueue.main.async { completion(.failure(.notConfigured)) }
            return
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data

        session.dataTask(with: request) { data, response, error in
            let result: Result<Announcement?, BackendError>
            if error != nil {
                result = .failure(.network)
            } else if let http = response as? HTTPURLResponse, http.statusCode == 200,
                let data,
                let decoded = try? JSONDecoder().decode(CheckResponse.self, from: data),
                decoded.ok
            {
                result = .success(decoded.announcement)
            } else {
                result = .failure(.server)
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    /// Fire and forget: says the announcement was actually put on screen.
    func acknowledgeAnnouncement(installID: String, announcementID: String) {
        postAnnouncementEvent(path: "/api/announce/ack", installID: installID, id: announcementID)
    }

    /// Fire and forget: says the user pressed the secondary link button.
    func reportAnnouncementClick(installID: String, announcementID: String) {
        postAnnouncementEvent(path: "/api/announce/click", installID: installID, id: announcementID)
    }

    // MARK: - Plumbing

    private struct CheckResponse: Decodable {
        let ok: Bool
        let announcement: Announcement?
    }

    private struct APIResponse: Decodable {
        let ok: Bool
        let errorCode: String?

        private enum CodingKeys: String, CodingKey {
            case ok
            case errorCode = "error_code"
        }
    }

    private func postAnnouncementEvent(path: String, installID: String, id: String) {
        let body: [String: Any] = ["app": Self.appID, "install_id": installID, "id": id]
        guard var request = makeRequest(path: path),
            let data = try? JSONSerialization.data(withJSONObject: body)
        else { return }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        session.dataTask(with: request).resume()
    }

    private func makeRequest(path: String) -> URLRequest? {
        guard let secret = Self.bearerSecret else { return nil }
        var request = URLRequest(url: Self.baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func perform(
        _ request: URLRequest, completion: @escaping (Result<Void, BackendError>) -> Void
    ) {
        session.dataTask(with: request) { data, response, error in
            let result: Result<Void, BackendError>
            if error != nil {
                result = .failure(.network)
            } else if let http = response as? HTTPURLResponse {
                if http.statusCode == 200 {
                    result = .success(())
                } else {
                    let decoded = data.flatMap {
                        try? JSONDecoder().decode(APIResponse.self, from: $0)
                    }
                    switch decoded?.errorCode {
                    case "rate_limited": result = .failure(.rateLimited)
                    case "validation_error", "invalid_json": result = .failure(.validation)
                    default: result = .failure(.server)
                    }
                }
            } else {
                result = .failure(.network)
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    private func multipartBody(
        boundary: String, reportJSON: Data, logFile: (name: String, data: Data)?
    ) -> Data {
        var body = Data()
        func append(_ string: String) { body.append(Data(string.utf8)) }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"report\"\r\n")
        append("Content-Type: application/json\r\n\r\n")
        body.append(reportJSON)
        append("\r\n")
        if let logFile {
            append("--\(boundary)\r\n")
            append(
                "Content-Disposition: form-data; name=\"log_file\"; filename=\"\(logFile.name)\"\r\n"
            )
            append("Content-Type: text/plain\r\n\r\n")
            body.append(logFile.data)
            append("\r\n")
        }
        append("--\(boundary)--\r\n")
        return body
    }
}
