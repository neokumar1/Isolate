import SwiftUI
import AppKit

struct CustomFader: View {
    @Environment(\.isEnabled) private var isEnabled
    @Binding var value: Double
    let label: String
    var peak: Float = 0
    
    @Bindable private var theme = ThemeManager.shared
    @State private var startValue: Double? = nil
    @State private var hitTop = false
    @State private var hitBottom = false
    @State private var isHovered = false
    @State private var isDragging = false
    @State private var isClippingHeld = false
    @State private var clipHoldTask: Task<Void, Never>? = nil
    
    // Calibrated dB scale marks for hardware console layout
    private struct FaderTick {
        let normVal: Double
        let label: String?
        let isMajor: Bool
    }
    
    private let ticks: [FaderTick] = [
        FaderTick(normVal: 1, label: "+6", isMajor: true),
        FaderTick(normVal: 60.0 / 66, label: "0", isMajor: true),
        FaderTick(normVal: 54.0 / 66, label: "-6", isMajor: true),
        FaderTick(normVal: 48.0 / 66, label: "-12", isMajor: true),
        FaderTick(normVal: 36.0 / 66, label: "-24", isMajor: true),
        FaderTick(normVal: 0, label: "-∞", isMajor: true)
    ]

    var body: some View {
        GeometryReader { geo in
            let trackHeight = max(1, geo.size.height)
            let thumbCenterY = trackHeight * (1.0 - CGFloat(FaderScale.position(for: value)))
            let centerX = geo.size.width / 2.0
            
            ZStack(alignment: .top) {
                // 1. Full Track Hit Area for Immediate Dragging and Jump-to-Click
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .local)
                            .onChanged { drag in
                                isDragging = true
                                
                                if startValue == nil {
                                    // Check if drag started on/near thumb vs track jump
                                    let clickY = drag.startLocation.y
                                    let distFromThumb = abs(clickY - thumbCenterY)
                                    if distFromThumb <= 16 {
                                        startValue = FaderScale.position(for: value)
                                    } else {
                                        let jumpedVal = min(max(Double(1.0 - (clickY / trackHeight)), 0.0), 1.0)
                                        value = FaderScale.gain(at: jumpedVal)
                                        startValue = jumpedVal
                                        Haptics.playClick()
                                    }
                                    
                                    hitTop = (FaderScale.position(for: value) >= 0.999)
                                    hitBottom = (value <= 0.001)
                                }
                                
                                let isOptionHeld = NSEvent.modifierFlags.contains(.option)
                                let multiplier = isOptionHeld ? 0.25 : 1.0
                                let delta = (-drag.translation.height / trackHeight) * multiplier
                                let targetVal = min(max((startValue ?? FaderScale.position(for: value)) + delta, 0.0), 1.0)
                                
                                if targetVal >= 0.999 && !hitTop {
                                    hitTop = true
                                    Haptics.playAlignment()
                                } else if targetVal < 0.999 {
                                    hitTop = false
                                }
                                
                                if targetVal <= 0.001 && !hitBottom {
                                    hitBottom = true
                                    Haptics.playAlignment()
                                } else if targetVal > 0.001 {
                                    hitBottom = false
                                }
                                
                                if abs(FaderScale.position(for: value) - targetVal) > 0.0005 {
                                    value = FaderScale.gain(at: targetVal)
                                }
                            }
                            .onEnded { _ in
                                isDragging = false
                                startValue = nil
                                hitTop = false
                                hitBottom = false
                            }
                    )
                
                // 2. Calibrated Decibel Scale Graduation Marks (Left & Right Flanks)
                ForEach(0..<ticks.count, id: \.self) { idx in
                    let tick = ticks[idx]
                    if tick.isMajor || trackHeight >= 140 {
                        let yPos = trackHeight * (1.0 - CGFloat(tick.normVal))
                        
                        // Left Ticks + Labels
                        HStack(spacing: 3) {
                            if let lbl = tick.label {
                                Text(lbl)
                                    .font(.custom("DotGothic16-Regular", size: 7.5))
                                    .foregroundColor(tick.normVal == 1.0 ? Color.red.opacity(0.85) : theme.textMuted)
                                    .frame(width: 18, alignment: .trailing)
                            } else {
                                Spacer()
                                    .frame(width: 18)
                            }
                            
                            Rectangle()
                                .fill(tick.normVal == 1.0 ? Color.red.opacity(0.8) : (theme.isDark ? Color.white.opacity(tick.isMajor ? 0.25 : 0.12) : Color.black.opacity(tick.isMajor ? 0.35 : 0.16)))
                                .frame(width: tick.isMajor ? 6 : 3, height: 1)
                        }
                        .position(x: centerX - 18, y: yPos)
                        .allowsHitTesting(false)
                        
                        // Right Symmetrical Ticks
                        Rectangle()
                            .fill(tick.normVal == 1.0 ? Color.red.opacity(0.8) : (theme.isDark ? Color.white.opacity(tick.isMajor ? 0.25 : 0.12) : Color.black.opacity(tick.isMajor ? 0.35 : 0.16)))
                            .frame(width: tick.isMajor ? 6 : 3, height: 1)
                            .position(x: centerX + (tick.isMajor ? 11 : 9.5), y: yPos)
                            .allowsHitTesting(false)
                    }
                }
                
                // 3. Vertical Track Slot & Active Level Meter with Peak-Hold Clip LED
                ZStack(alignment: .top) {
                    let isLit = peak >= 1 || isClippingHeld
                    Circle()
                        .fill(isLit ? Color.red : Color.red.opacity(0.18))
                        .frame(width: 4.5, height: 4.5)
                        .shadow(color: isLit ? Color.red : Color.clear, radius: 3)
                        .padding(.bottom, 4)
                        .animation(.easeOut(duration: 0.25), value: isLit)
                    
                    ZStack(alignment: .bottom) {
                        // Track background slot
                        Rectangle()
                            .fill(theme.faderTrack)
                            .frame(width: 3.5, height: max(0, trackHeight - 12))
                            .overlay(
                                Rectangle()
                                    .stroke(theme.hairline, lineWidth: 0.5)
                            )
                        
                        // Track fill (active level)
                        Rectangle()
                            .fill(Color.red)
                            .frame(width: 3.5, height: max(0, (max(0, trackHeight - 12)) * CGFloat(FaderScale.position(for: value))))
                    }
                    .padding(.top, 10)
                }
                .frame(width: 6, height: trackHeight)
                .position(x: centerX, y: trackHeight / 2.0)
                .allowsHitTesting(false)
                
                // 4. Machined Hardware Fader Thumb (Nothing OS Style)
                ZStack {
                    // Expanded touch target (48x28pt)
                    Color.clear
                        .frame(width: 48, height: 28)
                        .contentShape(Rectangle())
                    
                    // Visual Hardware Thumb
                    ZStack {
                        // Cap Body
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(theme.faderThumb)
                            .frame(width: 40, height: 14)
                            .overlay(
                                RoundedRectangle(cornerRadius: 1.5)
                                    .stroke(
                                        (isHovered || isDragging)
                                            ? Color.red.opacity(0.90)
                                            : theme.faderThumbStroke,
                                        lineWidth: (isHovered || isDragging) ? 1.5 : 1
                                    )
                            )
                            .shadow(
                                color: Color.red.opacity((isHovered || isDragging) ? 0.6 : 0.0),
                                radius: 5,
                                x: 0,
                                y: 0
                            )
                        
                        // Milled Knurling Grip Accents
                        HStack {
                            Rectangle()
                                .fill(theme.faderThumbKnurling)
                                .frame(width: 1, height: 8)
                            Spacer()
                            Rectangle()
                                .fill(theme.faderThumbKnurling)
                                .frame(width: 1, height: 8)
                        }
                        .frame(width: 32)
                        
                        // Center Nothing Red Alignment Index Stripe
                        Rectangle()
                            .fill(Color.red)
                            .frame(width: 22, height: 2)
                    }
                }
                .position(x: centerX, y: thumbCenterY)
                .onHover { hovering in
                    isHovered = hovering
                    if hovering {
                        NSCursor.pointingHand.push()
                    } else {
                        NSCursor.pop()
                    }
                }
                .allowsHitTesting(false)
            }
        }
        .frame(minHeight: 70, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) volume")
        .accessibilityValue(value > 0 ? String(format: "%.1f decibels", 20 * log10(value)) : "Muted")
        .accessibilityAdjustableAction { direction in
            adjust(direction == .increment ? 0.02 : -0.02)
        }
        .focusable(isEnabled)
        .onKeyPress(.upArrow) { adjust(0.02); return .handled }
        .onKeyPress(.downArrow) { adjust(-0.02); return .handled }
        .contextMenu { Button("Reset to 0 dB") { value = 1 } }
        .simultaneousGesture(TapGesture(count: 2).onEnded { value = 1; Haptics.playAlignment() })
        .onChange(of: peak) { oldPeak, newPeak in
            if newPeak >= 1 {
                clipHoldTask?.cancel()
                isClippingHeld = true
            } else if oldPeak >= 1 {
                triggerClipHold()
            }
        }
        .onDisappear {
            clipHoldTask?.cancel()
            isClippingHeld = false
        }

    }
    
    private func adjust(_ delta: Double) {
        value = FaderScale.gain(at: FaderScale.position(for: value) + delta)
    }

    private func triggerClipHold() {
        isClippingHeld = true
        clipHoldTask?.cancel()
        clipHoldTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            // This task starts when the peak falls below clipping. A new clip
            // cancels it; avoid reading the stale peak captured with this view.
            withAnimation(.easeOut(duration: 0.35)) {
                isClippingHeld = false
            }
        }
    }
}
