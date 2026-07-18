#if CUESYNC_CROSSUI
import SwiftCrossUI
import CueSyncCore

// Re-host of Views/Sections/EnvelopeCanvasView.swift onto swift-cross-ui (spec CUESYNC-7 §G.14).
// The AppKit original is off-limits (SwiftUI-only, excluded from this target) and read only
// as the behavioral reference.
//
// PORT: there is no `Canvas`/`GraphicsContext` at 0.8.0 (§0 table), so the drawing is built
// from `Shape`-conforming layers instead — each layer computes its own `Path` from the SAME
// full-canvas `bounds` it's handed, which is what lets several differently-colored point
// circles stack correctly in one `ZStack` without any `.offset`/`.position` API (0.8.0 has
// neither). This is also why per-cue-point Y-value/curve-name text labels are dropped rather
// than reproduced: `Path` cannot draw text, and there is no way to place a `Text` at an
// arbitrary computed pixel inside the canvas without `GtkFixed`-style absolute positioning,
// which the spec forbids outright. The cue table below already shows every value this would
// have duplicated, so no information is lost — only the on-canvas annotation.
// PORT: click-to-add, click-to-select, and drag-to-move are not portable at 0.8.0 (no pointer
// location on tap, no `DragGesture`) — see spec §G.14/§L. All editing routes through the
// toolbar and cue table instead, which is already a complete editor.
// CUESYNC-8 §5 re-verification (specs/CUESYNC-8-findings.md §2.4): re-checked against the
// pinned checkout after the GTK gesture/interactivity patch (patches/swift-cross-ui-0.8.0-gtk-
// interactivity.patch) — that patch fixes *delivery* of the tap/hover events that already
// exist, it cannot add a pointer-location parameter or a drag primitive the public
// `SwiftCrossUI` API never exposed at 0.8.0. Gap confirmed unchanged: cannot-reproduce-
// faithfully, not a regression from the patch.
// PORT: `StrokeStyle` has no `dash:` parameter at 0.8.0 (established re-hosting
// BrowseSectionView, §F) — the selection guide is a solid line, not dashed.
struct EnvelopeCanvasView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let colors = state.colors
        let duration = state.trackDuration
        let cuePoints = state.cuePoints
        let selectedIdx = state.selectedPointIndex

        let enabledSorted: [EnvelopePlotPoint] = cuePoints
            .filter(\.enabled)
            .sorted { $0.start < $1.start }
            .map {
                EnvelopePlotPoint(
                    normX: $0.normalizedX(duration: duration),
                    normY: $0.normalizedY,
                    curve: $0.curve
                )
            }

        VStack(spacing: 4) {
            HStack(spacing: 6) {
                VStack {
                    Text("100")
                    Spacer()
                    Text("50")
                    Spacer()
                    Text("0")
                }
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(colors.textSecondary)
                .frame(width: 22)

                ZStack {
                    EnvelopeGridShape()
                        .stroke(colors.gridColor, style: StrokeStyle(width: 1))

                    EnvelopeFillShape(points: enabledSorted)
                        .fill(colors.accentGreen.opacity(0.1))

                    EnvelopeCurveShape(points: enabledSorted)
                        .stroke(colors.accentGreen, style: StrokeStyle(width: 2, cap: .round, join: .round))

                    if let idx = selectedIdx, idx < cuePoints.count, cuePoints[idx].enabled {
                        EnvelopeSelectionGuideShape(normX: cuePoints[idx].normalizedX(duration: duration))
                            .stroke(colors.accentGreen.opacity(0.3), style: StrokeStyle(width: 1))
                    }

                    ForEach(Array(cuePoints.enumerated()), id: \.element.id) { index, cue in
                        pointView(cue: cue, duration: duration, colors: colors, isSelected: selectedIdx == index)
                    }
                }
                .frame(minHeight: 200)
                .background(colors.canvasBg)
                .cornerRadius(4)
            }

            HStack {
                Text("0.0")
                Spacer()
                Text("0.5")
                Spacer()
                Text("1.0")
            }
            .font(.system(size: 9, design: .monospaced))
            .foregroundColor(colors.textSecondary)
            .padding(.leading, 28)
        }
    }

    @ViewBuilder
    private func pointView(cue: CuePoint, duration: Double, colors: ThemeColors, isSelected: Bool) -> some View {
        let normX = cue.normalizedX(duration: duration)
        let normY = cue.normalizedY

        if !cue.enabled {
            EnvelopePointShape(normX: normX, normY: normY, radius: 3)
                .fill(Color.gray.opacity(0.4))
        } else {
            let strokeColor = isSelected
                ? (colors.isDark ? Color.white : Color.black)
                : (colors.isDark ? Color.white.opacity(0.5) : Color.black.opacity(0.3))
            EnvelopePointShape(normX: normX, normY: normY, radius: isSelected ? 7 : 5)
                .fill(Color(cssString: cue.color))
                .stroke(strokeColor, style: StrokeStyle(width: isSelected ? 2 : 1))
        }
    }
}

