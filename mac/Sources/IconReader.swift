// macOS host for the Deskland Preview theme pages (GPL-3.0, see LICENSE).
// Reads where Finder has drawn the desktop icons. Finder exposes the desktop through the
// Accessibility API as: application → scroll area ("desktop") → group → one image per icon,
// each with a position and size in global screen points (origin top-left of the primary display).
// Needs the Accessibility permission; until it is granted nothing is reported.

import Cocoa
import ApplicationServices

struct IconSnapshot: Equatable {
    var visible: Bool
    var rects: [CGRect]
}

final class IconReader {
    /// Called on the main queue whenever the set of icon rectangles changes.
    var onChange: ((IconSnapshot) -> Void)?

    private let queue = DispatchQueue(label: "icon-reader", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var mouseMonitor: Any?
    private var last: IconSnapshot?
    private var lastPoll = Date.distantPast
    private var burstUntil = Date.distantPast
    private var finderPID: pid_t = 0
    private var finder: AXUIElement?
    private var container: AXUIElement?
    private var wasTrusted = false
    private var loggedShape = false

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system dialog that sends the user to Privacy & Security → Accessibility.
    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    func start() {
        // Icons only move when the user lets go of something, so poll fast for a moment after a
        // mouse-up and slowly otherwise. Global mouse monitoring needs no extra permission.
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp]) { [weak self] _ in
            self?.kick()
        }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.2, repeating: 0.25, leeway: .milliseconds(50))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
        if let m = mouseMonitor { NSEvent.removeMonitor(m) }
        mouseMonitor = nil
    }

    /// Poll quickly for the next few seconds.
    func kick() {
        queue.async { self.burstUntil = Date().addingTimeInterval(3) }
    }

    private func tick() {
        let now = Date()
        guard now < burstUntil || now.timeIntervalSince(lastPoll) >= 1.0 else { return }
        lastPoll = now
        let trusted = AXIsProcessTrusted()
        if trusted != wasTrusted {
            wasTrusted = trusted
            Log.write(trusted ? "Accessibility access granted, reading desktop icons" : "no Accessibility access, icons cannot be read")
            finder = nil
            container = nil
        }
        guard trusted, let snap = read(), snap != last else { return }
        last = snap
        burstUntil = now.addingTimeInterval(2)
        if let f = snap.rects.first {
            Log.write("icons changed: \(snap.rects.count), visible=\(snap.visible), first=\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))")
        } else {
            Log.write("icons changed: 0, visible=\(snap.visible)")
        }
        DispatchQueue.main.async { self.onChange?(snap) }
    }

    private func attribute(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success ? value : nil
    }

    private func children(_ el: AXUIElement) -> [AXUIElement]? {
        attribute(el, kAXChildrenAttribute as String) as? [AXUIElement]
    }

    private func role(_ el: AXUIElement) -> String? {
        attribute(el, kAXRoleAttribute as String) as? String
    }

    /// Role and frame of one element in a single round trip to Finder.
    private func roleAndFrame(_ el: AXUIElement) -> (String, CGRect)? {
        let names = [kAXRoleAttribute as String, kAXPositionAttribute as String, kAXSizeAttribute as String] as CFArray
        var out: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(el, names, AXCopyMultipleAttributeOptions(rawValue: 0), &out) == .success,
              let values = out as? [AnyObject], values.count == 3,
              let role = values[0] as? String,
              CFGetTypeID(values[1]) == AXValueGetTypeID(), CFGetTypeID(values[2]) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(values[1] as! AXValue, .cgPoint, &origin),
              AXValueGetValue(values[2] as! AXValue, .cgSize, &size) else { return nil }
        return (role, CGRect(origin: origin, size: size))
    }

    /// The element whose children are the desktop icons.
    private func findContainer(_ app: AXUIElement) -> AXUIElement? {
        guard let top = children(app) else { return nil }
        for el in top where role(el) == (kAXScrollAreaRole as String) {
            let kids = children(el) ?? []
            if let group = kids.first(where: { role($0) == (kAXGroupRole as String) }) { return group }
            return el
        }
        return nil
    }

    /// nil means "could not tell" (Finder busy or restarting), which leaves the last state alone.
    private func read() -> IconSnapshot? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else {
            return IconSnapshot(visible: false, rects: [])
        }
        if finder == nil || app.processIdentifier != finderPID {
            finderPID = app.processIdentifier
            let el = AXUIElementCreateApplication(finderPID)
            AXUIElementSetMessagingTimeout(el, 1.5)
            finder = el
            container = nil
        }
        guard let finder = finder else { return nil }
        if container == nil {
            guard children(finder) != nil else { return nil }          // Finder is not answering yet
            container = findContainer(finder)
            if container == nil {
                // Finder is running without a desktop (icons turned off): the whole screen is scenery.
                return IconSnapshot(visible: false, rects: [])
            }
        }
        guard let container = container, let items = children(container) else {
            self.container = nil
            return nil
        }
        var rects: [CGRect] = []
        rects.reserveCapacity(items.count)
        var roles = Set<String>()
        for item in items {
            guard let (role, frame) = roleAndFrame(item) else { continue }
            roles.insert(role)
            if role == (kAXImageRole as String), frame.width > 1, frame.height > 1 { rects.append(frame) }
        }
        if !loggedShape, !items.isEmpty {
            loggedShape = true
            Log.write("Finder desktop: \(items.count) elements, roles \(roles.sorted().joined(separator: ","))")
        }
        rects.sort { $0.minY != $1.minY ? $0.minY < $1.minY : $0.minX < $1.minX }   // Finder's order is not stable
        return IconSnapshot(visible: true, rects: rects)
    }
}
