#if CUESYNC_CROSSUI
import SwiftCrossUI

// Re-host of Views/CollapsibleSection.swift onto swift-cross-ui (spec CUESYNC-7 §D.8), minus
// section drag-reorder — 0.8.0 has no `.draggable`/`.dropDestination` (§0 table), so section
// order stays the fixed logical order (`AppState.sectionOrder`). The AppKit original is
// off-limits (SwiftUI-only) and read only as the behavioral reference.
// PORT: drag handle, `.tracking` letter-spacing on the title, and the header's
// open/close animation are dropped — no equivalents at 0.8.0 (spec §L).
struct CollapsibleSection<Content: View, Trailing: View>: View {
    @Environment(AppState.self) var state

    let id: String
    let title: String
    let stepNumber: Int
    @ViewBuilder let trailing: () -> Trailing
    @ViewBuilder let content: () -> Content

    init(
        id: String,
        title: String,
        stepNumber: Int,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() },
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.id = id
        self.title = title
        self.stepNumber = stepNumber
        self.trailing = trailing
        self.content = content
    }

    private var isCollapsed: Bool {
        state.collapsedSections.contains(id)
    }

    var body: some View {
        let colors = state.colors

        VStack(spacing: 0) {
            // Header — no ViewBuilder-label Button at 0.8.0 (label is String-only), so the
            // whole row is a plain HStack with `.onTapGesture` standing in for the AppKit
            // original's `Button { ... } label: { ... }`.
            HStack(spacing: 10) {
                // Step badge
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(colors.accentGreen)
                        .frame(width: 28, height: 28)
                    Text("\(stepNumber)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.black)
                }

                Text(title)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(colors.textPrimary)

                Spacer()

                trailing()

                // Collapse arrow: ▶ when collapsed, ▼ when expanded
                Text(isCollapsed ? "\u{25B6}" : "\u{25BC}")
                    .font(.system(size: 9))
                    .foregroundColor(colors.textSecondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .onTapGesture {
                if isCollapsed {
                    state.collapsedSections.remove(id)
                } else {
                    state.collapsedSections.insert(id)
                }
                state.savePreferences()
            }

            if !isCollapsed {
                VStack(spacing: 0) {
                    Rectangle().fill(colors.border).frame(height: 1)
                    content()
                        .padding(16)
                }
            }
        }
        .background(colors.sectionBG)
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(colors.border, style: StrokeStyle(width: 1))
        }
        .cornerRadius(10)
    }
}
#endif
