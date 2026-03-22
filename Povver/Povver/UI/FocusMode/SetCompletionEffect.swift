/**
 * SetCompletionEffect.swift
 *
 * Full sensory signature for set completion: radial fill, pulse, stroke draw,
 * row flash, and haptic feedback. Replaces the simple checkmark toggle with
 * a choreographed animation sequence.
 *
 * Progressive intensity levels:
 * - standard: base signature (light haptic)
 * - exerciseFinal: base + medium haptic at 0.3s
 * - workoutFinal: base + medium at 0.3s + success notification at 0.7s
 */

import SwiftUI

// MARK: - Completion Level

enum CompletionLevel {
    case standard       // Base signature
    case exerciseFinal  // + medium haptic
    case workoutFinal   // + success notification haptic
}

// MARK: - Set Completion Circle

struct SetCompletionCircle: View {
    let isComplete: Bool
    let completionLevel: CompletionLevel
    let action: () -> Void

    @State private var fillProgress: CGFloat = 0
    @State private var pulseScale: CGFloat = 1.0
    @State private var checkmarkTrim: CGFloat = 0
    @State private var hasAppeared = false
    @State private var animationTask: Task<Void, Never>?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let circleSize: CGFloat = 28
    private let strokeWidth: CGFloat = 2

    var body: some View {
        Button(action: action) {
            ZStack {
                // Background fill (radial)
                Circle()
                    .fill(Color.accent.opacity(fillProgress * 0.15))
                    .frame(width: circleSize, height: circleSize)

                // Stroke ring
                Circle()
                    .stroke(
                        isComplete ? Color.accent.opacity(0.3 + fillProgress * 0.7) : Color.textSecondary.opacity(0.15),
                        lineWidth: strokeWidth
                    )
                    .frame(width: circleSize, height: circleSize)

                // Checkmark stroke draw
                if isComplete {
                    CheckmarkShape()
                        .trim(from: 0, to: checkmarkTrim)
                        .stroke(Color.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .frame(width: circleSize * 0.5, height: circleSize * 0.5)
                }
            }
            .scaleEffect(pulseScale)
            .frame(width: 44, height: 44) // 44pt hit target
            .contentShape(Rectangle())
        }
        .buttonStyle(SetCompletionPressStyle())
        .accessibilityLabel(isComplete ? "Undo set completion" : "Mark set complete")
        .accessibilityAddTraits(.isButton)
        .onChange(of: isComplete) { _, newValue in
            if newValue {
                animateCompletion()
            } else {
                animateReset()
            }
        }
        .onAppear {
            // If already complete on appear, set final state without animation
            if isComplete && !hasAppeared {
                fillProgress = 1.0
                checkmarkTrim = 1.0
                pulseScale = 1.0
            }
            hasAppeared = true
        }
    }

    // MARK: - Animation Choreography

    private func animateCompletion() {
        if reduceMotion {
            // Reduce Motion: instant visual, haptics still fire
            fillProgress = 1.0
            checkmarkTrim = 1.0
            pulseScale = 1.0
            animationTask = Task { @MainActor in
                await fireHaptics(completionLevel)
            }
            return
        }

        // 1. Radial fill: 0.15s easeOut
        withAnimation(.easeOut(duration: 0.15)) {
            fillProgress = 1.0
        }

        // 2. Pulse: scale to 1.15 with bouncy spring
        withAnimation(.bouncy) {
            pulseScale = 1.15
        }

        // Choreograph delayed steps via cancellable Task
        animationTask = Task { @MainActor in
            // Fire haptic at pulse peak (~0.15s in)
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            await fireHaptics(completionLevel)

            // Checkmark: stroke draw 0.2s easeOut (starts at ~0.15s)
            withAnimation(.easeOut(duration: 0.2)) {
                checkmarkTrim = 1.0
            }

            // Return scale to 1.0 (at ~0.2s from start, so 0.05s after haptic)
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            withAnimation(.bouncy) {
                pulseScale = 1.0
            }
        }
    }

    private func animateReset() {
        animationTask?.cancel()
        withAnimation(.easeOut(duration: 0.15)) {
            fillProgress = 0
            checkmarkTrim = 0
            pulseScale = 1.0
        }
    }

    // MARK: - Progressive Haptics

    private func fireHaptics(_ level: CompletionLevel) async {
        // Base: light impact
        HapticManager.setCompleted()

        switch level {
        case .standard:
            break
        case .exerciseFinal:
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            HapticManager.modeToggle()
        case .workoutFinal:
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            HapticManager.modeToggle()
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            HapticManager.workoutCompleted()
        }
    }
}

// MARK: - Checkmark Shape

private struct CheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width; let h = rect.height
        path.move(to: CGPoint(x: w * 0.15, y: h * 0.5))
        path.addLine(to: CGPoint(x: w * 0.4, y: h * 0.75))
        path.addLine(to: CGPoint(x: w * 0.85, y: h * 0.25))
        return path
    }
}

// MARK: - Press Style

private struct SetCompletionPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? InteractionToken.pressScale : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - Row Flash Modifier

struct SetCompletionRowFlash: ViewModifier {
    let trigger: Bool
    @State private var flash = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .background(Color.accent.opacity(flash ? 0.08 : 0).animation(.easeOut(duration: 0.3), value: flash))
            .onChange(of: trigger) { _, newValue in
                guard newValue, !reduceMotion else { return }
                flash = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { flash = false }
            }
    }
}

extension View {
    func setCompletionFlash(trigger: Bool) -> some View {
        modifier(SetCompletionRowFlash(trigger: trigger))
    }
}
