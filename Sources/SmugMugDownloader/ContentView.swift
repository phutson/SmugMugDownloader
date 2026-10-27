import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            accountBox
            destinationBox
            actionRow
            statusBox
            logBox
        }
        .padding(20)
        .alert(
            "SmugMug Downloader",
            isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } }),
            actions: { Button("OK") {} },
            message: { Text(model.errorMessage ?? "") })
    }

    // MARK: Inputs

    private var accountBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                switch model.phase {
                case .signedOut:
                    Grid(alignment: .leading, verticalSpacing: 8) {
                        GridRow {
                            Text("API key").gridColumnAlignment(.trailing)
                            TextField("", text: $model.apiKey).textFieldStyle(.roundedBorder)
                        }
                        GridRow {
                            Text("API secret")
                            SecureField("", text: $model.apiSecret).textFieldStyle(.roundedBorder)
                        }
                    }
                    HStack {
                        Link("Get an API key from SmugMug",
                             destination: URL(string: "https://api.smugmug.com/api/developer/apply")!)
                            .font(.callout)
                        Spacer()
                        if model.isBusy { ProgressView().controlSize(.small) }
                        Button("Sign In with SmugMug…") { model.startSignIn() }
                            .disabled(model.isBusy)
                    }
                case .awaitingCode:
                    Text("Log in and approve access in your browser, then enter the 6-digit code SmugMug shows you.")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        TextField("Code", text: $model.verifier)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 140)
                            .onSubmit { model.finishSignIn() }
                        Button("Verify") { model.finishSignIn() }
                            .disabled(model.verifier.isEmpty || model.isBusy)
                        Button("Cancel") { model.cancelSignIn() }
                        if model.isBusy { ProgressView().controlSize(.small) }
                    }
                case .signedIn:
                    HStack {
                        Label(model.userName.isEmpty ? "Signed in" : "Signed in as \(model.userName)",
                              systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Spacer()
                        Button("Sign Out") { model.signOut() }
                            .disabled(model.isDownloading)
                    }
                }
            }
            .padding(6)
        } label: {
            Text("SmugMug Account").font(.headline)
        }
    }

    private var destinationBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "folder")
                    Text(model.destination?.path ?? "No folder chosen")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(model.destination == nil ? .secondary : .primary)
                    Spacer()
                    Button("Choose…") { model.chooseDestination() }
                        .disabled(model.isDownloading)
                }
                Toggle("Include videos", isOn: $model.includeVideos)
                    .disabled(model.isDownloading)
            }
            .padding(6)
        } label: {
            Text("Download Folder").font(.headline)
        }
    }

    private var actionRow: some View {
        HStack {
            Spacer()
            if model.isDownloading {
                Button("Cancel") { model.cancelDownload() }
                    .controlSize(.large)
            } else {
                Button("Download Everything") { model.startDownload() }
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canStartDownload)
            }
        }
    }

    // MARK: Status

    private var statusBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(statusTitle).font(.title3.weight(.semibold))
                    Spacer()
                    if model.runState == .downloading || model.runState == .finished || model.runState == .cancelled {
                        Text(percentText)
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .monospacedDigit()
                    }
                }

                switch model.runState {
                case .idle:
                    Text(model.canStartDownload
                         ? "Ready. Click Download Everything to start."
                         : "Sign in and choose a download folder to begin.")
                        .foregroundStyle(.secondary)
                case .scanning:
                    ProgressView()
                        .progressViewStyle(.linear)
                    Text("Found \(model.stats.imagesFound.formatted()) images in \(model.stats.albums.formatted()) albums so far")
                        .monospacedDigit()
                default:
                    ProgressView(value: model.stats.fraction)
                        .progressViewStyle(.linear)
                    HStack {
                        statTile("Left to download", model.stats.remaining)
                        statTile("Downloaded", model.stats.downloaded)
                        statTile("To download", model.stats.toDownload)
                        statTile("Already on disk", model.stats.alreadyPresent)
                        statTile("Failed", model.stats.failed, highlight: model.stats.failed > 0)
                    }
                }

                if !model.currentItem.isEmpty {
                    Text(model.currentItem)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(6)
        } label: {
            Text("Status").font(.headline)
        }
    }

    private var statusTitle: String {
        switch model.runState {
        case .idle: return "Not started"
        case .scanning: return "Scanning your SmugMug albums…"
        case .downloading: return "Downloading…"
        case .finished: return model.stats.failed > 0 ? "Finished with errors" : "Finished"
        case .cancelled: return "Cancelled"
        case .stopped: return "Stopped"
        }
    }

    private var percentText: String {
        if model.runState == .finished && model.stats.toDownload == 0 { return "100%" }
        return "\(Int((model.stats.fraction * 100).rounded(.down)))%"
    }

    private func statTile(_ title: String, _ value: Int, highlight: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value.formatted())
                .font(.title3.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(highlight ? .red : .primary)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Log

    private var logBox: some View {
        GroupBox {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(model.log) { line in
                            Text(line.text)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .id(line.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }
                .frame(minHeight: 100)
                .onChange(of: model.log.last?.id) { id in
                    if let id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
        } label: {
            Text("Log").font(.headline)
        }
    }
}
