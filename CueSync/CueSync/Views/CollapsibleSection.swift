import SwiftUI

struct CollapsibleSection<Content: View, Trailing: View>: View {
    @Environment(AppState.self) private var state
    let id: String
    let title: String
    let stepNumber: Int
    let sectionIcon: String
    @ViewBuilder let trailing: () -> Trailing
    @ViewBuilder let content: () -> Content

    @State private var dragHandleHovered = false

    init(
        id: String,
        title: String,
        stepNumber: Int,
        sectionIcon: String = "circle",
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() },
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.id = id
        self.title = title
        self.stepNumber = stepNumber
        self.sectionIcon = sectionIcon
        self.trailing = trailing
        self.content = content
    }

    private var isCollapsed: Bool {
        state.collapsedSections.contains(id)
    }

    private var isBeingDragged: Bool {
        state.draggedSection == id
    }

    var body: some View {
        let colors = state.colors

        VStack(spacing: 0) {
            // Header
            Button {
                // Any click on header means drag is done
                state.draggedSection = nil
                state.preDragSectionOrder = nil
                withAnimation(.easeInOut(duration: 0.3)) {
                    if isCollapsed {
                        state.collapsedSections.remove(id)
                    } else {
                        state.collapsedSections.insert(id)
                    }
                    state.savePreferences()
                }
            } label: {
                HStack(spacing: 10) {
                    // Drag handle — ⋮⋮ (ONLY this is draggable)
                    Text("\u{22EE}\u{22EE}")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(dragHandleHovered ? colors.accentGreen : colors.textDisabled)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                        .padding(.horizontal, 4)
                        .onHover { dragHandleHovered = $0 }
                        .animation(.easeInOut(duration: 0.15), value: dragHandleHovered)
                        .draggable(id) {
                            Text(title)
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundStyle(colors.accentGreen)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(colors.sectionBG)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(colors.accentGreen, lineWidth: 1))
                                .onAppear {
                                    state.preDragSectionOrder = state.sectionOrder
                                    state.draggedSection = id
                                }
                                .onDisappear {
                                    // Drag ended (dropped or cancelled) — always clean up
                                    state.draggedSection = nil
                                    state.preDragSectionOrder = nil
                                }
                        }

                    // Step badge with icon
                    ZStack {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(colors.accentGreen)
                            .frame(width: 28, height: 28)

                        VStack(spacing: 0) {
                            Image(systemName: sectionIcon)
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.black)
                            Text("\(stepNumber)")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(.black)
                        }
                    }

                    // Title
                    Text(title)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .tracking(1)
                        .foregroundStyle(colors.textPrimary)

                    Spacer()

                    trailing()

                    // Collapse arrow: ▶ when collapsed, ▼ when expanded
                    Text(isCollapsed ? "\u{25B6}" : "\u{25BC}")
                        .font(.system(size: 9))
                        .foregroundStyle(colors.textSecondary)
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            // Content
            if !isCollapsed {
                VStack(spacing: 0) {
                    Rectangle().fill(colors.border).frame(height: 1)
                    content()
                        .padding(16)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(
            colors.isDark
                ? AnyShapeStyle(LinearGradient(
                    colors: [colors.sectionBG.opacity(0.8), colors.sectionBG.opacity(0.9)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
                : AnyShapeStyle(colors.sectionBG)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isBeingDragged ? colors.accentGreen : colors.border,
                        style: isBeingDragged
                            ? StrokeStyle(lineWidth: 1, dash: [6, 4])
                            : StrokeStyle(lineWidth: 1))
        )
        .shadow(color: colors.sectionShadow, radius: 3, y: 1)
        .opacity(isBeingDragged ? 0.5 : 1)
        // Drop target (whole section is a drop target, but only handle is drag source)
        .dropDestination(for: String.self) { items, _ in
            guard let draggedId = items.first else {
                state.draggedSection = nil
                state.preDragSectionOrder = nil
                return false
            }
            if draggedId != id {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if state.sideBySideMode {
                        state.sectionColumns[draggedId] = state.sectionColumns[id] ?? "left"
                    }
                    reorderSection(draggedId: draggedId, targetId: id)
                }
                state.savePreferences()
            }
            state.draggedSection = nil
            state.preDragSectionOrder = nil
            return true
        } isTargeted: { _ in }
        .onKeyPress(.escape) {
            if state.draggedSection != nil, let saved = state.preDragSectionOrder {
                withAnimation(.easeInOut(duration: 0.2)) {
                    state.sectionOrder = saved
                }
                state.draggedSection = nil
                state.preDragSectionOrder = nil
            }
            return .handled
        }
    }

    private func reorderSection(draggedId: String, targetId: String) {
        guard let fromIdx = state.sectionOrder.firstIndex(of: draggedId),
              let toIdx = state.sectionOrder.firstIndex(of: targetId) else { return }
        state.sectionOrder.move(fromOffsets: IndexSet(integer: fromIdx), toOffset: toIdx > fromIdx ? toIdx + 1 : toIdx)
        state.savePreferences()
    }
}
