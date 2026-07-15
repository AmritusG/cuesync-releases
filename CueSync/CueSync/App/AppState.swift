#if canImport(AppKit)
import SwiftUI
import Combine

@Observable
final class AppState {
    // MARK: - Project
    var projectName: String = "Untitled Project"
    var projectFileURL: URL?
    var hasUnsavedChanges: Bool = false

    // MARK: - Library
    var tracks: [Track] = []
    var playlists: [Playlist] = []

    // MARK: - Browse
    var selectedPlaylistId: String = "all"
    var searchQuery: String = ""
    var sortBy: SortField = .name
    var expandedFolders: Set<String> = []

    // MARK: - Envelope
    var selectedTrackId: String?
    var cuePoints: [CuePoint] = []
    var trackDuration: Double = 60.0
    var presetName: String = "New Envelope"
    var selectedPointIndex: Int?
    var lockXAxis: Bool = true
    var lockYAxis: Bool = false
    var forceYZeroOnImport: Bool = false

    // MARK: - UI
    var theme: AppTheme = .dark
    var collapsedSections: Set<String> = []
    var sectionOrder: [String] = ["project", "browse", "configure", "export"]
    var sideBySideMode: Bool = false
    var sectionColumns: [String: String] = [
        "project": "left", "browse": "left",
        "configure": "right", "export": "right"
    ]
    var draggedSection: String?
    var preDragSectionOrder: [String]?

    static let defaultSectionOrder = ["project", "browse", "configure", "export"]
    static let defaultSectionColumns: [String: String] = [
        "project": "left", "browse": "left",
        "configure": "right", "export": "right"
    ]

    var leftColumnSections: [String] {
        sectionOrder.filter { sectionColumns[$0] == "left" }
    }
    var rightColumnSections: [String] {
        sectionOrder.filter { sectionColumns[$0] == "right" }
    }

    // MARK: - Unsaved Changes Dialog
    var showUnsavedAlert = false
    var pendingAction: (() -> Void)?

    // MARK: - Undo
    private var undoStack: [UndoState] = []
    private var redoStack: [UndoState] = []
    private let maxUndoStates = 50

    var colors: ThemeColors {
        ThemeColors.colors(for: theme)
    }

    enum SortField: String, CaseIterable {
        case name, artist, album, bpm, duration, cues

        var label: String {
            switch self {
            case .name: return "Name"
            case .artist: return "Artist"
            case .album: return "Album"
            case .bpm: return "BPM"
            case .duration: return "Duration"
            case .cues: return "Cue Count"
            }
        }
    }

    // MARK: - Computed

    var selectedTrack: Track? {
        tracks.first(where: { $0.id == selectedTrackId })
    }

    var filteredTracks: [Track] {
        var result = tracks

        // Filter by playlist
        if selectedPlaylistId != "all" {
            let ids = trackIdsForPlaylist(selectedPlaylistId)
            result = result.filter { ids.contains($0.id) }
        }

        // Filter by search
        if !searchQuery.isEmpty {
            let q = searchQuery.lowercased()
            result = result.filter {
                $0.name.lowercased().contains(q) ||
                $0.artist.lowercased().contains(q) ||
                $0.album.lowercased().contains(q)
            }
        }

        // Sort
        switch sortBy {
        case .name:     result.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .artist:   result.sort { $0.artist.localizedCaseInsensitiveCompare($1.artist) == .orderedAscending }
        case .album:    result.sort { $0.album.localizedCaseInsensitiveCompare($1.album) == .orderedAscending }
        case .bpm:      result.sort { $0.bpm < $1.bpm }
        case .duration: result.sort { $0.totalTime < $1.totalTime }
        case .cues:     result.sort { $0.cueCount > $1.cueCount }
        }

        return result
    }

    var xmlPreview: String {
        ResolumeExporter.generate(
            cuePoints: cuePoints,
            trackDuration: trackDuration,
            presetName: presetName
        ) ?? ""
    }

