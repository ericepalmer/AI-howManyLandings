import Foundation

enum AppBuild {
    static var number: String {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        if let build, !build.isEmpty { return build }
        return "0"
    }

    static var label: String { "Build \(number)" }
}
