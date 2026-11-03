import JetlineApp

#if os(macOS)
// The macOS app. `jetline daemon …` runs the headless daemon from the same
// binary, so a Mac can host remote clients too, and `jetline <tool> …` an
// agent tool.
JetlineDaemon.commandPrefix = ["daemon"]
let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "daemon" {
    JetlineDaemon.run(arguments: Array(arguments.dropFirst()))
} else if let command = arguments.first, AgentToolsCLI.handles(command) {
    AgentToolsCLI.run(argv: arguments)
} else {
    runJetlineApp()
}
#else
JetlineDaemon.run(arguments: Array(CommandLine.arguments.dropFirst()))
#endif
