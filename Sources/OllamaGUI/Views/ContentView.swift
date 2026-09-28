import OllamaKit
import SwiftUI

struct ContentView: View {
    private var app: AppModel { .shared }
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        @Bindable var app = app

        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        } detail: {
            detail
        }
        .sheet(isPresented: $app.isPullSheetPresented) {
            PullModelSheet(initialName: app.pullSheetPrefill)
        }
        .sheet(item: $app.copyRequest) { request in
            CopyModelSheet(request: request)
        }
        .sheet(item: $app.createRequest) { request in
            CreateModelSheet(request: request)
        }
        .confirmationDialog(
            app.deleteRequest.map(app.deleteTitle(for:)) ?? "",
            isPresented: Binding(get: { app.deleteRequest != nil }, set: { if !$0 { app.deleteRequest = nil } }),
            titleVisibility: .visible,
            presenting: app.deleteRequest
        ) { request in
            Button("Delete", role: .destructive) {
                Task { await app.delete(request.names) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { request in
            Text(verbatim: app.deleteMessage(for: request))
        }
        .alert(
            app.errorAlert?.title ?? "",
            isPresented: Binding(get: { app.errorAlert != nil }, set: { if !$0 { app.errorAlert = nil } }),
            presenting: app.errorAlert
        ) { _ in
            Button("OK") {}
        } message: { alert in
            Text(verbatim: alert.message)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch app.section ?? .models {
        case .models: ModelsView()
        case .running: RunningView()
        case .downloads: DownloadsView()
        case .discover: DiscoverView()
        case .playground: PlaygroundView()
        }
    }
}
