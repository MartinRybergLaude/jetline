import SwiftUI

/// Single sheet that hosts the three workspace-creation flows (new branch,
/// import remote branch, import PR) behind a capsule tab bar matching the
/// inspector's. Tabs that don't apply to the repo (PR import on a non-GitHub
/// remote) are filtered out.
struct WorkspaceCreationSheet: View {
    @EnvironmentObject private var state: AppState
    let repository: Repository

    @State private var tab: Tab = .new

    enum Tab: Hashable { case new, importBranch, importPR }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(repository.name)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }

            CapsuleTabs(
                selection: $tab,
                tabs: visibleTabs,
                height: 28,
                help: { Self.help(for: $0) }
            ) { tab, _ in
                Text(Self.title(for: tab))
                    .font(.system(size: 12, weight: .semibold))
            }

            pane
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(20)
        .frame(minWidth: 540, idealWidth: 580, minHeight: 540, idealHeight: 580)
        .onAppear {
            // Force an immediate fetch+FF so "New" branches off a fresh
            // tip and "Import branch" lists current remote refs, instead
            // of waiting for the next 20s poll.
            state.prTracker.kick(repoId: repository.id)
        }
    }

    @ViewBuilder
    private var pane: some View {
        switch tab {
        case .new:           NewWorkspacePane(repository: repository)
        case .importBranch:  ImportBranchPane(repository: repository)
        case .importPR:      ImportPRPane(repository: repository)
        }
    }

    private var visibleTabs: [Tab] {
        let hasGitHub = state.repoMetadataByRepo[repository.id] != nil
        return hasGitHub ? [.new, .importBranch, .importPR] : [.new, .importBranch]
    }

    private static func title(for tab: Tab) -> String {
        switch tab {
        case .new:          return "New"
        case .importBranch: return "Import branch"
        case .importPR:     return "Import PR"
        }
    }

    private static func help(for tab: Tab) -> String? {
        switch tab {
        case .new:          return "Create a new branch off the default branch"
        case .importBranch: return "Open an existing remote branch as a workspace"
        case .importPR:     return "Open a pull request as a workspace"
        }
    }
}
