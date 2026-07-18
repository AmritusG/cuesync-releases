#if CUESYNC_CROSSUI
import Foundation
import SwiftCrossUI
import CueSyncCore

// Re-host of Views/Sections/BrowseSectionView.swift onto swift-cross-ui (spec CUESYNC-7 §F).
// The AppKit original is off-limits (SwiftUI-only, excluded from this target) and read only
// as the behavioral reference.
//
// PORT: SF Symbols (`music.note.list`, `chevron.right`/`chevron.down`) are Apple-only;
// replaced with a portable glyph and the ▶/▼ text markers CollapsibleSection already
// established for expand/collapse (§D.8). The macOS source's own emoji (📚/📁/📋/🔍) are
// already portable and reused verbatim (spec §F.13, §0 table).
// PORT: swift-cross-ui's `Button` carries only a fixed String label (discovered re-hosting
// CollapsibleSection) — every row here is a plain HStack + `.onTapGesture`, the same
// substitute `CollapsibleSection`/`BrandButtons` use, not a real `Button`.
// PORT: `StrokeStyle` has no `dash:` parameter at 0.8.0 — the empty-state border is a solid
// stroke instead of the macOS dashed one.
// PORT: no `LazyVStack` at 0.8.0 — a plain `VStack` is used inside the `ScrollView`s instead.
struct BrowseSectionView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let colors = state.colors

        if state.tracks.isEmpty {
            VStack(spacing: 12) {
                Text("\u{1F3B5}")
                    .font(.system(size: 28))
                Text("Import tracks from Rekordbox, Serato, Engine DJ, or ShowKontrol to browse")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(colors.textMuted)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
            .background(colors.emptyStateBg)
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(colors.emptyStateBorder, style: StrokeStyle(width: 1))
            }
            .cornerRadius(8)
        } else {
            HStack(alignment: .top, spacing: 0) {
                PlaylistSidebar()
                    .frame(minWidth: 150, idealWidth: 220, maxWidth: 220)

                Rectangle().fill(colors.border).frame(width: 1)

                TrackListView()
            }
            .frame(minHeight: 250)
        }
    }
}

// MARK: - Playlist Sidebar

private struct PlaylistSidebar: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let colors = state.colors

        VStack(alignment: .leading, spacing: 0) {
            Text("PLAYLISTS")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(colors.textMuted)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            ScrollView {
                VStack(spacing: 0) {
                    PlaylistRow(
                        name: "All Tracks",
                        emoji: "\u{1F4DA}",
                        count: state.tracks.count,
                        isSelected: state.selectedPlaylistId == "all"
                    ) {
                        state.selectedPlaylistId = "all"
                    }

                    ForEach(state.playlists) { playlist in
                        PlaylistItemView(playlist: playlist, depth: 0)
                    }
                }
            }
        }
    }
}

private struct PlaylistItemView: View {
    @Environment(AppState.self) private var state
    let playlist: Playlist
    let depth: Int

    var body: some View {
        VStack(spacing: 0) {
            if playlist.isFolder {
                FolderRow(playlist: playlist, depth: depth)
                if state.expandedFolders.contains(playlist.id) {
                    ForEach(playlist.children) { child in
                        PlaylistItemView(playlist: child, depth: depth + 1)
                    }
                }
            } else {
                PlaylistRow(
                    name: playlist.name,
                    emoji: "\u{1F4CB}",
                    count: playlist.trackIds.count,
                    isSelected: state.selectedPlaylistId == playlist.id,
                    depth: depth
                ) {
                    state.selectedPlaylistId = playlist.id
                }
            }
        }
    }
}

private struct FolderRow: View {
    @Environment(AppState.self) private var state
    let playlist: Playlist
    let depth: Int

    private var isExpanded: Bool {
        state.expandedFolders.contains(playlist.id)
    }

