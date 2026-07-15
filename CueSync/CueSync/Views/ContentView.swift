import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var state

    private let sectionConfigs: [(id: String, title: String, icon: String)] = [
        ("project", "PROJECT", "folder"),
        ("browse", "BROWSE & SELECT TRACK", "music.note"),
        ("configure", "CONFIGURE CUE POINTS", "slider.horizontal.3"),
        ("export", "EXPORT", "square.and.arrow.up"),
    ]

    private let logicalOrder = ["project", "browse", "configure", "export"]

    var body: some View {
        let colors = state.colors

        VStack(spacing: 0) {
            HeaderView()

            ScrollView {
                if state.sideBySideMode {
                    // Two independent columns, both top-aligned
                    HStack(alignment: .top, spacing: 16) {
                        VStack(spacing: 16) {
                            ForEach(state.leftColumnSections, id: \.self) { sectionId in
                                sectionView(for: sectionId, colors: colors)
                            }
                            columnDropZone(column: "left", colors: colors)
                        }
                        .frame(minWidth: 500, maxWidth: .infinity, alignment: .top)
                        .clipped()

                        VStack(spacing: 16) {
                            ForEach(state.rightColumnSections, id: \.self) { sectionId in
                                sectionView(for: sectionId, colors: colors)
                            }
                            columnDropZone(column: "right", colors: colors)
                        }
                        .frame(minWidth: 500, maxWidth: .infinity, alignment: .top)
                        .clipped()
                    }
                    .padding(20)
                } else {
                    // Single column
                    VStack(spacing: 16) {
                        ForEach(state.sectionOrder, id: \.self) { sectionId in
                            sectionView(for: sectionId, colors: colors)
                        }
                        columnDropZone(column: nil, colors: colors)
                    }
                    .padding(20)
                }
            }

            FooterView()
        }
        .background(
            ZStack {
                colors.background
                GridOverlay(color: colors.accentGreen)
            }
        )
        .preferredColorScheme(state.theme == .dark ? .dark : .light)
        .navigationTitle(state.projectName + (state.hasUnsavedChanges ? " — Edited" : ""))
        .onAppear { setupDragCleanupMonitor() }
    }

    /// Monitor global mouse-up to always clear drag state when mouse is released
    private func setupDragCleanupMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { event in
            if state.draggedSection != nil {
                DispatchQueue.main.async {
                    state.draggedSection = nil
                    state.preDragSectionOrder = nil
                }
            }
            return event
        }
    }

    // MARK: - Drop Zone (bottom of columns)

    @ViewBuilder
    private func columnDropZone(column: String?, colors: ThemeColors) -> some View {
        // Invisible drop target at the bottom of each column so you can drop a panel there
        Color.clear
            .frame(height: 60)
            .contentShape(Rectangle())
            .dropDestination(for: String.self) { items, _ in
                guard let draggedId = items.first else { return false }
                withAnimation(.easeInOut(duration: 0.2)) {
                    // Move to end of this column
                    if let column, state.sideBySideMode {
                        state.sectionColumns[draggedId] = column
                    }
                    // Move to end of section order
                    if let idx = state.sectionOrder.firstIndex(of: draggedId) {
                        state.sectionOrder.remove(at: idx)
                        state.sectionOrder.append(draggedId)
                    }
                }
                state.draggedSection = nil
                state.preDragSectionOrder = nil
                state.savePreferences()
                return true
            } isTargeted: { _ in }
    }

    // MARK: - Section Builder

    @ViewBuilder
    private func sectionView(for sectionId: String, colors: ThemeColors) -> some View {
        let stepNumber = (logicalOrder.firstIndex(of: sectionId) ?? 0) + 1
        let config = sectionConfigs.first(where: { $0.id == sectionId })

        if let config {
            switch config.id {
            case "project":
                CollapsibleSection(
                    id: config.id, title: config.title,
                    stepNumber: stepNumber, sectionIcon: config.icon
                ) { ProjectSectionView() }
            case "browse":
                CollapsibleSection(
                    id: config.id, title: config.title,
                    stepNumber: stepNumber, sectionIcon: config.icon
                ) { BrowseSectionView() }
            case "configure":
                CollapsibleSection(
                    id: config.id, title: config.title,
                    stepNumber: stepNumber, sectionIcon: config.icon,
                    trailing: {
                        if !state.cuePoints.isEmpty {
                            let active = state.cuePoints.filter(\.enabled).count
                            Text("\(active)/\(state.cuePoints.count) points active")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(colors.textSecondary)
                        }
                    }
                ) { ConfigureSectionView() }
            case "export":
                CollapsibleSection(
                    id: config.id, title: config.title,
                    stepNumber: stepNumber, sectionIcon: config.icon
                ) { ExportSectionView() }
            default:
                EmptyView()
            }
        }
    }
}

// MARK: - Subtle green grid overlay

private struct GridOverlay: View {
    let color: Color
    private let gridSpacing: CGFloat = 50

    var body: some View {
        Canvas { context, size in
            let lineColor = color.resolve(in: context.environment)
            let faint = Color(
                red: Double(lineColor.red),
                green: Double(lineColor.green),
                blue: Double(lineColor.blue),
                opacity: 0.03
            )
            var y: CGFloat = 0
            while y <= size.height {
                var path = Path()
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(path, with: .color(faint), lineWidth: 1)
                y += gridSpacing
            }
            var x: CGFloat = 0
            while x <= size.width {
                var path = Path()
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(path, with: .color(faint), lineWidth: 1)
                x += gridSpacing
            }
        }
        .allowsHitTesting(false)
    }
}
