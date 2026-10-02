import Foundation

/// This fork’s repository and upstream attribution (shown in Settings / About).
enum ForkMetadata {
    static let repository = "codewise26/toknotch"
    static let upstreamRepository = "ReffWu/toknotch"

    static var repositoryURL: URL {
        URL(string: "https://github.com/\(repository)")!
    }

    static var upstreamRepositoryURL: URL {
        URL(string: "https://github.com/\(upstreamRepository)")!
    }

    /// Sparkle appcast on the latest GitHub release (populated when you publish).
    static var appcastURL: URL {
        URL(string: "https://github.com/\(repository)/releases/latest/download/appcast.xml")!
    }
}
