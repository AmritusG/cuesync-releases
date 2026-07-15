import SwiftUI

struct EnvelopeCanvasView: View {
    @Environment(AppState.self) private var state
    @State private var isDragging = false
    @State private var dragPointIndex: Int?
    @State private var preDragCuePoint: CuePoint?  // snapshot for ESC cancel

    private let pointRadius: CGFloat = 5
    private let selectedPointRadius: CGFloat = 7
    private let hitTestRadius: CGFloat = 15
    // Canvas margins matching Electron's viewBox: -25 0 850 240, graph area 20,40 to 780,200
    private let marginLeft: CGFloat = 30
    private let marginRight: CGFloat = 45
    private let marginTop: CGFloat = 28
    private let marginBottom: CGFloat = 30

    var body: some View {
        let colors = state.colors
        let cuePoints = state.cuePoints
        let duration = state.trackDuration
        let selectedIdx = state.selectedPointIndex

        GeometryReader { geo in
            let size = geo.size
            let graphRect = CGRect(
                x: marginLeft,
                y: marginTop,
                width: size.width - marginLeft - marginRight,
                height: size.height - marginTop - marginBottom
            )

            Canvas { context, drawSize in
                drawGrid(context: context, rect: graphRect, colors: colors)
                drawAxisLabels(context: context, rect: graphRect, colors: colors)
                drawFill(context: context, rect: graphRect, colors: colors, cuePoints: cuePoints, duration: duration)
                drawCurve(context: context, rect: graphRect, colors: colors, cuePoints: cuePoints, duration: duration)
                drawSelectionGuide(context: context, rect: graphRect, colors: colors, cuePoints: cuePoints, duration: duration, selectedIdx: selectedIdx)
                drawPoints(context: context, rect: graphRect, colors: colors, cuePoints: cuePoints, duration: duration, selectedIdx: selectedIdx)
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { location in
                // Double-click on empty space adds a new point
                handleDoubleClick(location: location, graphRect: graphRect)
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        handleDrag(location: value.location, graphRect: graphRect)
                    }
                    .onEnded { _ in
                        isDragging = false
                        dragPointIndex = nil
                        preDragCuePoint = nil
                    }
            )
        }
        .aspectRatio(850.0 / 240.0, contentMode: .fit)
        .background(colors.canvasBg)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .onKeyPress(.escape) {
            cancelDrag()
            return .handled
        }
    }

    // MARK: - Drawing

