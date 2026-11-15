import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct NudgeSettings: View {
    @ObservedObject var store: ReminderStore
    @Binding var appearance: NudgeAppearance
    let palette: NudgePalette

    @Environment(\.openURL) private var openURL
    @State private var exporting = false
    @State private var showingBackupHelp = false
    @State private var importing = false
    @State private var document = ReminderBackupDocument()
    @State private var pendingBackup: ReminderBackup?
    @State private var confirming = false
    @State private var message: String?

    private var versionLabel: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "Version \(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"
    }

    private var backupPresentation: (title: String, detail: String, icon: String, color: Color) {
        if let issue = store.storageIssue {
            return ("Backup needs attention", issue, "exclamationmark.shield", palette.accent)
        }
        switch store.backupStatus {
        case "Automatic backup is ready.", "Recovered your reminders from the automatic backup.":
            return ("Automatic backup is on", "Recover your reminders if data is damaged.",
                    "checkmark.shield", palette.green)
        case "Automatic backup starts with your first saved reminder.":
            return ("Automatic backup is on", "Starts with your first saved reminder.",
                    "shield", palette.green)
        case "Checking automatic backup…":
            return ("Checking automatic backup…", "Checking your recovery copy.",
                    "clock", palette.secondary)
        default:
            return ("Backup needs attention", store.backupStatus,
                    "exclamationmark.shield", palette.accent)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                NudgeHeading(eyebrow: "", title: "Settings", subtitle: "", icon: "", palette: palette)
                    .padding(.bottom, 2)
                VStack(alignment: .leading, spacing: 10) {
                    Text("New reminder defaults").font(.footnote.weight(.semibold)).accessibilityAddTraits(.isHeader)
                    PreferenceFields(preferences: $store.defaults, palette: palette, isDefaults: true)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Notifications").font(.footnote.weight(.semibold)).accessibilityAddTraits(.isHeader)
                    VStack(spacing: 0) {
                        Button {
                            if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                        } label: {
                            NudgeSettingsRow(title: "iPhone settings", icon: "bell", palette: palette) {
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(palette.secondary)
                            }
                        }.buttonStyle(.plain)
                        Divider().overlay(palette.line.opacity(0.5)).padding(.horizontal, 14)
                        NudgeSettingsRow(title: "Snooze", icon: "clock", palette: palette) {
                            Text("15 minutes").font(.caption).foregroundStyle(palette.secondary)
                        }
                    }.nudgePanel(palette)
                    Text("Sound and vibration follow your iPhone settings.")
                        .font(.caption2).foregroundStyle(palette.secondary).padding(.horizontal, 3)
                }
                NudgeSettingsRow(title: "Appearance", icon: "moon", palette: palette) {
                    Menu {
                        Picker("Appearance", selection: $appearance) {
                            ForEach(NudgeAppearance.allCases) { style in Text(style.rawValue).tag(style) }
                        }
                    } label: {
                        NudgeMenuValue(value: appearance.rawValue, palette: palette)
                    }
                    .accessibilityLabel("Appearance, " + appearance.rawValue)
                }.nudgePanel(palette)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Backup").font(.footnote.weight(.semibold)).accessibilityAddTraits(.isHeader)
                    VStack(alignment: .leading, spacing: 0) {
                        Button { showingBackupHelp = true } label: {
                            HStack(spacing: 12) {
                                Image(systemName: backupPresentation.icon)
                                    .font(.system(size: 20, weight: .regular))
                                    .foregroundStyle(backupPresentation.color)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(backupPresentation.title)
                                        .font(.caption)
                                        .foregroundStyle(backupPresentation.color)
                                    Text(backupPresentation.detail)
                                        .font(.caption2)
                                        .foregroundStyle(palette.secondary)
                                }
                                .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Show backup information")
                        Rectangle().fill(palette.green.opacity(0.16)).frame(height: 1)
                        HStack(spacing: 0) {
                            Button {
                                do {
                                    document = ReminderBackupDocument(data: try store.exportBackup())
                                    exporting = true
                                } catch { message = "Could not export your reminders. Check the storage message and try again." }
                            } label: {
                                Label("Export", systemImage: "square.and.arrow.up")
                                    .frame(maxWidth: .infinity, minHeight: 44)
                            }
                            Divider().frame(height: 20)
                            Button { importing = true } label: {
                                Label("Import", systemImage: "square.and.arrow.down")
                                    .frame(maxWidth: .infinity, minHeight: 44)
                            }
                        }
                        .font(.caption).buttonStyle(.plain).foregroundStyle(palette.green)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
                    .nudgePanel(palette, fill: palette.sage, radius: 18)
                }
                VStack(spacing: 7) {
                    Text(versionLabel).font(.caption)
                    Text("Developed by Jason Wang").font(.caption)
                }
                .foregroundStyle(palette.secondary)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 8)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
        }
        .alert("About backup", isPresented: $showingBackupHelp) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The app keeps a verified recovery copy on this iPhone and can restore it if the main database is damaged. Export a separate file to protect against deleting the app or losing your phone.\n\nExport includes completed reminders. Import adds missing reminders; existing and previously deleted reminders are skipped. App defaults and appearance stay unchanged.")
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
                // Map larger exports where possible. Decode and validate the complete
                // backup before offering Import; no storage writes happen here.
                pendingBackup = try ReminderBackup.decode(Data(contentsOf: url, options: .mappedIfSafe))
                confirming = true
            } catch { message = "Choose a valid reminder backup exported by this app. Nothing was changed." }
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