    // MARK: - Actions

    func selectTrack(_ track: Track) {
        pushUndo()
        selectedTrackId = track.id
        cuePoints = track.cuePoints.map { $0.sanitized() }
        trackDuration = AppState.safeDuration(Double(track.totalTime))
        presetName = track.name
        selectedPointIndex = nil
        ensureStartAndEndPoints()
        hasUnsavedChanges = true
    }

    func createBlankEnvelope() {
        pushUndo()
        selectedTrackId = nil
        cuePoints = [
            CuePoint.makeDefault(at: 0, name: "Start"),
            CuePoint.makeDefault(at: trackDuration, name: "End"),
        ]
        presetName = "New Envelope"
        selectedPointIndex = nil
        hasUnsavedChanges = true
    }

    func addCuePoint(at time: Double, yValue: Double = 0) {
        pushUndo()
        let cue = CuePoint(
            id: UUID().uuidString,
            start: min(max(time, 0), trackDuration),
            name: "Cue \(cuePoints.count + 1)",
            color: "#1ed760",
            yValue: min(max(yValue, 0), 100),
            curve: 1,
            enabled: true
        ).sanitized()   // time/yValue may be NaN (e.g. "nan" typed into Add Cue fields)
        cuePoints.append(cue)
        cuePoints.sort { $0.start < $1.start }
        selectedPointIndex = cuePoints.firstIndex(where: { $0.id == cue.id })
        hasUnsavedChanges = true
    }

    /// Duplicate the selected cue point with a time offset in milliseconds.
    /// Useful for building sharp envelope edges (e.g. +10ms and -10ms around a cue).
    func duplicateSelectedWithOffset(offsetMs: Int) {
        guard let idx = selectedPointIndex, idx < cuePoints.count else { return }
        let source = cuePoints[idx]
        let newTime = source.start + Double(offsetMs) / 1000.0
        // Clamp to valid range and don't place outside track
        let clampedTime = min(max(newTime, 0), trackDuration)
        // Don't add if a cue already exists very close
        let exists = cuePoints.contains { abs($0.start - clampedTime) < 0.0005 }
        guard !exists else { return }

        pushUndo()
        let newCue = CuePoint(
            id: UUID().uuidString,
            start: clampedTime,
            name: "\(source.name) \(offsetMs > 0 ? "+" : "")\(offsetMs)ms",
            color: source.color,
            yValue: source.yValue,
            curve: source.curve,
            enabled: true
        ).sanitized()
        cuePoints.append(newCue)
        cuePoints.sort { $0.start < $1.start }
        selectedPointIndex = cuePoints.firstIndex(where: { $0.id == newCue.id })
        hasUnsavedChanges = true
    }

    var canRemoveSelectedPoint: Bool {
        guard let idx = selectedPointIndex, idx < cuePoints.count else { return false }
        return idx != 0 && idx != cuePoints.count - 1
    }

    func removeSelectedPoint() {
        guard canRemoveSelectedPoint,
              let idx = selectedPointIndex, idx < cuePoints.count else { return }
        pushUndo()
        cuePoints.remove(at: idx)
        selectedPointIndex = nil
        hasUnsavedChanges = true
    }

    func updateCuePoint(at index: Int, _ transform: (inout CuePoint) -> Void) {
        guard index >= 0, index < cuePoints.count else { return }
        pushUndo()
        transform(&cuePoints[index])
        // The transform takes raw edits from the cue table (a StepperField can hand back
        // NaN/Inf or an out-of-range curve); re-clamp so bad input can't reach the canvas/export.
        cuePoints[index] = cuePoints[index].sanitized()
        hasUnsavedChanges = true
    }

    /// Update without pushing undo — use for continuous drag operations.
    /// Call pushUndoSnapshot() once before the drag starts.
    func updateCuePointSilently(at index: Int, _ transform: (inout CuePoint) -> Void) {
        guard index >= 0, index < cuePoints.count else { return }
        transform(&cuePoints[index])
        cuePoints[index] = cuePoints[index].sanitized()
        hasUnsavedChanges = true
    }

