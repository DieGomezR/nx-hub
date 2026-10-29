import SwiftUI

/// nxnative: its updates and the builds, in one page
struct NXNativePage: View {
    @Environment(AppModel.self) private var model
    @State private var tab = 0

    var body: some View {
        PageShell(title: "nxnative", systemImage: "arrow.triangle.2.circlepath") {
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    Text("Updates").tag(0)
                    Text(LF("Builds (%lld)", model.builds.jobs.count)).tag(1)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .padding(.bottom, 6)
                if tab == 0 { UpdatesView(showBuilds: { tab = 1 }) }
                else { BuildsView() }
            }
        }
        .onAppear { if model.builds.current != nil && model.repo.incoming.isEmpty { tab = 1 } }
    }
}
