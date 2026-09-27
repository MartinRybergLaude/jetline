import JetlineApp

#if os(macOS)
// The macOS app. `jetline daemon …` runs the headless daemon from the same
// binary, so a Mac can host remote clients too.
if CommandLine.arguments.dropFirst().first == "daemon" {
    JetlineDaemon.run(arguments: Array(CommandLine.arguments.dropFirst(2)))
} else {
    runJetlineApp()
}
#else
JetlineDaemon.run(arguments: Array(CommandLine.arguments.dropFirst()))
#endif