    private func drawGrid(context: GraphicsContext, rect: CGRect, colors: ThemeColors) {
        let gridColor = colors.gridColor
        let cols = 10
        let rows = 4
        for i in 0...cols {
            let x = rect.minX + CGFloat(i) / CGFloat(cols) * rect.width
            var path = Path()
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x, y: rect.maxY))
            context.stroke(path, with: .color(gridColor), lineWidth: 1)
        }
        for i in 0...rows {
            let y = rect.minY + CGFloat(i) / CGFloat(rows) * rect.height
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y))
            context.stroke(path, with: .color(gridColor), lineWidth: 1)
        }
    }

    private func drawAxisLabels(context: GraphicsContext, rect: CGRect, colors: ThemeColors) {
        let labelColor = colors.textSecondary

        // Y-axis labels: 100, 50, 0
        for (label, fraction) in [("100", 0.0), ("50", 0.5), ("0", 1.0)] {
            let y = rect.minY + CGFloat(fraction) * rect.height
            let text = Text(label).font(.system(size: 9, design: .monospaced)).foregroundColor(labelColor)
            let resolved = context.resolve(text)
            context.draw(resolved, at: CGPoint(x: rect.minX - 4, y: y), anchor: .trailing)
        }

        // X-axis labels: 0.0, 0.5, 1.0
        for (label, fraction) in [("0.0", 0.0), ("0.5", 0.5), ("1.0", 1.0)] {
            let x = rect.minX + CGFloat(fraction) * rect.width
            let text = Text(label).font(.system(size: 9, design: .monospaced)).foregroundColor(labelColor)
            let resolved = context.resolve(text)
            context.draw(resolved, at: CGPoint(x: x, y: rect.maxY + 4), anchor: .top)
        }
    }

    private func drawFill(context: GraphicsContext, rect: CGRect, colors: ThemeColors,
                          cuePoints: [CuePoint], duration: Double) {
        let sorted = cuePoints.filter(\.enabled).sorted { $0.start < $1.start }
        guard sorted.count >= 2 else { return }

        var path = Path()
        path.move(to: CGPoint(x: ptX(sorted[0], rect, duration), y: rect.maxY))
        for pt in sorted {
            path.addLine(to: CGPoint(x: ptX(pt, rect, duration), y: ptY(pt, rect)))
        }
        path.addLine(to: CGPoint(x: ptX(sorted.last!, rect, duration), y: rect.maxY))
        path.closeSubpath()
        context.fill(path, with: .color(colors.accentGreen.opacity(0.1)))
    }

    private func drawCurve(context: GraphicsContext, rect: CGRect, colors: ThemeColors,
                           cuePoints: [CuePoint], duration: Double) {
        let sorted = cuePoints.filter(\.enabled).sorted { $0.start < $1.start }
        guard sorted.count >= 2 else { return }

        var path = Path()
        path.move(to: CGPoint(x: ptX(sorted[0], rect, duration), y: ptY(sorted[0], rect)))

        for i in 1..<sorted.count {
            let prev = sorted[i - 1]
            let curr = sorted[i]
            let x0 = ptX(prev, rect, duration), y0 = ptY(prev, rect)
            let x1 = ptX(curr, rect, duration), y1 = ptY(curr, rect)
            let steps = max(Int((x1 - x0) / 2), 20)

            for step in 1...steps {
                let t = Double(step) / Double(steps)
                let easedT = CurveType.evaluate(curr.curve, t: t)
                let x = x0 + (x1 - x0) * t
                let y = y0 + (y1 - y0) * easedT
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        context.stroke(path, with: .color(colors.accentGreen), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
    }

    private func drawSelectionGuide(context: GraphicsContext, rect: CGRect, colors: ThemeColors,
                                    cuePoints: [CuePoint], duration: Double, selectedIdx: Int?) {
        guard let idx = selectedIdx, idx < cuePoints.count else { return }
        let cue = cuePoints[idx]
        guard cue.enabled else { return }
        let x = ptX(cue, rect, duration)

        var path = Path()
        path.move(to: CGPoint(x: x, y: rect.minY))
        path.addLine(to: CGPoint(x: x, y: rect.maxY))
        context.stroke(path, with: .color(colors.accentGreen.opacity(0.3)),
                       style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
    }

    private func drawPoints(context: GraphicsContext, rect: CGRect, colors: ThemeColors,
                            cuePoints: [CuePoint], duration: Double, selectedIdx: Int?) {
        for (i, cue) in cuePoints.enumerated() {
            let x = ptX(cue, rect, duration), y = ptY(cue, rect)
            let isSelected = selectedIdx == i
            let r = isSelected ? selectedPointRadius : pointRadius

            if !cue.enabled {
                let circle = Path(ellipseIn: CGRect(x: x - 3, y: y - 3, width: 6, height: 6))
                context.fill(circle, with: .color(Color.gray.opacity(0.4)))
                continue
            }

            let color = Color(cssString: cue.color)

            // Point circle with theme-aware stroke
            let circle = Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
            context.fill(circle, with: .color(color))
            let strokeColor = isSelected
                ? (colors.isDark ? Color.white : Color.black)
                : (colors.isDark ? Color.white.opacity(0.5) : Color.black.opacity(0.3))
            context.stroke(circle, with: .color(strokeColor), lineWidth: isSelected ? 2 : 1)

            // Y value label above point — bold black text, no background box, clamped
            let yLabel = String(format: "%.2f", cue.yValue)
            let rawLabelY = y - r - 6
            let labelY = max(rawLabelY, 4)
            let labelX = min(max(x, rect.minX + 4), rect.maxX + marginRight - 4)

            let text = Text(yLabel).font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundColor(colors.textPrimary)
            let resolved = context.resolve(text)
            context.draw(resolved, at: CGPoint(x: labelX, y: labelY), anchor: .bottom)

            // Curve name below point (if not Linear)
            if cue.curve != 1 {
                let curveName = CurveType.name(for: cue.curve)
                let curveText = Text(curveName).font(.system(size: 8, weight: .medium, design: .monospaced)).foregroundColor(colors.textSecondary)
                let curveResolved = context.resolve(curveText)
                let curveY = min(y + r + 6, rect.maxY - 4)
                context.draw(curveResolved, at: CGPoint(x: x, y: curveY), anchor: .top)
            }
        }
    }

    // MARK: - Coordinate Conversion

    private func ptX(_ cue: CuePoint, _ rect: CGRect, _ duration: Double) -> CGFloat {
        guard duration > 0 else { return rect.minX }
        var normX = cue.start / duration
        if cue.start <= 0.001 { normX = 0 }
        else if cue.start >= duration - 0.001 { normX = 1 }
        else { normX = min(max(normX, 0), 1) }
        return rect.minX + CGFloat(normX) * rect.width
    }

    private func ptY(_ cue: CuePoint, _ rect: CGRect) -> CGFloat {
        rect.maxY - CGFloat(cue.yValue / 100.0) * rect.height
    }

    // MARK: - Interaction

    private func handleDrag(location: CGPoint, graphRect: CGRect) {
        let duration = state.trackDuration
        guard graphRect.width > 0, graphRect.height > 0 else { return }

        if !isDragging {
            isDragging = true
            if let hitIdx = hitTest(at: location, graphRect: graphRect, duration: duration) {
                dragPointIndex = hitIdx
                preDragCuePoint = state.cuePoints[hitIdx]
                state.pushUndoSnapshot()
                state.selectedPointIndex = hitIdx
            } else {
                // Single click on empty space — deselect
                state.selectedPointIndex = nil
            }
        } else if let idx = dragPointIndex, idx < state.cuePoints.count {
            let normX = clamp(Double((location.x - graphRect.minX) / graphRect.width))
            let normY = clamp(1.0 - Double((location.y - graphRect.minY) / graphRect.height))
            let isStartPoint = idx == 0
            let isEndPoint = idx == state.cuePoints.count - 1

            state.updateCuePointSilently(at: idx) { cue in
                if !state.lockXAxis && !isStartPoint && !isEndPoint {
                    cue.start = normX * duration
                }
                if !state.lockYAxis {
                    cue.yValue = normY * 100.0
                }
            }
        }
    }

    private func hitTest(at location: CGPoint, graphRect: CGRect, duration: Double) -> Int? {
        for (i, cue) in state.cuePoints.enumerated().reversed() {
            guard cue.enabled else { continue }
            let px = ptX(cue, graphRect, duration)
            let py = ptY(cue, graphRect)
            let dist = sqrt(pow(location.x - px, 2) + pow(location.y - py, 2))
            if dist < hitTestRadius { return i }
        }
        return nil
    }

    private func cancelDrag() {
        if isDragging, let idx = dragPointIndex, let snapshot = preDragCuePoint, idx < state.cuePoints.count {
            // Restore the point to its pre-drag position
            state.cuePoints[idx] = snapshot
            state.undo() // pop the undo snapshot we pushed at drag start
        }
        isDragging = false
        dragPointIndex = nil
        preDragCuePoint = nil
    }

    private func handleDoubleClick(location: CGPoint, graphRect: CGRect) {
        let duration = state.trackDuration
        guard graphRect.width > 0, graphRect.height > 0 else { return }
        // Only add if double-clicked on empty space (not on an existing point)
        if hitTest(at: location, graphRect: graphRect, duration: duration) != nil { return }
        let normX = clamp(Double((location.x - graphRect.minX) / graphRect.width))
        let normY = clamp(1.0 - Double((location.y - graphRect.minY) / graphRect.height))
        state.addCuePoint(at: normX * duration, yValue: normY * 100)
        if let newIdx = state.cuePoints.firstIndex(where: { abs($0.start - normX * duration) < 0.001 }) {
            state.selectedPointIndex = newIdx
        }
    }

    private func clamp(_ v: Double) -> Double { min(max(v, 0), 1) }
}
