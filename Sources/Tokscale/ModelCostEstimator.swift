import Foundation

/// API-equivalent cost for token counts when the source log has no `cost` field.
enum ModelCostEstimator {
    struct Rates: Equatable {
        var inputPerToken: Double = 0
        var outputPerToken: Double = 0
        var cacheReadPerToken: Double = 0
        var cacheWritePerToken: Double = 0
    }

    private static var cache: [String: Rates] = [:]
    private static let lock = NSLock()

    static func cost(model: String, tokens: TokenCounts) -> Double {
        let rates = rates(for: model)
        let input = Double(tokens.input) * rates.inputPerToken
        let output = Double(tokens.output) * rates.outputPerToken
        let cacheRead = Double(tokens.cacheRead) * rates.cacheReadPerToken
        let cacheWrite = Double(tokens.cacheWrite) * rates.cacheWritePerToken
        let reasoning = Double(tokens.reasoning) * rates.outputPerToken
        return input + output + cacheRead + cacheWrite + reasoning
    }

    static func rates(for model: String) -> Rates {
        lock.lock()
        if let cached = cache[model] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        if let fetched = fetchRatesFromTokscale(model: model) {
            lock.lock()
            cache[model] = fetched
            lock.unlock()
            return fetched
        }

        let fallback = fallbackRates(for: model)
        lock.lock()
        cache[model] = fallback
        lock.unlock()
        return fallback
    }

    private struct PricingJSON: Decodable {
        struct Block: Decodable {
            let inputCostPerToken: Double?
            let outputCostPerToken: Double?
            let cacheReadInputTokenCost: Double?
            let cacheCreationInputTokenCost: Double?
        }
        let pricing: Block?
    }

    private static func fetchRatesFromTokscale(model: String) -> Rates? {
        let executable = TokscaleCLI.bundledExecutable ?? TokscaleCLI.executable
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["pricing", model, "--json", "--no-spinner"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = TokscaleCLI.searchPath
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let decoded = try? JSONDecoder().decode(PricingJSON.self, from: data),
              let p = decoded.pricing
        else { return nil }

        return Rates(
            inputPerToken: p.inputCostPerToken ?? 0,
            outputPerToken: p.outputCostPerToken ?? 0,
            cacheReadPerToken: p.cacheReadInputTokenCost ?? 0,
            cacheWritePerToken: p.cacheCreationInputTokenCost ?? 0
        )
    }

    /// Conservative Anthropic-ish defaults when tokscale cannot price a model id.
    private static func fallbackRates(for model: String) -> Rates {
        let id = model.lowercased()
        if id.contains("opus") {
            return Rates(inputPerToken: 0.000015, outputPerToken: 0.000075,
                         cacheReadPerToken: 0.0000015, cacheWritePerToken: 0.00001875)
        }
        if id.contains("sonnet") {
            return Rates(inputPerToken: 0.000003, outputPerToken: 0.000015,
                         cacheReadPerToken: 0.0000003, cacheWritePerToken: 0.00000375)
        }
        if id.contains("haiku") {
            return Rates(inputPerToken: 0.0000008, outputPerToken: 0.000004,
                         cacheReadPerToken: 0.00000008, cacheWritePerToken: 0.000001)
        }
        return Rates(inputPerToken: 0.000003, outputPerToken: 0.000015,
                     cacheReadPerToken: 0.0000003, cacheWritePerToken: 0.00000375)
    }

    #if DEBUG
    static func resetCacheForTesting() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }
    #endif
}
