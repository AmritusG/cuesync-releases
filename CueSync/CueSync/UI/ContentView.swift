#if CUESYNC_CROSSUI
import SwiftCrossUI

// Re-host of App/ContentView.swift onto swift-cross-ui (spec CUESYNC-7 §D.9): the real
// Header -> ScrollView { Project, Browse, Configure, Export sections } -> Footer shape,
// replacing the CUESYNC-5 placeholder. The AppKit original is off-limits (SwiftUI-only,
// excluded from this target) and read only as the behavioral reference.
// PORT: section drag-reorder (`.draggable`/`.dropDestination`, the column drop zones) has no
// 0.8.0 equivalent (§0 table) — `AppState.sectionOrder`/`sectionColumns` stay fixed, set only
// by the Project section's Reset/Side-By-Side toggle, never by dragging (§D.8/§D.9).
// PORT: the subtle green `GridOverlay` background is cosmetic and dropped here rather than
// risking the forbidden `GtkFixed`/absolute-positioning path the DoD rules out (§D.9, §L).
// PORT: `.preferredColorScheme`/`.navigationTitle` have no swift-cross-ui equivalent used
// elsewhere in this port; theme is already applied per-view via `state.colors`.
struct ContentView: View {
    @Environment(AppState.self) private var state

    private let sectionTitles: [String: String] = [
        "project": "PROJECT",
        "browse": "BROWSE & SELECT TRACK",
        "configure": "CONFIGURE CUE POINTS",
        "export": "EXPORT",
    ]

    private let logicalOrder = ["project", "browse", "configure", "export"]

    var body: some View {
        let colors = state.colors

        VStack(spacing: 0) {
            HeaderView()

            ScrollView {
                if state.sideBySideMode {
                    HStack(alignment: .top, spacing: 16) {
                        VStack(spacing: 16) {
                            ForEach(state.leftColumnSections, id: \.self) { sectionId in
                                sectionView(for: sectionId, colors: colors)
                            }
                        }
                        .frame(minWidth: 500)

                        VStack(spacing: 16) {
                            ForEach(state.rightColumnSections, id: \.self) { sectionId in
                                sectionView(for: sectionId, colors: colors)
                            }
                        }
                        .frame(minWidth: 500)
                    }
                    .padding(20)
                } else {
                    VStack(spacing: 16) {
                        ForEach(state.sectionOrder, id: \.self) { sectionId in
                            sectionView(for: sectionId, colors: colors)
                        }
                    }
                    .padding(20)
                }
            }

            FooterView()
        }
        .background(colors.background)
    }

    @ViewBuilder
    private func sectionView(for sectionId: String, colors: ThemeColors) -> some View {
        let stepNumber = (logicalOrder.firstIndex(of: sectionId) ?? 0) + 1
        let title = sectionTitles[sectionId] ?? sectionId.uppercased()

        switch sectionId {
        case "project":
            CollapsibleSection(id: sectionId, title: title, stepNumber: stepNumber) {
                ProjectSectionView()
            }
        case "browse":
            CollapsibleSection(id: sectionId, title: title, stepNumber: stepNumber) {
                BrowseSectionView()
            }
        case "configure":
            CollapsibleSection(
                id: sectionId, title: title, stepNumber: stepNumber,
                trailing: {
                    if !state.cuePoints.isEmpty {
                        let active = state.cuePoints.filter(\.enabled).count
                        Text("\(active)/\(state.cuePoints.count) points active")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(colors.textSecondary)
                    }
                }
            ) {
                ConfigureSectionView()
            }
        case "export":
            CollapsibleSection(id: sectionId, title: title, stepNumber: stepNumber) {
                ExportSectionView()
            }
        default:
            EmptyView()
        }
    }
}
#endif