    func pushUndoSnapshot() {
        pushUndo()
    }

    func loadRekordbox(from url: URL) throws {
        let data = try Data(contentsOf: url)
        guard let xmlString = String(data: data, encoding: .utf8) else {
            throw ParseError.invalidFormat("Could not read file as UTF-8")
        }
        let result = try RekordboxParser.parse(xml: xmlString)
        pushUndo()
        tracks = applyYZeroIfNeeded(to: result.tracks)
        playlists = result.playlists
        hasUnsavedChanges = true
    }

    /// Returns true if duration was auto-detected from cue timing, false if user needs to set it
    @discardableResult
    func loadShowKontrol(from url: URL) throws -> Bool {
        let content = try String(contentsOf: url, encoding: .utf8)
        let result = try ShowKontrolParser.parse(content: content)
        pushUndo()
        cuePoints = result.cuePoints
        applyYZeroIfNeeded(to: &cuePoints)
        if let dur = result.suggestedDurationMs {
            trackDuration = AppState.safeDuration(dur / 1000.0)
        }
        selectedTrackId = nil
        ensureStartAndEndPoints()
        hasUnsavedChanges = true
        return result.durationFromCues
    }

    func loadSerato(from urls: [URL]) {
        let result = SeratoParser.parseFiles(at: urls)
        guard !result.tracks.isEmpty else { return }
        pushUndo()
        tracks.append(contentsOf: applyYZeroIfNeeded(to: result.tracks))
        hasUnsavedChanges = true
    }

    func loadEngineDJ(from url: URL) throws {
        let result = try EngineDJParser.parse(databaseURL: url)
        guard !result.isEmpty else {
            throw ParseError.noData
        }
        pushUndo()
        tracks = applyYZeroIfNeeded(to: result)
        hasUnsavedChanges = true
    }

    func loadResolumeEnvelope(from url: URL, duration: Double) throws {
        let data = try Data(contentsOf: url)
        guard let xmlString = String(data: data, encoding: .utf8) else {
            throw ParseError.invalidFormat("Could not read file as UTF-8")
        }
        let result = try ResolumeParser.parse(xml: xmlString)
        let safe = AppState.safeDuration(duration)
        pushUndo()
        presetName = result.presetName
        trackDuration = safe
        cuePoints = ResolumeParser.convertToCuePoints(points: result.points, duration: safe)
        applyYZeroIfNeeded(to: &cuePoints)
        selectedTrackId = nil
        ensureStartAndEndPoints()
        hasUnsavedChanges = true
    }

    // MARK: - Import Settings

    /// When `forceYZeroOnImport` is on, set every cue's yValue to 0.
    /// Driven by the Project section's Import Settings toggle.
    private func applyYZeroIfNeeded(to cues: inout [CuePoint]) {
        guard forceYZeroOnImport else { return }
        for i in cues.indices { cues[i].yValue = 0 }
    }

    private func applyYZeroIfNeeded(to tracks: [Track]) -> [Track] {
        guard forceYZeroOnImport else { return tracks }
        return tracks.map { track in
            var t = track
            for i in t.cuePoints.indices { t.cuePoints[i].yValue = 0 }
            return t
        }
    }

    func confirmNewProject() {
        if hasUnsavedChanges {
            pendingAction = { [self] in newProject() }
            showUnsavedAlert = true
        } else {
            newProject()
        }
    }

    func confirmAction(_ action: @escaping () -> Void) {
        if hasUnsavedChanges {
            pendingAction = action
            showUnsavedAlert = true
        } else {
            action()
        }
    }

    func executePendingAction() {
        pendingAction?()
        pendingAction = nil
    }

