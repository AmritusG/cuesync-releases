import SwiftUI

struct BrowseSectionView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let colors = state.colors

        if state.tracks.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "music.note.list")
                    .font(.system(size: 32))
                    .foregroundStyle(colors.textDisabled)
                Text("Import tracks from Rekordbox, Serato, Engine DJ, or ShowKontrol to browse")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(colors.textMuted)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
            .background(colors.emptyStateBg)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(colors.emptyStateBorder, style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
            )
        } else {
            HStack(alignment: .top, spacing: 0) {
                // Playlist sidebar
                PlaylistSidebar()
                    .frame(minWidth: 150, idealWidth: 220, maxWidth: 220)

                Rectangle().fill(colors.border).frame(width: 1)

                // Track list
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
                .tracking(1)
                .foregroundStyle(colors.textMuted)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            ScrollView {
                VStack(spacing: 0) {
                    // All tracks
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
        Button {
            if isExpanded {
                state.expandedFolders.remove(playlist.id)
            } else {
                state.expandedFolders.insert(playlist.id)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(colors.textMuted)
                    .frame(width: 10)
                Text("\u{1F4C1}")
                    .font(.system(size: 11))
                Text(playlist.name)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(colors.textPrimary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.leading, CGFloat(12 + depth * 16))
            .padding(.vertical, 6)
            .padding(.trailing, 8)
        }
        .buttonStyle(.plain)
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
        Button(action: action) {
            HStack(spacing: 6) {
                Text(emoji)
                    .font(.system(size: 11))
                Text(name)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(isSelected ? colors.accentGreen : colors.textPrimary)
                    .lineLimit(1)
                Spacer()
                Text("\(count)")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(colors.textMuted)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(colors.countBadgeBg)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .padding(.leading, CGFloat(12 + depth * 16))
            .padding(.vertical, 6)
            .padding(.trailing, 8)
            .background(isSelected ? colors.accentGreen.opacity(0.1) : Color.clear)
            .overlay(alignment: .leading) {
                if isSelected {
                    Rectangle().fill(colors.accentGreen).frame(width: 2)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Track List

private struct TrackListView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let colors = state.colors

        VStack(spacing: 0) {
            // Search + Sort
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Text("\u{1F50D}")
                        .font(.system(size: 11))
                    TextField("Search tracks, artists, albums...", text: Bindable(state).searchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(colors.textPrimary)
                }
                .padding(8)
                .background(colors.inputBg)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(colors.inputBorder, lineWidth: 1)
                )

                Picker("Sort", selection: Bindable(state).sortBy) {
                    ForEach(AppState.SortField.allCases, id: \.self) { field in
                        Text(field.label).tag(field)
                    }
                }
                .pickerStyle(.menu)
                .font(.system(size: 10, design: .monospaced))
                .frame(width: 120)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // Track rows (max height 280, scrollable)
            ScrollView {
                LazyVStack(spacing: 4) {
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

            // Footer: centered "Showing X of Y tracks" with border-top
            Divider()
            HStack {
                Spacer()
                Text("Showing \(state.filteredTracks.count) of \(state.tracks.count) tracks")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(colors.textMuted)
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
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.name)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(colors.textPrimary)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Text(track.artist)
                        if !track.album.isEmpty {
                            Text("\u{2022}").foregroundStyle(colors.textDisabled)
                            Text(track.album)
                        }
                    }
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(colors.textSecondary)
                    .lineLimit(1)

                    HStack(spacing: 8) {
                        if track.bpm > 0 {
                            Text(String(format: "%.1f BPM", track.bpm))
                        }
                        if !track.tonality.isEmpty {
                            Text(track.tonality)
                        }
                        Text("\(track.cueCount) cues")
                            .foregroundStyle(colors.accentGreen)
                    }
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(colors.textMuted)
                }

                Spacer()

                Text(track.formattedDuration)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(colors.textSecondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                isSelected
                    ? colors.accentGreen.opacity(0.2)
                    : (isHovered ? colors.accentGreen.opacity(0.1) : colors.cardBg)
            )
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(
                        isSelected ? colors.accentGreen :
                        (isHovered ? colors.accentGreen.opacity(0.5) : colors.cardBorder),
                        lineWidth: 1
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
    }
}
