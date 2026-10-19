import AppKit
import Foundation

// Headless flags (see CommandLineTool) print and exit; otherwise the menu bar app starts.
let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.contains(where: CommandLineTool.modes.contains) {
    exit(CommandLineTool.run(arguments))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
