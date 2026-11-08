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

    var paper: Color { color(0xfcfbf8, 0x292d27) }
    var canvas: Color { color(0xf4f3ee, 0x20231f) }
    var surface: Color { color(0xffffff, 0x33382f) }
    var ink: Color { color(0x30322d, 0xf4f2e9) }
    var secondary: Color { color(0x666a60, 0xb2b9a9) }
    var line: Color { color(0xe8e8df, 0x41473b) }
    var accent: Color { color(0xb7442e, 0xf39479) }
    var coral: Color { color(0xfae5dc, 0x5c3f34) }
    var sage: Color { color(0xe7eee2, 0x3e4938) }
    var green: Color { color(0x4e674b, 0xc2d9af) }

    private func color(_ light: UInt32, _ dark: UInt32) -> Color {
        let hex = scheme == .dark ? dark : light
        return Color(red: Double((hex >> 16) & 255) / 255,
                     green: Double((hex >> 8) & 255) / 255,
                     blue: Double(hex & 255) / 255)
    }
}

extension View {
    func nudgePanel(_ palette: NudgePalette, fill: Color? = nil) -> some View {
        self
            .background(fill ?? palette.surface, in: RoundedRectangle(cornerRadius: 20))
            .overlay {
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(palette.line, lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }
}

struct NudgeHeading: View {
    let eyebrow: String
    let title: String
    let subtitle: String
    let icon: String
    let palette: NudgePalette

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 7) {
                Text(eyebrow.uppercased())
                    .font(.caption.weight(.semibold)).tracking(1.3)
                    .foregroundStyle(palette.secondary)
                Text(title)
                    .font(.largeTitle.weight(.semibold))
                    .foregroundStyle(palette.ink)
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle).font(.subheadline).foregroundStyle(palette.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: icon)
                .font(.system(size: 25, weight: .light))
                .foregroundStyle(palette.accent)
                .padding(12)
                .background(palette.coral, in: RoundedRectangle(cornerRadius: 17))
                .accessibilityHidden(true)
        }
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
    @State private var soundPreview = NudgeSoundPreview()
    private let columns = [GridItem(.adaptive(minimum: 65), spacing: 7)]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("NAG ME", systemImage: "bell.badge")
                .font(.caption.weight(.semibold)).tracking(0.8)
                .foregroundStyle(palette.secondary)
            LazyVGrid(columns: columns, spacing: 7) {
                ForEach(ReminderPreferences.nagIntervals, id: \.self) { minutes in
                    chip(minutes == 0 ? "Off" : "\(minutes) min", selected: preferences.nagMinutes == minutes) {
                        preferences.nagMinutes = minutes
                    }
                }
            }
            Text(nagHelp).font(.footnote).foregroundStyle(palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                row("Repeat", icon: "repeat", color: palette.sage) {
                    Picker("Repeat", selection: $preferences.repeatRule) {
                        ForEach(RepeatRule.allCases) { rule in Text(rule.rawValue).tag(rule) }
                    }.pickerStyle(.menu).labelsHidden()
                }
                if preferences.repeatRule == .custom {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 37), spacing: 5)], spacing: 5) {
                        ForEach(1...7, id: \.self) { day in
                            let calendar = Calendar.autoupdatingCurrent
                            chip(calendar.veryShortWeekdaySymbols[day - 1], selected: preferences.weekdays.contains(day)) {
                                if preferences.weekdays.contains(day) {
                                    if preferences.weekdays.count > 1 { preferences.weekdays.remove(day) }
                                }
                                else { preferences.weekdays.insert(day) }
                            }
                            .accessibilityLabel(calendar.weekdaySymbols[day - 1])
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                    Text(preferences.weekdays.isEmpty ? "Choose at least one repeat day." : "Keep at least one repeat day selected.")
                        .font(.footnote)
                        .foregroundStyle(preferences.weekdays.isEmpty ? palette.accent : palette.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 10)
                }
                Divider().overlay(palette.line)
                row("Notifications", icon: "bell", color: palette.coral) {
                    Toggle("Notifications", isOn: $preferences.notifications)
                        .labelsHidden().tint(palette.green)
                }
                Divider().overlay(palette.line)
                row("Vibration", icon: "iphone.radiowaves.left.and.right", color: palette.sage) {
                    Text("iPhone settings").font(.footnote).foregroundStyle(palette.secondary)
                }
                Divider().overlay(palette.line)
                row("Sound", icon: "speaker.wave.2", color: palette.coral) {
                    Picker("Sound", selection: $preferences.sound) {
                        ForEach(AlertSound.allCases) { sound in Text(sound.rawValue).tag(sound) }
                    }.pickerStyle(.menu).labelsHidden()
                    Button { soundPreview.play(preferences.sound) } label: {
                        Image(systemName: "play.circle").font(.title3)
                            .frame(minWidth: 36, minHeight: 44)
                    }
                    .buttonStyle(.plain).foregroundStyle(palette.accent)
                    .accessibilityLabel("Preview sound")
                    .disabled(preferences.sound.fileName == nil)
                }
                Divider().overlay(palette.line)
                row("Snooze", icon: "clock", color: palette.sage) {
                    Text("15 minutes").font(.footnote).foregroundStyle(palette.secondary)
                }
            }
            .nudgePanel(palette)
        }
        .onChange(of: preferences.sound) { _, sound in soundPreview.play(sound) }
    }

    private var nagHelp: String {
        if !preferences.notifications { return "Turn on notifications to receive nudges." }
        if preferences.nagMinutes == 0 { return "One notification, with no follow-up nudges." }
        return "Repeat every \(preferences.nagMinutes) minutes. Snooze pauses nudges for 15 minutes."
    }

    private func chip(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.subheadline.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? palette.accent : palette.ink)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(selected ? palette.coral : palette.surface, in: RoundedRectangle(cornerRadius: 11))
                .overlay {
                    RoundedRectangle(cornerRadius: 11)
                        .strokeBorder(selected ? palette.accent : palette.line, lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func row<Trailing: View>(_ label: String, icon: String, color: Color,
                                     @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.subheadline)
                .frame(width: 28, height: 28)
                .background(color, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
            Text(label).font(.subheadline)
            Spacer(minLength: 0)
            trailing()
        }
        .foregroundStyle(palette.ink)
        .padding(.horizontal, 12)
        .frame(minHeight: 52)
    }
}
