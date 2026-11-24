import AppKit

if let flag = CommandLine.arguments.firstIndex(of: "--snapshot") {
    exit(Snapshot.run(arguments: Array(CommandLine.arguments[(flag + 1)...])))
}

if let flag = CommandLine.arguments.firstIndex(of: "--icon") {
    exit(Snapshot.icon(arguments: Array(CommandLine.arguments[(flag + 1)...])))
}

if let flag = CommandLine.arguments.firstIndex(of: "--ask") {
    exit(AskPreview.ask(arguments: Array(CommandLine.arguments[(flag + 1)...])))
}

if let flag = CommandLine.arguments.firstIndex(of: "--ask-preview") {
    exit(AskPreview.preview(arguments: Array(CommandLine.arguments[(flag + 1)...])))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
