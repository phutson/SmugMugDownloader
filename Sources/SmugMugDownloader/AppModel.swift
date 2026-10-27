import AppKit
import Foundation

@MainActor
final class AppModel: ObservableObject {
    enum Phase { case signedOut, awaitingCode, signedIn }

    enum RunState { case idle, scanning, downloading, finished, cancelled, stopped }

    struct Stats {
        var albums = 0
        var imagesFound = 0
        var alreadyPresent = 0
        var toDownload = 0
        var downloaded = 0
        var failed = 0

        var processed: Int { downloaded + failed }
        var remaining: Int { max(toDownload - processed, 0) }
        /// Downloaded (or attempted) vs. to be downloaded, 0...1.
        var fraction: Double { toDownload == 0 ? 0 : Double(processed) / Double(toDownload) }
    }

    struct LogLine: Identifiable {
        let id = UUID()
        let text: String
    }

    @Published var apiKey = ""
    @Published var apiSecret = ""
    @Published var verifier = ""
    @Published var phase: Phase = .signedOut
    @Published var userName = ""
    @Published var destination: URL?
    @Published var includeVideos = true
    @Published var isBusy = false
    @Published var runState: RunState = .idle
    @Published var currentItem = ""
    @Published var stats = Stats()
    @Published var log: [LogLine] = []
    @Published var errorMessage: String?

    private var credentials: OAuthCredentials?
    private var requestToken: (token: String, secret: String)?
    private var downloadTask: Task<Void, Never>?
    private static let destinationKey = "destinationPath"

    init() {
        if let path = UserDefaults.standard.string(forKey: Self.destinationKey) {
            destination = URL(fileURLWithPath: path, isDirectory: true)
        }
        if let saved = Keychain.load() {
            apiKey = saved.consumerKey
            apiSecret = saved.consumerSecret
            if saved.token != nil {
                credentials = saved
                phase = .signedIn
                loadUser()
            }
        }
    }

    // MARK: Sign-in

    func startSignIn() {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = apiSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !secret.isEmpty else {
            errorMessage = "Enter your SmugMug API key and secret first."
            return
        }
        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                let token = try await SmugMugClient.requestToken(consumerKey: key, consumerSecret: secret)
                requestToken = token
                verifier = ""
                phase = .awaitingCode
                NSWorkspace.shared.open(SmugMugClient.authorizeURL(requestToken: token.token))
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func finishSignIn() {
        guard let requestToken else { phase = .signedOut; return }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = apiSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = verifier.trimmingCharacters(in: .whitespacesAndNewlines)
        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                let access = try await SmugMugClient.accessToken(
                    consumerKey: key, consumerSecret: secret,
                    requestToken: requestToken.token, requestSecret: requestToken.secret, verifier: code)
                let creds = OAuthCredentials(
                    consumerKey: key, consumerSecret: secret, token: access.token, tokenSecret: access.secret)
                Keychain.save(creds)
                credentials = creds
                self.requestToken = nil
                phase = .signedIn
                loadUser()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func cancelSignIn() {
        requestToken = nil
        phase = .signedOut
    }

    func signOut() {
        cancelDownload()
        credentials = nil
        userName = ""
        phase = .signedOut
        // Keep the API key/secret so signing in again is one click.
        Keychain.save(OAuthCredentials(consumerKey: apiKey, consumerSecret: apiSecret))
    }

    private func loadUser() {
        guard let credentials else { return }
        let client = SmugMugClient(credentials: credentials)
        Task {
            do {
                let user = try await client.get("/api/v2!authuser", as: UserResponse.self).user
                userName = user.name.map { "\($0) (\(user.nickName))" } ?? user.nickName
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: Destination

    func chooseDestination() {
        let panel = NSOpenPanel()
        panel.title = "Choose a folder to download into"
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = destination
        if panel.runModal() == .OK, let url = panel.url {
            destination = url
            UserDefaults.standard.set(url.path, forKey: Self.destinationKey)
        }
    }

    // MARK: Download

    var isDownloading: Bool { runState == .scanning || runState == .downloading }

    var canStartDownload: Bool {
        phase == .signedIn && destination != nil && !isDownloading
    }

    func startDownload() {
        guard let destination, let credentials else { return }
        stats = Stats()
        log = []
        currentItem = ""
        runState = .scanning
        append("Downloading into \(destination.path)")

        let downloader = Downloader(
            client: SmugMugClient(credentials: credentials),
            includeVideos: includeVideos,
            report: { [weak self] event in self?.handle(event) })

        downloadTask = Task {
            do {
                try await downloader.run(into: destination)
                runState = .finished
                append("Done. \(stats.downloaded) downloaded, \(stats.alreadyPresent) already on disk, \(stats.failed) failed.")
            } catch {
                if Task.isCancelled {
                    runState = .cancelled
                    append("Cancelled.")
                } else {
                    runState = .stopped
                    append("Stopped: \(error.localizedDescription)")
                    errorMessage = error.localizedDescription
                }
            }
            currentItem = ""
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
    }

    private func handle(_ event: DownloadEvent) {
        switch event {
        case .log(let text): append(text)
        case .albumScanned(let path, let images, let present):
            stats.albums += 1
            stats.imagesFound += images
            stats.alreadyPresent += present
            stats.toDownload += images - present
            currentItem = path
            append("Album: \(path) (\(images) images, \(images - present) to download)")
        case .scanFinished(let count):
            runState = .downloading
            append("Scan complete: \(count) images to download.")
        case .downloaded(let path):
            stats.downloaded += 1
            currentItem = path
        case .failed(let message):
            stats.failed += 1
            append("Failed: \(message)")
        }
    }

    private func append(_ text: String) {
        log.append(LogLine(text: text))
        if log.count > 1000 { log.removeFirst(log.count - 1000) }
    }
}