    /// Clamp a proposed track/envelope duration to a finite, positive, Int-safe value.
    /// Falls back to 60s for non-finite or non-positive input (e.g. a 0-length track,
    /// an audio file with a 0 sample rate, or `nan` typed into the duration dialog) and
    /// caps the upper bound so downstream `Int(duration …)` conversions can never overflow.
    static func safeDuration(_ d: Double) -> Double {
        guard d.isFinite, d > 0 else { return 60 }
        return Swift.min(d, 1_000_000_000)
    }

    func updateDurationWithScaling(_ newDuration: Double) {
        let target = AppState.safeDuration(newDuration)
        guard trackDuration.isFinite, trackDuration > 0 else {
            trackDuration = target
            return
        }
        let scale = target / trackDuration
        pushUndo()
        for i in cuePoints.indices {
            cuePoints[i].start *= scale
            cuePoints[i] = cuePoints[i].sanitized()
        }
        trackDuration = target
        hasUnsavedChanges = true
    }

    func newProject() {
        projectName = "Untitled Project"
        projectFileURL = nil
        tracks = []
        playlists = []
        cuePoints = []
        selectedTrackId = nil
        selectedPointIndex = nil
        trackDuration = 60.0
        presetName = "New Envelope"
        searchQuery = ""
        selectedPlaylistId = "all"
        hasUnsavedChanges = false
        undoStack.removeAll()
        redoStack.removeAll()
    }

    func saveProject(to url: URL) throws {
        let project = Project(
            version: "3.0",
            name: projectName,
            savedAt: ISO8601DateFormatter().string(from: Date()),
            tracks: tracks,
            playlists: playlists,
            selectedTrackId: selectedTrackId,
            cuePoints: cuePoints,
            trackDuration: trackDuration,
            presetName: presetName
        )
        let data = try JSONEncoder.prettyEncoder.encode(project)
        try data.write(to: url)
        projectFileURL = url
        hasUnsavedChanges = false
    }

    func loadProject(from url: URL) throws {
        let data = try Data(contentsOf: url)
        let project = try JSONDecoder().decode(Project.self, from: data)
        projectName = project.name
        // A hand-edited .cueproj can carry negative/huge/non-finite cue values and a bad
        // duration; sanitize everything so it can never crash the canvas or the exporters.
        tracks = project.tracks.map { track in
            var t = track
            t.cuePoints = t.cuePoints.map { $0.sanitized() }
            return t
        }
        playlists = project.playlists
        selectedTrackId = project.selectedTrackId
        cuePoints = project.cuePoints.map { $0.sanitized() }
        trackDuration = AppState.safeDuration(project.trackDuration)
        presetName = project.presetName
        projectFileURL = url
        ensureStartAndEndPoints()
        hasUnsavedChanges = false
        undoStack.removeAll()
        redoStack.removeAll()
    }

    // MARK: - Undo/Redo

    private struct UndoState {
        let cuePoints: [CuePoint]
        let trackDuration: Double
        let presetName: String
        let selectedTrackId: String?
        let tracks: [Track]
        let playlists: [Playlist]
    }

    private func pushUndo() {
        let state = UndoState(
            cuePoints: cuePoints,
            trackDuration: trackDuration,
            presetName: presetName,
            selectedTrackId: selectedTrackId,
            tracks: tracks,
            playlists: playlists
        )
        undoStack.append(state)
        if undoStack.count > maxUndoStates {
            undoStack.removeFirst()
        }
        redoStack.removeAll()
    }

    func undo() {
        guard let state = undoStack.popLast() else { return }
        let current = UndoState(
            cuePoints: cuePoints,
            trackDuration: trackDuration,
            presetName: presetName,
            selectedTrackId: selectedTrackId,
            tracks: tracks,
            playlists: playlists
        )
        redoStack.append(current)
        apply(state)
    }

    func redo() {
        guard let state = redoStack.popLast() else { return }
        let current = UndoState(
            cuePoints: cuePoints,
            trackDuration: trackDuration,
            presetName: presetName,
            selectedTrackId: selectedTrackId,
            tracks: tracks,
            playlists: playlists
        )
        undoStack.append(current)
        apply(state)
    }

