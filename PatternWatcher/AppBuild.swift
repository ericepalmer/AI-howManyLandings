import Foundation

enum AppBuild {
    static var number: String {
        if let url = Bundle.main.url(forResource: "BuildNumber", withExtension: "txt"),
           let raw = try? String(contentsOf: url, encoding: .utf8) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
           !build.isEmpty {
            return build
        }
        return "0"
    }

    static var label: String { "Build \(number)" }

    static var shortVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        if let version, !version.isEmpty { return version }
        return "1.0"
    }

    static var aboutVersionLine: String {
        "Version \(shortVersion) (Build \(number))"
    }
}