    var body: some View {
        let colors = state.colors

        HStack(spacing: 6) {
            Text(isExpanded ? "\u{25BC}" : "\u{25B6}")
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(colors.textMuted)
                .frame(width: 10)
            Text("\u{1F4C1}")
                .font(.system(size: 11))
            Text(playlist.name)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(colors.textPrimary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.leading, 12 + depth * 16)
        .padding(.vertical, 6)
        .padding(.trailing, 8)
        .onTapGesture {
            if isExpanded {
                state.expandedFolders.remove(playlist.id)
            } else {
                state.expandedFolders.insert(playlist.id)
            }
        }
    }
}

private struct PlaylistRow: View {
    @Environment(AppState.self) private var state
    let name: String
    let emoji: String
    let count: Int
    let isSelected: Bool
    var depth: Int = 0
    let action: () -> Void

    var body: some View {
        let colors = state.colors

        HStack(spacing: 6) {
            Text(emoji)
                .font(.system(size: 11))
            Text(name)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(isSelected ? colors.accentGreen : colors.textPrimary)
                .lineLimit(1)
            Spacer()
            Text("\(count)")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(colors.textMuted)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(colors.countBadgeBg)
                .cornerRadius(3)
        }
        .padding(.leading, 12 + depth * 16)
        .padding(.vertical, 6)
        .padding(.trailing, 8)
        .background(isSelected ? colors.accentGreen.opacity(0.1) : Color.clear)
        .overlay(alignment: .leading) {
            if isSelected {
                Rectangle().fill(colors.accentGreen).frame(width: 2)
            }
        }
        .onTapGesture { action() }
    }
}

// MARK: - Track List

private struct TrackListView: View {
    @Environment(AppState.self) private var state

    private var sortBinding: Binding<AppState.SortField?> {
        Binding(
            get: { state.sortBy },
            set: { newValue in
                if let newValue = newValue { state.sortBy = newValue }
            }
        )
    }

    var body: some View {
        let colors = state.colors

        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Text("\u{1F50D}")
                        .font(.system(size: 11))
                    TextField("Search tracks, artists, albums...", text: state.$searchQuery)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(colors.textPrimary)
                }
                .padding(8)
                .background(colors.inputBg)
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(colors.inputBorder, style: StrokeStyle(width: 1))
                }
                .cornerRadius(5)

                Picker(of: AppState.SortField.allCases, selection: sortBinding)
                    .pickerStyle(.menu)
                    .frame(width: 120)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Rectangle().fill(colors.border).frame(height: 1)

            ScrollView {
                VStack(spacing: 4) {
                    ForEach(state.filteredTracks) { track in
                        TrackRow(track: track, isSelected: state.selectedTrackId == track.id) {
                            state.selectTrack(track)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 280)

            Rectangle().fill(colors.border).frame(height: 1)
            HStack {
                Spacer()
                Text("Showing \(state.filteredTracks.count) of \(state.tracks.count) tracks")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(colors.textMuted)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(colors.footerBg)
        }
    }
}

private struct TrackRow: View {
    @Environment(AppState.self) private var state
    let track: Track
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        let colors = state.colors

        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(track.name)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(colors.textPrimary)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Text(track.artist)
                    if !track.album.isEmpty {
                        Text("\u{2022}").foregroundColor(colors.textDisabled)
                        Text(track.album)
                    }
                }
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(colors.textSecondary)
                .lineLimit(1)

                HStack(spacing: 8) {
                    if track.bpm > 0 {
                        Text(String(format: "%.1f BPM", track.bpm))
                    }
                    if !track.tonality.isEmpty {
                        Text(track.tonality)
                    }
                    Text("\(track.cueCount) cues")
                        .foregroundColor(colors.accentGreen)
                }
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(colors.textMuted)
            }

            Spacer()

            Text(track.formattedDuration)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(colors.textSecondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            isSelected
                ? colors.accentGreen.opacity(0.2)
                : (isHovered ? colors.accentGreen.opacity(0.1) : colors.cardBg)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .stroke(
                    isSelected ? colors.accentGreen :
                        (isHovered ? colors.accentGreen.opacity(0.5) : colors.cardBorder),
                    style: StrokeStyle(width: 1)
                )
        }
        .cornerRadius(5)
        .onHover { isHovered = $0 }
        .onTapGesture { action() }
    }
}
#endif
