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
            deleteTitle,
            isPresented: Binding(get: { app.deleteRequest != nil }, set: { if !$0 { app.deleteRequest = nil } }),
            titleVisibility: .visible,
            presenting: app.deleteRequest
        ) { request in
            Button("Delete", role: .destructive) {
                Task { await app.delete(request.names) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { request in
            Text(deleteMessage(for: request))
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

    private var deleteTitle: String {
        guard let request = app.deleteRequest else { return "" }
        if request.names.count == 1, let name = request.names.first {
            return String(localized: "Delete “\(name)”?")
        }
        return String(localized: "Delete \(request.names.count) models?")
    }

    private func deleteMessage(for request: DeleteRequest) -> String {
        let models = request.names.compactMap(app.model(named:))
        let size = models.filter { !$0.isCloud }.reduce(0) { $0 + $1.size }
        if size > 0 {
            return String(localized: "This frees \(Format.bytes(size)) of disk space. Deleted models can be pulled again at any time.")
        }
        return String(localized: "Deleted models can be pulled again at any time.")
    }
}
