import SwiftUI

@MainActor
struct NudgeSettings: View {
    @ObservedObject var store: ReminderStore
    @Binding var appearance: NudgeAppearance
    let palette: NudgePalette

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
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
        }
        .foregroundStyle(palette.ink)
        .background(palette.paper.ignoresSafeArea())
    }
}
