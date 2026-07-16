#if CUESYNC_CROSSUI
import SwiftCrossUI

// Intentionally empty for CUESYNC-5 (step 1 of the swift-cross-ui re-host).
// The later, screen-by-screen tickets fill this in with the same shape as
// App/ContentView.swift: Header -> ScrollView { Project, Browse, Configure,
// Export sections } -> Footer. No section, collapsible wrapper, grid overlay,
// or envelope canvas belongs here yet.
struct ContentView: View {
    var body: some View {
        Text("CUE SYNC")
    }
}
#endif
