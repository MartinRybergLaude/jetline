import SwiftUI

struct InspectorView: View {
    @EnvironmentObject private var state: AppState
    @State private var tab: Tab = .changes

    enum Tab: Hashable { case changes, pr }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                Group {
                    switch tab {
                    case .changes: ChangesPanel()
                    case .pr:      PRPanel()
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        Picker("", selection: $tab) {
            Text("Changes").tag(Tab.changes)
            Text("PR").tag(Tab.pr)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
