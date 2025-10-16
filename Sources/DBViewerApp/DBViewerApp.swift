import SwiftUI
import DBViewerCore

@main
struct DBViewerApp: App {
    private let dependencies: AppDependencies
    @StateObject private var viewModel: ConnectionListViewModel

    @MainActor
    init(dependencies: AppDependencies = .live()) {
        let resolvedDependencies = dependencies
        _viewModel = StateObject(wrappedValue: resolvedDependencies.makeConnectionListViewModel())
        self.dependencies = resolvedDependencies
    }

    @MainActor
    init() {
        self.init(dependencies: .live())
    }

    var body: some Scene {
        WindowGroup {
            ConnectionListView(viewModel: viewModel)
                .frame(minWidth: 800, minHeight: 600)
        }
    }
}
