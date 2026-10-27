import Foundation

enum DownloadEvent: Sendable {
    case log(String)
    case albumScanned(path: String, images: Int, alreadyPresent: Int)
    case scanFinished(toDownload: Int)
    case downloaded(String)
    case failed(String)
}

/// Mirrors the user's SmugMug folder/album tree under a local folder in two phases:
/// first it scans every album so the total is known, then it downloads whatever is missing.
/// Files already present with the same size are skipped, so an interrupted run can be resumed.
struct Downloader: Sendable {
    let client: SmugMugClient
    let includeVideos: Bool
    let maxConcurrentDownloads = 4
    let report: @MainActor @Sendable (DownloadEvent) -> Void

    private struct Job: Sendable {
        let source: String
        let destination: URL
    }

    func run(into root: URL) async throws {
        let user = try await client.get("/api/v2!authuser", as: UserResponse.self).user
        await report(.log("Signed in as \(user.name ?? user.nickName). Scanning folders and albums…"))
        let rootNode = try await client.get(user.uris.node.uri, as: NodeResponse.self).node
        let jobs = try await scan(rootNode, into: root, relativePath: "")
        await report(.scanFinished(toDownload: jobs.count))
        try await downloadAll(jobs)
    }

    // MARK: Phase 1: scan

    private func scan(_ node: Node, into directory: URL, relativePath: String) async throws -> [Job] {
        guard let childrenURI = node.uris.childNodes?.uri else { return [] }
        var jobs: [Job] = []
        var usedNames = Set<String>()
        var next: String? = childrenURI.appendingQuery("count=100")
        while let page = next {
            try Task.checkCancellation()
            let response = try await client.get(page, as: NodeListResponse.self)
            for child in response.nodes ?? [] {
                try Task.checkCancellation()
                let name = Self.uniqueName(Self.sanitize(child.name), used: &usedNames, hasExtension: false)
                let childDir = directory.appendingPathComponent(name, isDirectory: true)
                let childPath = relativePath.isEmpty ? name : "\(relativePath)/\(name)"
                if let album = child.uris.album {
                    jobs += try await scanAlbum(album.uri, into: childDir, relativePath: childPath)
                } else if child.type == "Folder" {
                    jobs += try await scan(child, into: childDir, relativePath: childPath)
                }
                // Other node types (e.g. Pages) contain no photos.
            }
            next = response.pages?.nextPage
        }
        return jobs
    }

    private func scanAlbum(_ albumURI: String, into directory: URL, relativePath: String) async throws -> [Job] {
        var jobs: [Job] = []
        var usedNames = Set<String>()
        var total = 0
        var present = 0
        var next: String? = "\(albumURI)!images".appendingQuery("count=100")
        while let page = next {
            try Task.checkCancellation()
            let response = try await client.get(page, as: AlbumImagesResponse.self)
            for image in response.images ?? [] {
                if image.isVideo == true && !includeVideos { continue }
                let name = Self.uniqueName(
                    Self.sanitize(image.fileName ?? image.imageKey), used: &usedNames, hasExtension: true)
                guard let source = image.archivedUri else {
                    await report(.log("Skipping \(relativePath)/\(name): no original available"))
                    continue
                }
                total += 1
                let destination = directory.appendingPathComponent(name)
                if Self.isAlreadyDownloaded(destination, expectedSize: image.archivedSize) {
                    present += 1
                } else {
                    jobs.append(Job(source: source, destination: destination))
                }
            }
            next = response.pages?.nextPage
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        await report(.albumScanned(path: relativePath, images: total, alreadyPresent: present))
        return jobs
    }

    private static func isAlreadyDownloaded(_ url: URL, expectedSize: Int64?) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return false }
        guard let expectedSize else { return true }
        return (attributes[.size] as? NSNumber)?.int64Value == expectedSize
    }

    // MARK: Phase 2: download

    private func downloadAll(_ jobs: [Job]) async throws {
        await withTaskGroup(of: Void.self) { group in
            var index = 0
            for _ in 0..<min(maxConcurrentDownloads, jobs.count) {
                let job = jobs[index]
                index += 1
                group.addTask { await download(job) }
            }
            while await group.next() != nil {
                if Task.isCancelled { group.cancelAll(); continue }
                if index < jobs.count {
                    let job = jobs[index]
                    index += 1
                    group.addTask { await download(job) }
                }
            }
        }
        try Task.checkCancellation()
    }

    private func download(_ job: Job) async {
        let fm = FileManager.default
        do {
            let temp = try await client.download(job.source)
            if fm.fileExists(atPath: job.destination.path) {
                try fm.removeItem(at: job.destination)
            }
            try fm.moveItem(at: temp, to: job.destination)
            await report(.downloaded(job.destination.path))
        } catch {
            if Task.isCancelled { return }
            await report(.failed("\(job.destination.path): \(error.localizedDescription)"))
        }
    }

    // MARK: Naming

    static func sanitize(_ name: String) -> String {
        var s = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix(".") { s.removeFirst() }
        return s.isEmpty ? "Untitled" : String(s.prefix(200))
    }

    /// Returns `name`, or `name (2)`, `name (3)`… if already used. Comparison is case-insensitive
    /// because the default macOS file system is.
    static func uniqueName(_ name: String, used: inout Set<String>, hasExtension: Bool) -> String {
        let ext = hasExtension ? (name as NSString).pathExtension : ""
        let stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        var candidate = name
        var n = 2
        while used.contains(candidate.lowercased()) {
            candidate = ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)"
            n += 1
        }
        used.insert(candidate.lowercased())
        return candidate
    }
}
