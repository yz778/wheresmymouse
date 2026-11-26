import AppKit
import Foundation

private struct Failure: Error, CustomStringConvertible {
    let description: String
}

private func expect(_ condition: Bool, _ message: String) throws {
    if !condition { throw Failure(description: message) }
}

@main
struct RegressionTests {
    static func main() throws {
        try pointerStyles()
        try displayCenters()
        try updates()
        try singleInstance()
        print("Regression tests passed: pointer styles, display centers, release checks, and singleton.")
    }

    private static func pointerStyles() throws {
        let suite = "wheresmymouse.tests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = PointerStyleSettings(defaults: defaults)
        let original = PointerColors(border: 0xFF8C00, fill: 0xFFFF00)
        try expect(settings.colors == original, "Fresh installs should use an orange border and yellow fill.")
        defaults.set("retiredStyle", forKey: "pointerStyle")
        try expect(settings.colors == original, "Unknown saved styles should fall back to orange/yellow.")

        settings.style = .custom
        try expect(settings.colors == original, "Custom should start with the default colors.")
        let black = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        let teal = NSColor(srgbRed: 18.0 / 255, green: 160.0 / 255, blue: 138.0 / 255, alpha: 1)
        guard let border = PointerColors.rgb(black), let fill = PointerColors.rgb(teal) else {
            throw Failure(description: "The picker must accept sRGB colors.")
        }
        settings.customColors = PointerColors(border: border, fill: fill)
        let custom = PointerColors(border: 0x000000, fill: 0x12A08A)
        let reopened = PointerStyleSettings(defaults: UserDefaults(suiteName: suite)!)
        try expect(reopened.colors == custom, "Reopening settings must preserve both custom channels, including black.")

        reopened.style = .purpleGreen
        try expect(reopened.colors == PointerColors(border: 0x800080, fill: 0x32CD32), "Purple/green must override custom.")
        reopened.style = .redWhite
        try expect(reopened.colors == PointerColors(border: 0xFF0000, fill: 0xFFFFFF), "Red/white must override custom.")
        reopened.style = .custom
        try expect(reopened.colors == custom, "Switching presets should not erase custom colors.")
    }

    private static func displayCenters() throws {
        let primary = CGRect(x: 0, y: 0, width: 1200, height: 900)
        let left = CGRect(x: -800, y: 200, width: 800, height: 600)
        let displays = [primary, left]
        let onLeft = CGPoint(x: -50, y: 400)
        let leftCenter = CGPoint(x: -400, y: 500)
        let primaryCenter = CGPoint(x: 600, y: 450)
        try expect(DisplayCenter.target(for: onLeft, in: displays, advance: false) == leftCenter,
                   "Center should use the display under the pointer, even at negative coordinates.")
        try expect(DisplayCenter.target(for: primaryCenter, in: displays, advance: true) == leftCenter,
                   "Move should advance to the next display.")
        try expect(DisplayCenter.target(for: onLeft, in: displays, advance: true) == primaryCenter,
                   "Move should wrap to the first display.")
        try expect(DisplayCenter.target(for: primaryCenter, in: [primary], advance: true) == primaryCenter,
                   "Move with one display should center there.")
        try expect(DisplayCenter.target(for: .zero, in: [CGRect](), advance: false) == nil,
                   "Center should fail cleanly when no displays are available.")
    }

    private static func updates() throws {
        func latest(_ tag: String, installed: String) throws -> GitHubRelease? {
            try UpdateChecker.newerRelease(in: Data("{\"tag_name\":\"\(tag)\"}".utf8), installedVersion: installed)
        }
        let newer = try latest("v2.10.1", installed: "2.9")
        try expect(newer?.url.absoluteString == "https://github.com/yz778/wheresmymouse/releases/tag/v2.10.1",
                   "Compare versions numerically and link to the matching GitHub release.")
        try expect(try latest("v2.1.0", installed: "2.1") == nil, "Omitted patch should equal zero.")
        try expect(try latest("v2.1", installed: "2.1.1") == nil, "An older release must not be offered.")
        try expect(try latest("v3.0", installed: "2.99.99")?.version == "3.0", "Major versions take precedence.")
        do {
            _ = try latest("v2..1", installed: "2.1")
            throw Failure(description: "Malformed release versions must fail rather than show an update.")
        } catch let error as URLError where error.code == .cannotParseResponse {}
    }

    private static func singleInstance() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            guard let first = try InstanceLock(directory: directory) else {
                throw Failure(description: "The first instance must acquire the lock.")
            }
            try withExtendedLifetime(first) {
                try expect(try InstanceLock(directory: directory) == nil,
                           "A second instance must not acquire the lock while the first is running.")
            }
        }
        try expect(try InstanceLock(directory: directory) != nil, "The app must start again after the first instance exits.")
    }
}
