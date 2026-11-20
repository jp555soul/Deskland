// macOS host for the Deskland Preview theme pages (GPL-3.0, see LICENSE).
// Entry point. With no arguments: start the wallpaper and open Settings (or just open Settings
// if already running). --autostart starts quietly. --settings / --menu / --exit talk to the
// running copy.

import Cocoa

let launchArguments = Array(CommandLine.arguments.dropFirst())
let launchCommand: String? = launchArguments.contains("--exit") ? "exit"
    : launchArguments.contains("--settings") ? "settings"
    : launchArguments.contains("--menu") ? "menu" : nil
let fromLogin = launchArguments.contains("--autostart")
let myPID = ProcessInfo.processInfo.processIdentifier
let alreadyRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: App.bundleID)
    .filter { $0.processIdentifier != myPID }.isEmpty

func tellRunningCopy(_ what: String) {
    DistributedNotificationCenter.default().postNotificationName(App.commandNotification, object: what, userInfo: nil, deliverImmediately: true)
    RunLoop.current.run(until: Date().addingTimeInterval(0.3))
}

if let launchCommand = launchCommand {
    if alreadyRunning { tellRunningCopy(launchCommand) }
    exit(0)
}
if alreadyRunning {
    if !fromLogin { tellRunningCopy("settings") }
    exit(0)
}

let application = NSApplication.shared
let appDelegate = AppDelegate(showSettings: !fromLogin)
application.delegate = appDelegate
application.setActivationPolicy(.accessory)
application.run()
