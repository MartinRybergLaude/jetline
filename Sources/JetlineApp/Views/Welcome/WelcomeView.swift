import SwiftUI
import AppKit

struct WelcomeView: View {
    @EnvironmentObject private var state: AppState
    @State private var showingRepoSettings: Repository?

    var body: some View {
        VStack(spacing: 16) {
            JetMark()
                .frame(width: 200, height: 200)
                .padding(.bottom, -28)
            ShimmerText(text: "Jetline", font: .system(size: 28, weight: .bold).italic())
            Text(state.repositories.isEmpty
                 ? "Add a git repository to get started."
                 : "Pick a workspace, or create a new one.")
                .foregroundStyle(.secondary)
            Button {
                Task {
                    if let repo = await state.addRepository() {
                        // Mirror the sidebar's add-repo button: drop the
                        // user straight into the new repo's settings sheet
                        // so they can wire setup/run scripts before the
                        // first workspace is spawned.
                        showingRepoSettings = repo
                    }
                }
            } label: {
                Label("Add repository", systemImage: "plus")
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $showingRepoSettings) { repo in
            RepositorySettingsSheet(repository: repo)
        }
    }
}

/// One-shot metallic shimmer: a soft white band crosses the text from
/// off-screen left to off-screen right. The band animates via `.offset`
/// (which `withAnimation` reliably interpolates) and is masked to the
/// text shape; `.plusLighter` adds the highlight to whatever colour
/// `.primary` resolves to underneath.
private struct ShimmerText: View {
    let text: String
    let font: Font
    @State private var phase: CGFloat = 0

    var body: some View {
        Text(text)
            .font(font)
            .overlay {
                GeometryReader { geo in
                    let bandWidth = max(40, geo.size.width * 0.45)
                    LinearGradient(
                        colors: [.clear, .white, .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: bandWidth)
                    .offset(x: -bandWidth + phase * (geo.size.width + bandWidth))
                    .blendMode(.plusLighter)
                }
                .mask(Text(text).font(font))
                .allowsHitTesting(false)
            }
            .onAppear {
                withAnimation(.easeInOut(duration: 1.4).delay(0.35)) {
                    phase = 1
                }
            }
    }
}

/// Brand mark for the welcome screen. SwiftUI's `Image(_:bundle:)` only
/// resolves asset-catalog entries, but `Sources/JetlineApp/Resources/`
/// is processed as a loose-files bundle — load via `NSImage` like
/// `AgentMark` does.
private struct JetMark: View {
    private static let image: NSImage? = {
        Bundle.jetlineResources.url(forResource: "JetMark", withExtension: "png")
            .flatMap(NSImage.init(contentsOf:))
    }()

    var body: some View {
        if let image = Self.image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "airplane")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.secondary)
        }
    }
}