    private func apply(_ state: UndoState) {
        cuePoints = state.cuePoints
        trackDuration = state.trackDuration
        presetName = state.presetName
        selectedTrackId = state.selectedTrackId
        tracks = state.tracks
        playlists = state.playlists
        selectedPointIndex = nil
    }

    // MARK: - Envelope Integrity

    /// Ensures cue points exist at start (0) and end (trackDuration) for Resolume compatibility.
    /// Resolume requires envelope points at x=0 and x=1.
    private func ensureStartAndEndPoints() {
        guard trackDuration > 0 else { return }
        cuePoints.sort { $0.start < $1.start }

        let hasStart = cuePoints.contains { $0.start <= 0.001 }
        if !hasStart {
            cuePoints.insert(
                CuePoint(id: UUID().uuidString, start: 0, name: "Start",
                         color: "#1ed760", yValue: 0, curve: 1, enabled: true),
                at: 0
            )
        }

        let hasEnd = cuePoints.contains { $0.start >= trackDuration - 0.001 }
        if !hasEnd {
            cuePoints.append(
                CuePoint(id: UUID().uuidString, start: trackDuration, name: "End",
                         color: "#1ed760", yValue: 0, curve: 1, enabled: true)
            )
        }

        cuePoints.sort { $0.start < $1.start }
    }

    // MARK: - Preferences

    func loadPreferences() {
        if let raw = UserDefaults.standard.string(forKey: "theme"),
           let t = AppTheme(rawValue: raw) { theme = t }
        if let order = UserDefaults.standard.stringArray(forKey: "sectionOrder") {
            sectionOrder = order
        }
        if let collapsed = UserDefaults.standard.stringArray(forKey: "collapsedSections") {
            collapsedSections = Set(collapsed)
        }
        sideBySideMode = UserDefaults.standard.bool(forKey: "sideBySideMode")
        forceYZeroOnImport = UserDefaults.standard.bool(forKey: "forceYZeroOnImport")
        if let cols = UserDefaults.standard.dictionary(forKey: "sectionColumns") as? [String: String],
           Self.defaultSectionOrder.allSatisfy({ cols[$0] != nil }) {
            sectionColumns = cols
        } else {
            sectionColumns = Self.defaultSectionColumns
        }
    }

    func savePreferences() {
        UserDefaults.standard.set(theme.rawValue, forKey: "theme")
        UserDefaults.standard.set(sectionOrder, forKey: "sectionOrder")
        UserDefaults.standard.set(Array(collapsedSections), forKey: "collapsedSections")
        UserDefaults.standard.set(sideBySideMode, forKey: "sideBySideMode")
        UserDefaults.standard.set(forceYZeroOnImport, forKey: "forceYZeroOnImport")
        UserDefaults.standard.set(sectionColumns, forKey: "sectionColumns")
    }

    func resetLayout() {
        sideBySideMode = false
        sectionOrder = Self.defaultSectionOrder
        sectionColumns = Self.defaultSectionColumns
        savePreferences()
    }

    // MARK: - Helpers

    private func trackIdsForPlaylist(_ id: String) -> Set<String> {
        func collect(_ playlist: Playlist) -> [String] {
            if playlist.id == id {
                if playlist.isFolder {
                    return playlist.children.flatMap { collect($0) }
                }
                return playlist.trackIds
            }
            return playlist.children.flatMap { collect($0) }
        }
        return Set(playlists.flatMap { collect($0) })
    }
}

// MARK: - Errors

enum ParseError: LocalizedError {
    case invalidFormat(String)
    case noData

    var errorDescription: String? {
        switch self {
        case .invalidFormat(let msg): return msg
        case .noData: return "No data found in file"
        }
    }
}

extension JSONEncoder {
    static var prettyEncoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}
#endif
