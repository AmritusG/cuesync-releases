import CueSyncCore

// Placeholder entry point for the SwiftPM build. The real swift-cross-ui
// presentation layer (App/ContentView/sections) is re-hosted here one
// screen at a time in later steps; this stub only proves CueSyncCore links.
// NOTE: Models/Parsers/Exporters types are still `internal`, so this UI
// target can't reference them across the module boundary yet — exposing the
// needed surface as `public` is tracked for the UI re-hosting steps.
print("CueSync core loaded")
