#!/usr/bin/env python3
"""Run the titlebar observer's actual Swift code against AppKit window teardown."""
import platform
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "Sources/Update/UpdateTitlebarAccessory.swift"


def block(source, marker):
    start = source.index(marker)
    opening = source.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


OBJC_HEADER = r"""
#import <AppKit/AppKit.h>
@interface LifecycleWindow : NSWindow
@property(copy) void (^duringDealloc)(void);
@end
@interface WindowProbe : NSView
@property(assign) NSWindow *probedWindow;
@end
"""
OBJC = r"""
#import "WindowProbe.h"
@implementation LifecycleWindow
- (void)dealloc {
    if (_duringDealloc) _duringDealloc();
    [_duringDealloc release];
    [super dealloc];
}
@end
@implementation WindowProbe
- (NSWindow *)window { return _probedWindow; }
@end
"""
SWIFT = r"""
import AppKit

@MainActor
final class ObserverHarness {
    let view = WindowProbe()
    var invalidations = 0
    __PRODUCTION_MEMBERS__

    func scheduleSizeUpdate(invalidateIntrinsicSize: Bool, invalidateLayout: Bool) {
        precondition(invalidateIntrinsicSize && invalidateLayout)
        invalidations += 1
    }

    func refresh() -> Bool { updateObservedWindowIfNeeded() }
    func stop() { removeWindowGeometryObservers() }
    var observerCount: Int { windowGeometryObservers.count }
}

__PRODUCTION_NOTIFICATIONS__

@MainActor
func makeWindow() -> LifecycleWindow {
    let window = LifecycleWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    return window
}

@MainActor
func run() {
    _ = NSApplication.shared
    let observer = ObserverHarness()
    if CommandLine.arguments.last == "dealloc" {
        var deallocated = false
        weak var releasedWindow: NSWindow?
        autoreleasepool {
            let window = makeWindow()
            releasedWindow = window
            observer.view.probedWindow = window
            precondition(observer.refresh())
            window.duringDealloc = {
                // AppKit can expose the same window while its zeroing weak reference is already nil.
                precondition(releasedWindow == nil)
                precondition(!observer.refresh())
                observer.view.probedWindow = nil
                precondition(observer.refresh())
                precondition(observer.observerCount == 0)
                deallocated = true
            }
        }
        precondition(deallocated && releasedWindow == nil, "window retained beyond its owner")
        print("PASS: refreshed during actual NSWindow deallocation; window released")
    } else {
        let first = makeWindow()
        let second = makeWindow()
        observer.view.probedWindow = first
        precondition(observer.refresh())
        precondition(!observer.refresh())
        precondition(observer.observerCount == TitlebarWindowGeometryNotifications.names.count)
        NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: first)
        precondition(observer.invalidations == 1)
        observer.view.probedWindow = second
        precondition(observer.refresh())
        NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: first)
        precondition(observer.invalidations == 1, "old window still observed")
        NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification, object: second)
        precondition(observer.invalidations == 2)
        observer.view.probedWindow = nil
        precondition(observer.refresh())
        precondition(observer.observerCount == 0)
        NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: second)
        precondition(observer.invalidations == 2, "detached view still observes its window")
        precondition(!observer.refresh())
        observer.view.probedWindow = first
        precondition(observer.refresh())
        precondition(observer.observerCount == TitlebarWindowGeometryNotifications.names.count)
        precondition(!observer.refresh())
        NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: first)
        precondition(observer.invalidations == 3, "reattached window has duplicate observers")
        observer.view.probedWindow = nil
        precondition(observer.refresh())
        print("PASS: resize, unchanged identity, changed window, nil detach and reattach")
    }
    observer.stop()
}
run()
"""


@unittest.skipUnless(platform.system() == "Darwin" and shutil.which("swiftc"),
                     "requires macOS AppKit and the Swift compiler")
class TitlebarWindowLifecycleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory(prefix="cmux-titlebar-lifecycle-")
        cls.addClassCleanup(cls.directory.cleanup)
        directory = Path(cls.directory.name)
        source = SOURCE.read_text()
        owner = source[source.index("final class TitlebarControlsAccessoryViewController"):
                       source.index("private func scheduleSizeUpdate(")]
        properties = [line.strip() for line in owner.splitlines()
                      if line.strip().startswith(("private weak var observedWindow:",
                                                  "private var observedWindowIdentifier:",
                                                  "private var windowGeometryObservers:"))]
        members = properties + [block(owner, "private func updateObservedWindowIfNeeded()"),
                                block(owner, "private func removeWindowGeometryObservers()")]
        if "private func setObservedWindow(" in owner:
            members.append(block(owner, "private func setObservedWindow("))
        harness = SWIFT.replace("__PRODUCTION_MEMBERS__", "\n".join(members)).replace(
            "__PRODUCTION_NOTIFICATIONS__", block(source, "enum TitlebarWindowGeometryNotifications"))
        (directory / "WindowProbe.h").write_text(OBJC_HEADER)
        (directory / "WindowProbe.m").write_text(OBJC)
        (directory / "main.swift").write_text(harness)
        cls.binary = directory / "lifecycle"
        for command in (
            ["clang", "-fno-objc-arc", "-fblocks", "-c", str(directory / "WindowProbe.m"),
             "-o", str(directory / "WindowProbe.o")],
            ["swiftc", "-swift-version", "6", "-import-objc-header", str(directory / "WindowProbe.h"),
             str(directory / "main.swift"), str(directory / "WindowProbe.o"), "-o", str(cls.binary)],
        ):
            result = subprocess.run(command, capture_output=True, text=True, timeout=60)
            if result.returncode:
                raise RuntimeError(result.stdout + result.stderr)

    def check_scenario(self, scenario):
        result = subprocess.run([str(self.binary), scenario], capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("PASS:", result.stdout)
        print(result.stdout.strip())

    def test_refresh_during_window_deallocation(self):
        self.check_scenario("dealloc")

    def test_geometry_observer_lifecycle(self):
        self.check_scenario("geometry")


if __name__ == "__main__":
    unittest.main()
