import SwiftUI
import AppKit

/// First-launch welcome flow. Modeled on Apple's own onboarding (Music,
/// Mail, Apple Intelligence): a chromeless, fixed-size window with a hero
/// step, two feature-list steps, and a celebratory close. Paging is a
/// horizontal slide; the footer carries Back / page dots / Continue.
///
/// Lives in its own `Window` scene; `AppShell` calls `openWindow(id:)` once
/// after `state.load()` if `settings.hasCompletedOnboarding` is false, and
/// the Debug menu exposes a re-run hook for testing.
struct OnboardingView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismissWindow) private var dismissWindow

    private static let pages: [OnboardingPage] = [.hero, .workspaces, .tools, .ready]
    private static let pageSize = CGSize(width: 580, height: 640)

    @State private var pageIndex: Int = 0
    @State private var didMarkComplete = false

    var body: some View {
        VStack(spacing: 0) {
            pager
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .frame(width: Self.pageSize.width, height: Self.pageSize.height)
        .background(BackgroundLayer())
        .onAppear { markCompleteOnce() }
    }

    // MARK: - Pager

    private var pager: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            HStack(spacing: 0) {
                ForEach(Self.pages.indices, id: \.self) { idx in
                    pageView(for: Self.pages[idx])
                        .frame(width: width)
                }
            }
            .offset(x: -CGFloat(pageIndex) * width)
            .animation(.smooth(duration: 0.42), value: pageIndex)
            .frame(width: width, alignment: .leading)
        }
        .clipped()
    }

    @ViewBuilder
    private func pageView(for page: OnboardingPage) -> some View {
        switch page {
        case .hero:       HeroPage()
        case .workspaces: WorkspacesPage()
        case .tools:      ToolsPage()
        case .ready:      ReadyPage()
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button("Back") {
                guard pageIndex > 0 else { return }
                pageIndex -= 1
            }
            .controlSize(.large)
            .buttonStyle(.bordered)
            .opacity(pageIndex == 0 ? 0 : 1)
            .disabled(pageIndex == 0)
            .frame(width: 92, alignment: .leading)

            Spacer()

            PageDots(count: Self.pages.count, index: pageIndex)

            Spacer()

            Button(action: advance) {
                Text(pageIndex == Self.pages.count - 1 ? "Get Started" : "Continue")
                    .frame(minWidth: 80)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .frame(width: 92, alignment: .trailing)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 22)
        .overlay(alignment: .top) {
            Divider().opacity(0.5)
        }
    }

    private func advance() {
        if pageIndex < Self.pages.count - 1 {
            pageIndex += 1
        } else {
            dismissWindow(id: "onboarding")
        }
    }

    /// Persist the "seen" flag the first time the window appears. Doing it
    /// here (rather than only on the Get Started button) means the user
    /// won't be re-shown the flow if they close via the title-bar red dot,
    /// which would otherwise feel like nagging on every relaunch.
    private func markCompleteOnce() {
        guard !didMarkComplete, !state.settings.hasCompletedOnboarding else {
            didMarkComplete = true
            return
        }
        didMarkComplete = true
        var s = state.settings
        s.hasCompletedOnboarding = true
        state.saveSettings(s)
    }
}

// MARK: - Pages

private enum OnboardingPage {
    case hero
    case workspaces
    case tools
    case ready
}

private struct HeroPage: View {
    @State private var revealed = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            JetMark()
                .frame(width: 168, height: 168)
                .scaleEffect(revealed ? 1 : 0.92)
                .opacity(revealed ? 1 : 0)
            Text("Welcome to Jetline")
                .font(.system(size: 32, weight: .bold))
                .padding(.top, 12)
                .opacity(revealed ? 1 : 0)
                .offset(y: revealed ? 0 : 6)
            Text("Run coding agents in their own git worktrees.")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .padding(.top, 6)
                .opacity(revealed ? 1 : 0)
                .offset(y: revealed ? 0 : 6)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            withAnimation(.smooth(duration: 0.55).delay(0.05)) {
                revealed = true
            }
        }
    }
}

