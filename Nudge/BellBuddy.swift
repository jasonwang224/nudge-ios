import SwiftUI
import UIKit

@MainActor
struct BellBuddy: View {
    let date: Date
    let palette: NudgePalette
    @Environment(\.scenePhase) private var scenePhase
    @State private var visible = false

    var body: some View {
        VStack(spacing: 0) {
            BellBuddyArtwork(active: visible && scenePhase == .active, accent: UIColor(palette.accent))
                .frame(width: 136, height: 126)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(UpNextCountdown.label(until: date, now: context.date))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.accent)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Reminder countdown")
                    .accessibilityValue(UpNextCountdown.label(until: date, now: context.date))
            }
        }
        .frame(width: 136)
        .onAppear { visible = true }
        .onDisappear { visible = false }
    }
}

@MainActor
private struct BellBuddyArtwork: UIViewRepresentable {
    let active: Bool
    let accent: UIColor

    func makeUIView(context: Context) -> BellBuddyControl { BellBuddyControl() }

    func updateUIView(_ view: BellBuddyControl, context: Context) {
        view.tintColor = accent
        view.setActive(active)
    }

    static func dismantleUIView(_ view: BellBuddyControl, coordinator: ()) {
        view.setActive(false)
    }
}

/// Self-contained UI animation. It never reads or writes reminders or notifications.
/// Explicit Core Animation keeps the user-requested movement with Reduce Motion on.
@MainActor
private final class BellBuddyControl: UIControl {
    private enum Face: Equatable { case open, blink, left, right, happy }
    private let canvas = UIView()
    private let image = UIImageView()
    private var hearts: [UIImageView] = []
    private var wantsAnimation = false
    private var running = false
    private var reacting = false
    private var expressionWork: DispatchWorkItem?
    private var reactionWork: DispatchWorkItem?
    private var expressionIndex = 0
    private let expressions: [(Face, TimeInterval)] = [
        (.open, 2.8), (.blink, 0.16), (.open, 1.44), (.left, 1.6),
        (.open, 3.2), (.blink, 0.16), (.open, 0.24), (.blink, 0.16),
        (.open, 1.74), (.right, 1.6), (.open, 2.9)
    ]

    private static let frames: [UIImage] = {
        guard let sheet = UIImage(named: "BellBuddySprites")?.cgImage else { return [] }
        let side = sheet.width / 2
        return (0..<4).compactMap { index in
            let cell = CGRect(x: CGFloat((index % 2) * side), y: CGFloat((index / 2) * side), width: CGFloat(side), height: CGFloat(side))
            // Trim identical transparent margins in every frame without changing the artwork.
            let rect = cell.insetBy(dx: CGFloat(side) * 0.08, dy: CGFloat(side) * 0.04).integral
            guard let crop = sheet.cropping(to: rect) else { return nil }
            return UIImage(cgImage: crop, scale: 2, orientation: .up)
        }
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        accessibilityLabel = "Bell Buddy"
        accessibilityHint = "Double tap for a happy hop."
        accessibilityTraits = .button
        canvas.isUserInteractionEnabled = false
        image.contentMode = .scaleAspectFit
        image.isUserInteractionEnabled = false
        addSubview(canvas)
        canvas.addSubview(image)
        for _ in 0..<2 {
            let heart = UIImageView(image: UIImage(systemName: "heart.fill"))
            heart.contentMode = .scaleAspectFit
            heart.alpha = 0
            heart.isUserInteractionEnabled = false
            addSubview(heart)
            hearts.append(heart)
        }
        show(.open)
        addTarget(self, action: #selector(reaction), for: .touchUpInside)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        canvas.frame = bounds
        image.frame = canvas.bounds
        hearts[0].frame = CGRect(x: 7, y: 20, width: 16, height: 16)
        hearts[1].frame = CGRect(x: bounds.width - 25, y: 9, width: 14, height: 14)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        refreshActivity()
    }

    override func accessibilityActivate() -> Bool {
        guard running else { return false }
        reaction()
        return true
    }

    func setActive(_ active: Bool) {
        wantsAnimation = active
        refreshActivity()
    }

    private func refreshActivity() {
        let shouldRun = wantsAnimation && window != nil
        guard shouldRun != running else { return }
        running = shouldRun
        if running {
            startIdle()
        } else {
            expressionWork?.cancel()
            reactionWork?.cancel()
            expressionWork = nil
            reactionWork = nil
            reacting = false
            canvas.layer.removeAllAnimations()
            hearts.forEach { $0.layer.removeAllAnimations() }
            show(.open)
        }
    }

    private func show(_ face: Face) {
        let index: Int
        switch face {
        case .open: index = 0
        case .blink: index = 1
        case .left, .right: index = 2
        case .happy: index = 3
        }
        image.image = Self.frames.indices.contains(index) ? Self.frames[index] : UIImage(systemName: "bell.fill")
        image.transform = face == .right ? CGAffineTransform(scaleX: -1, y: 1) : .identity
    }

    private func startIdle() {
        guard running else { return }
        let sway = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        sway.values = [0, 0, -0.052, 0.052, -0.026, 0.012, 0, 0]
        sway.keyTimes = [0, 0.26, 0.33, 0.41, 0.49, 0.55, 0.60, 1]
        sway.duration = 10
        sway.repeatCount = .infinity
        sway.calculationMode = .cubic
        canvas.layer.add(sway, forKey: "idleSway")
        expressionIndex = 0
        nextExpression()
    }

    private func nextExpression() {
        guard running, !reacting else { return }
        let (face, duration) = expressions[expressionIndex]
        show(face)
        expressionIndex = (expressionIndex + 1) % expressions.count
        let work = DispatchWorkItem { [weak self] in self?.nextExpression() }
        expressionWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    @objc private func reaction() {
        guard running, !reacting else { return }
        reacting = true
        expressionWork?.cancel()
        canvas.layer.removeAnimation(forKey: "idleSway")
        show(.happy)

        let hop = CAKeyframeAnimation(keyPath: "transform.translation.y")
        hop.values = [0, 3, -17, 0, -5, 0, 0]
        hop.keyTimes = [0, 0.12, 0.37, 0.59, 0.76, 0.91, 1]
        let wiggle = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        wiggle.values = [0, -0.14, 0.14, -0.087, 0.035, 0]
        wiggle.keyTimes = [0, 0.20, 0.42, 0.64, 0.82, 1]
        hop.duration = 1.2
        wiggle.duration = 1.2
        hop.calculationMode = .cubic
        wiggle.calculationMode = .cubic
        let group = CAAnimationGroup()
        group.animations = [hop, wiggle]
        group.duration = 1.2
        canvas.layer.add(group, forKey: "happyHop")

        for (index, heart) in hearts.enumerated() {
            let opacity = CAKeyframeAnimation(keyPath: "opacity")
            opacity.values = [0, 0.9, 0]
            opacity.keyTimes = [0, 0.25, 1]
            let rise = CABasicAnimation(keyPath: "transform.translation.y")
            rise.fromValue = 5
            rise.toValue = -25
            opacity.duration = 1.2
            rise.duration = 1.2
            let float = CAAnimationGroup()
            float.animations = [opacity, rise]
            float.duration = 1.2
            float.beginTime = CACurrentMediaTime() + Double(index) * 0.1
            heart.layer.add(float, forKey: "happyHeart")
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.running else { return }
            self.reacting = false
            self.startIdle()
        }
        reactionWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
    }
}