/// Plain-value (Sendable) projection of a `CuePoint` used only for path math — kept separate
/// from `CuePoint` itself so the `Shape` layers below (which must be `Sendable`, per the
/// `Shape` protocol) don't need `CuePoint` to carry that conformance.
private struct EnvelopePlotPoint: Equatable, Sendable {
    let normX: Double
    let normY: Double
    let curve: Int
}

private struct EnvelopeGridShape: Shape {
    nonisolated func path(in bounds: Path.Rect) -> Path {
        var path = Path()
        let cols = 10
        let rows = 4
        for i in 0...cols {
            let x = bounds.x + Double(i) / Double(cols) * bounds.width
            path = path.move(to: SIMD2(x: x, y: bounds.y)).addLine(to: SIMD2(x: x, y: bounds.maxY))
        }
        for i in 0...rows {
            let y = bounds.y + Double(i) / Double(rows) * bounds.height
            path = path.move(to: SIMD2(x: bounds.x, y: y)).addLine(to: SIMD2(x: bounds.maxX, y: y))
        }
        return path
    }
}

private struct EnvelopeFillShape: Shape {
    let points: [EnvelopePlotPoint]

    nonisolated func path(in bounds: Path.Rect) -> Path {
        guard points.count >= 2 else { return Path() }
        func px(_ p: EnvelopePlotPoint) -> SIMD2<Double> {
            SIMD2(x: bounds.x + p.normX * bounds.width, y: bounds.maxY - p.normY * bounds.height)
        }
        var path = Path()
        path = path.move(to: SIMD2(x: px(points[0]).x, y: bounds.maxY))
        for p in points {
            path = path.addLine(to: px(p))
        }
        path = path.addLine(to: SIMD2(x: px(points[points.count - 1]).x, y: bounds.maxY))
        return path
    }
}

private struct EnvelopeCurveShape: Shape {
    let points: [EnvelopePlotPoint]

    nonisolated func path(in bounds: Path.Rect) -> Path {
        guard points.count >= 2 else { return Path() }
        func px(_ p: EnvelopePlotPoint) -> SIMD2<Double> {
            SIMD2(x: bounds.x + p.normX * bounds.width, y: bounds.maxY - p.normY * bounds.height)
        }
        var path = Path()
        path = path.move(to: px(points[0]))
        for i in 1..<points.count {
            let prev = points[i - 1]
            let curr = points[i]
            let p0 = px(prev)
            let p1 = px(curr)
            let steps = max(Int((p1.x - p0.x) / 2), 20)
            guard steps > 0 else { continue }
            for step in 1...steps {
                let t = Double(step) / Double(steps)
                let easedT = CurveType.evaluate(curr.curve, t: t)
                let x = p0.x + (p1.x - p0.x) * t
                let y = p0.y + (p1.y - p0.y) * easedT
                path = path.addLine(to: SIMD2(x: x, y: y))
            }
        }
        return path
    }
}

private struct EnvelopeSelectionGuideShape: Shape {
    let normX: Double

    nonisolated func path(in bounds: Path.Rect) -> Path {
        let x = bounds.x + normX * bounds.width
        return Path().move(to: SIMD2(x: x, y: bounds.y)).addLine(to: SIMD2(x: x, y: bounds.maxY))
    }
}

private struct EnvelopePointShape: Shape {
    let normX: Double
    let normY: Double
    let radius: Double

    nonisolated func path(in bounds: Path.Rect) -> Path {
        let cx = bounds.x + normX * bounds.width
        let cy = bounds.maxY - normY * bounds.height
        return Path().addCircle(center: SIMD2(x: cx, y: cy), radius: radius)
    }
}
#endif
