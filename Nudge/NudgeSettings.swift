import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct NudgeSettings: View {
    @ObservedObject var store: ReminderStore
    @Binding var appearance: NudgeAppearance
    let palette: NudgePalette

    @State private var exporting = false
    @State private var importing = false
    @State private var document = ReminderBackupDocument()
    @State private var pendingBackup: ReminderBackup?
    @State private var confirming = false
    @State private var message: String?

    private var versionLabel: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "Version \(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                NudgeHeading(eyebrow: "Make it yours", title: "Settings",
                             subtitle: "A good default makes all the difference.",
                             icon: "slider.horizontal.3", palette: palette)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Your usual, every time.").font(.headline)
                    Text("These defaults apply to new reminders. You can adjust them for each reminder.")
                        .font(.subheadline).foregroundStyle(palette.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(15)
                .nudgePanel(palette, fill: palette.sage)
                PreferenceFields(preferences: $store.defaults, palette: palette)
                VStack(alignment: .leading, spacing: 12) {
                    Label("APPEARANCE", systemImage: "moon")
                        .font(.caption.weight(.semibold)).tracking(0.8)
                    Picker("Appearance", selection: $appearance) {
                        ForEach(NudgeAppearance.allCases) { style in Text(style.rawValue).tag(style) }
                    }.pickerStyle(.segmented)
                }
                .padding(15).nudgePanel(palette)
                VStack(alignment: .leading, spacing: 12) {
                    Label("BACKUP", systemImage: "externaldrive").font(.caption.weight(.semibold))
                    Text("Save your reminders, including completed items, to a JSON file. Import adds missing reminders and keeps your existing ones. Previously deleted reminders are skipped. App defaults and appearance stay unchanged.")
                        .font(.footnote).foregroundStyle(palette.secondary)
                    Button("Export reminders") {
                        do {
                            document = ReminderBackupDocument(data: try store.exportBackup())
                            exporting = true
                        } catch { message = "Could not export your reminders. Check the storage message and try again." }
                    }
                    Button("Import reminders") { importing = true }
                }.padding(15).nudgePanel(palette)
                VStack(alignment: .leading, spacing: 6) {
                    Text(versionLabel)
                    Text("Developed by Jason Wang")
                }
                .font(.footnote)
                .foregroundStyle(palette.secondary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
        }
        .fileExporter(isPresented: $exporting, document: document, contentType: .json,
                      defaultFilename: "Reminders-backup") { result in
            switch result {
            case .success: message = "Backup exported."
            case .failure: message = "The backup was not exported."
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { (result: Result<URL, Error>) in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 10_000_000 else { throw ReminderDatabase.Problem.invalid }
                pendingBackup = try ReminderBackup.decode(Data(contentsOf: url))
                confirming = true
            } catch { message = "Choose a valid reminder backup exported by this app (up to 10 MB). Nothing was changed." }
        }
        .confirmationDialog("Import \(pendingBackup?.reminders.count ?? 0) reminders?",
                            isPresented: $confirming, titleVisibility: .visible) {
            Button("Import") {
                if let backup = pendingBackup { message = store.importBackup(backup) }
                pendingBackup = nil
            }
            Button("Cancel", role: .cancel) { pendingBackup = nil }
        } message: {
            Text("Only missing reminders will be added. Existing and previously deleted reminders are skipped. Imported overdue reminders may notify you.")
        }
        .alert("Backup", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") { message = nil }
        } message: { Text(message ?? "") }
        .foregroundStyle(palette.ink)
        .background(palette.paper.ignoresSafeArea())

    }
}


struct ReminderBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data = Data()
    init(data: Data = Data()) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let contents = configuration.file.regularFileContents else { throw ReminderDatabase.Problem.invalid }
        data = contents
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