private struct WorkspacesPage: View {
    var body: some View {
        FeaturePageLayout(
            eyebrow: "Workspaces",
            title: "Each task in its own worktree.",
            blurb:
                "Jetline spawns a fresh git worktree for every workspace, on its own feature branch — your main checkout stays untouched."
        ) {
            FeatureRow(
                icon: "rectangle.stack.fill",
                tint: .accentColor,
                title: "A clean slate, every time",
                detail: "New workspaces get a dedicated worktree under ~/.jetline so agents can run in parallel without stepping on each other."
            )
            FeatureRow(
                icon: "arrow.down.left.and.arrow.up.right.square.fill",
                tint: .indigo,
                title: "Import what you already have",
                detail: "Spin up a workspace from any local branch or open pull request — the worktree tracks it from there."
            )
            FeatureRow(
                icon: "sparkles",
                tint: .pink,
                title: "Pick an agent per workspace",
                detail: "Claude Code, Codex, Mistral Vibe, or a plain terminal — choose whichever fits the task."
            )
        }
    }
}

private struct ToolsPage: View {
    var body: some View {
        FeaturePageLayout(
            eyebrow: "While the agent works",
            title: "Stay close to the change.",
            blurb:
                "The inspector and git action bar live alongside the terminal so you can review, ship, or course-correct without leaving the app."
        ) {
            FeatureRow(
                icon: "doc.text.magnifyingglass",
                tint: .blue,
                title: "Live inspector",
                detail: "Diff, PR status, and run-script output refresh automatically as files and remotes change."
            )
            FeatureRow(
                icon: "arrow.triangle.branch",
                tint: .orange,
                title: "One-click git actions",
                detail: "Commit, open a PR, rebase, fix CI, address review comments — the agent picks up the work."
            )
            FeatureRow(
                icon: "terminal.fill",
                tint: .green,
                title: "Setup and run scripts",
                detail: "Configure per-repo setup, run, and archive scripts; they spawn alongside your agent in a dedicated panel."
            )
        }
    }
}

private struct ReadyPage: View {
    @State private var revealed = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.accentColor.opacity(0.85), Color.accentColor.opacity(0.55)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 120, height: 120)
                    .shadow(color: Color.accentColor.opacity(0.35), radius: 24, x: 0, y: 8)
                Image(systemName: "checkmark")
                    .font(.system(size: 54, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .scaleEffect(revealed ? 1 : 0.86)
            .opacity(revealed ? 1 : 0)

            Text("You're ready to go.")
                .font(.system(size: 28, weight: .bold))
                .padding(.top, 28)
                .opacity(revealed ? 1 : 0)
                .offset(y: revealed ? 0 : 6)

            Text("Add a git repository from the sidebar to spin up your first workspace.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .padding(.top, 8)
                .opacity(revealed ? 1 : 0)
                .offset(y: revealed ? 0 : 6)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            withAnimation(.smooth(duration: 0.55).delay(0.05)) {
                revealed = true
            }
        }
    }
}

// MARK: - Building blocks

private struct FeaturePageLayout<Rows: View>: View {
    let eyebrow: String
    let title: String
    let blurb: String
    @ViewBuilder var rows: () -> Rows

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 8) {
                Text(eyebrow)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                    .tracking(0.6)
                Text(title)
                    .font(.system(size: 26, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(blurb)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 28)

            VStack(alignment: .leading, spacing: 22) {
                rows()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 48)
        .padding(.vertical, 32)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct FeatureRow: View {
    let icon: String
    let tint: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(tint)
                .frame(width: 40, alignment: .center)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct PageDots: View {
    let count: Int
    let index: Int

    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<count, id: \.self) { i in
                Circle()
                    .fill(i == index ? Color.primary.opacity(0.6) : Color.primary.opacity(0.18))
                    .frame(width: 6, height: 6)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: index)
    }
}

/// Soft top-tinted gradient — the standard window background with a faint
/// accent-color highlight near the top so the chromeless window doesn't
/// look like an empty rectangle.
private struct BackgroundLayer: View {
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(
                colors: [
                    Color.accentColor.opacity(0.10),
                    Color.accentColor.opacity(0.02),
                    Color.clear
                ],
                startPoint: .top,
                endPoint: .center
            )
            .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }
}

/// Mirrors `WelcomeView`'s logo loader — `Bundle.jetlineResources` is the
/// loose-files resource bundle, not an asset catalog, so `Image(_:bundle:)`
/// won't resolve it.
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
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.secondary)
        }
    }
}
