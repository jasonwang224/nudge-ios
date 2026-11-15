import AVFoundation
import SwiftUI

enum NudgeAppearance: String, CaseIterable, Identifiable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"

    var id: String { rawValue }

    var scheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

struct NudgePalette {
    var scheme: ColorScheme

    var paper: Color { color(0xfaf9f6, 0x292d27) }
    var canvas: Color { color(0xf0f1eb, 0x20231f) }
    var surface: Color { color(0xffffff, 0x33382f) }
    var ink: Color { color(0x292e29, 0xf4f2e9) }
    var secondary: Color { color(0x666a60, 0xb2b9a9) }
    var line: Color { color(0xe8e8df, 0x41473b) }
    var accent: Color { color(0xb74730, 0xf39479) }
    var coral: Color { color(0xf8e5dc, 0x5c3f34) }
    var sage: Color { color(0xe9eee5, 0x3e4938) }
    var green: Color { color(0x4e674b, 0xc2d9af) }

    private func color(_ light: UInt32, _ dark: UInt32) -> Color {
        let hex = scheme == .dark ? dark : light
        return Color(red: Double((hex >> 16) & 255) / 255,
                     green: Double((hex >> 8) & 255) / 255,
                     blue: Double(hex & 255) / 255)
    }
}

extension View {
    func nudgePanel(_ palette: NudgePalette, fill: Color? = nil, radius: CGFloat = 20) -> some View {
        background(fill ?? palette.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

struct NudgeHeading: View {
    let eyebrow: String
    let title: String
    let subtitle: String
    let icon: String
    let palette: NudgePalette

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                if !eyebrow.isEmpty {
                    Text(eyebrow).font(.caption).foregroundStyle(palette.secondary)
                }
                Text(title)
                    .font(.largeTitle.weight(.bold))
                    .tracking(-0.8)
                    .foregroundStyle(palette.ink)
                    .accessibilityAddTraits(.isHeader)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.subheadline).foregroundStyle(palette.secondary)
                }
            }
            Spacer(minLength: 0)
            if !icon.isEmpty {
                Image(systemName: icon)
                    .font(.system(size: 25, weight: .light))
                    .foregroundStyle(palette.accent)
                    .frame(width: 46, height: 46)
                    .background(palette.coral, in: RoundedRectangle(cornerRadius: 16))
                    .accessibilityHidden(true)
            }
        }
    }
}

struct NudgeSettingsRow<Trailing: View>: View {
    let title: String
    let icon: String
    let palette: NudgePalette
    @ViewBuilder var trailing: () -> Trailing
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 10))
        layout {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.subheadline).foregroundStyle(palette.secondary)
                    .frame(width: 22).accessibilityHidden(true)
                Text(title).font(.subheadline).fixedSize(horizontal: false, vertical: true)
            }
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 6) }
            trailing()
                .font(.subheadline)
                .fixedSize(horizontal: !dynamicTypeSize.isAccessibilitySize, vertical: true)
        }
        .foregroundStyle(palette.ink)
        .padding(.horizontal, 14).padding(.vertical, 5)
        .frame(minHeight: 50)
    }
}

@MainActor
final class NudgeSoundPreview {
    private var player: AVAudioPlayer?

    func play(_ sound: AlertSound) {
        player?.stop()
        if let name = sound.fileName, let url = Bundle.main.url(forResource: name, withExtension: nil) {
            player = try? AVAudioPlayer(contentsOf: url)
            player?.play()
        }
    }
}

@MainActor
struct PreferenceFields: View {
    @Binding var preferences: ReminderPreferences
    let palette: NudgePalette
    var isDefaults = false
    @State private var soundPreview = NudgeSoundPreview()

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            VStack(spacing: 0) {
                if isDefaults {
                    nagRow
                    ruleDivider
                }
                NudgeSettingsRow(title: "Repeat", icon: "repeat", palette: palette) {
                    Picker("Repeat", selection: $preferences.repeatRule) {
                        ForEach(RepeatRule.allCases) { rule in Text(rule.rawValue).tag(rule) }
                    }
                    .pickerStyle(.menu).labelsHidden().tint(palette.secondary)
                    .font(.subheadline).lineLimit(1).minimumScaleFactor(0.8)
                }
                if preferences.repeatRule == .custom { customDays }
                ruleDivider
                if !isDefaults {
                    nagRow
                    ruleDivider
                }
                NudgeSettingsRow(title: "Sound", icon: "speaker.wave.2", palette: palette) {
                    Picker("Sound", selection: $preferences.sound) {
                        ForEach(AlertSound.allCases) { sound in Text(sound.rawValue).tag(sound) }
                    }
                    .pickerStyle(.menu).labelsHidden().tint(palette.secondary)
                    Button { soundPreview.play(preferences.sound) } label: {
                        Image(systemName: "play.circle")
                            .font(.title3).frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain).foregroundStyle(palette.accent)
                    .accessibilityLabel("Preview sound")
                    .disabled(preferences.sound.fileName == nil)
                }
            }
            .nudgePanel(palette)
            Text(isDefaults ? "Applied to reminders you create next." : (preferences.nagMinutes == 0 ? "Nag me is off: one notification. Snooze pauses it for 15 minutes." : "Snooze pauses nags for 15 minutes."))
                .font(.caption).foregroundStyle(palette.secondary)
                .padding(.horizontal, 3)
        }
        .onChange(of: preferences.sound) { _, sound in soundPreview.play(sound) }
    }

    private var ruleDivider: some View {
        Divider().overlay(palette.line.opacity(0.5)).padding(.horizontal, 14)
    }

    private var nagRow: some View {
        NudgeSettingsRow(title: "Nag me", icon: "bell", palette: palette) {
            Picker("Nag me", selection: $preferences.nagMinutes) {
                ForEach(ReminderPreferences.nagIntervals, id: \.self) { minutes in
                    Text(minutes == 0 ? "Off" : "Every \(minutes) min").tag(minutes)
                }
            }
            .pickerStyle(.menu).labelsHidden().tint(palette.secondary)
        }
    }

    private var customDays: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 38), spacing: 4)], spacing: 5) {
                ForEach(1...7, id: \.self) { day in
                    let calendar = Calendar.autoupdatingCurrent
                    let selected = preferences.weekdays.contains(day)
                    Button {
                        if selected {
                            if preferences.weekdays.count > 1 { preferences.weekdays.remove(day) }
                        } else { preferences.weekdays.insert(day) }
                    } label: {
                        Text(calendar.shortWeekdaySymbols[day - 1])
                            .font(.caption.weight(selected ? .semibold : .regular))
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .foregroundStyle(selected ? palette.accent : palette.secondary)
                            .background(selected ? palette.coral : palette.canvas,
                                        in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(calendar.weekdaySymbols[day - 1])
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            Text(preferences.weekdays.isEmpty ? "Choose at least one repeat day." : "Keep at least one repeat day selected.")
                .font(.caption).foregroundStyle(preferences.weekdays.isEmpty ? palette.accent : palette.secondary)
        }
        .padding(.horizontal, 14).padding(.bottom, 12)
    }
}
