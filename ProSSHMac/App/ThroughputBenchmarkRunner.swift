import AppKit
import Foundation

@MainActor
enum ThroughputBenchmarkRunner {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("--benchmark-base64")
    }

    private enum RunState {
        case idle
        case running
        case completed
    }
    private static var runState: RunState = .idle

    static func runIfRequested() async -> Bool {
        guard isEnabled else { return false }
        switch runState {
        case .completed, .running:
            return true
        case .idle:
            runState = .running
        }

        let config = configurationFromArgs()
        let payload = makeBase64LikePayload(targetBytes: config.bytes, lineLength: config.lineLength)

        print("==> ProSSHMac Throughput Benchmark")
        print("    bytes=\(config.bytes) chunk=\(config.chunkSize) runs=\(config.runs) lineLength=\(config.lineLength)")
        print("")

        var fullResults: [BenchmarkResult] = []
        var partialResults: [BenchmarkResult] = []

        for run in 1...config.runs {
            let full = await runScenario(
                name: "fullscreen",
                payload: payload,
                chunkSize: config.chunkSize,
                scrollRegion: nil
            )
            fullResults.append(full)
            print("run \(run)/\(config.runs) [fullscreen] \(full.summary)")

            let partial = await runScenario(
                name: "partial-\(config.partialTop)-\(config.partialBottom)",
                payload: payload,
                chunkSize: config.chunkSize,
                scrollRegion: (config.partialTop, config.partialBottom)
            )
            partialResults.append(partial)
            print("run \(run)/\(config.runs) [partial]    \(partial.summary)")
        }

        let fullAvg = average(of: fullResults.map(\.mbps))
        let partialAvg = average(of: partialResults.map(\.mbps))
        let deltaPct = fullAvg > 0 ? ((fullAvg - partialAvg) / fullAvg) * 100.0 : 0

        print("")
        print("summary:")
        print("  fullscreen avg: \(format(fullAvg)) MB/s")
        print("  partial    avg: \(format(partialAvg)) MB/s")
        print("  delta: \(format(deltaPct))% slower in partial scroll region")
        print("")

        runState = .completed
        fflush(stdout)
        fflush(stderr)
        exit(0)
        return true
    }

    private static func runScenario(
        name: String,
        payload: Data,
        chunkSize: Int,
        scrollRegion: (top: Int, bottom: Int)?
    ) async -> BenchmarkResult {
        let grid = TerminalGrid(columns: 80, rows: 24)
        let parser = VTParser(grid: grid)

        if let region = scrollRegion {
            await grid.setScrollRegion(top: region.top, bottom: region.bottom)
        }

        let start = CFAbsoluteTimeGetCurrent()
        var offset = 0
        while offset < payload.count {
            let end = min(offset + chunkSize, payload.count)
            let chunk = payload.subdata(in: offset..<end)
            _ = await parser.feed(chunk)
            offset = end
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        let state = await parser.state
        _ = await grid.snapshot()

        return BenchmarkResult(
            name: name,
            bytes: payload.count,
            elapsedSeconds: elapsed,
            parserState: state
        )
    }

    private static func makeBase64LikePayload(targetBytes: Int, lineLength: Int) -> Data {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)
        var out = Data()
        out.reserveCapacity(max(targetBytes, 0))

        var seed: UInt64 = 0x1234_5678_9ABC_DEF0
        var col = 0
        while out.count < targetBytes {
            if lineLength > 0, col >= lineLength {
                if out.count < targetBytes { out.append(0x0D) }
                if out.count < targetBytes { out.append(0x0A) }
                col = 0
                continue
            }

            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let idx = Int((seed >> 33) % UInt64(alphabet.count))
            out.append(alphabet[idx])
            col += 1
        }

        return out
    }

    private static func average(of values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private static func configurationFromArgs() -> BenchmarkConfig {
        let args = ProcessInfo.processInfo.arguments
        let top = max(intArg("--benchmark-partial-top", args: args, defaultValue: 4), 0)
        let bottomRaw = min(intArg("--benchmark-partial-bottom", args: args, defaultValue: 19), 23)
        let bottom = max(bottomRaw, top + 1)
        return BenchmarkConfig(
            bytes: max(intArg("--benchmark-bytes", args: args, defaultValue: 16 * 1_048_576), 1024),
            chunkSize: max(intArg("--benchmark-chunk", args: args, defaultValue: 4096), 64),
            runs: max(intArg("--benchmark-runs", args: args, defaultValue: 3), 1),
            lineLength: max(intArg("--benchmark-line-length", args: args, defaultValue: 76), 1),
            partialTop: top,
            partialBottom: bottom
        )
    }

    private static func intArg(_ flag: String, args: [String], defaultValue: Int) -> Int {
        guard let idx = args.firstIndex(of: flag), idx + 1 < args.count else {
            return defaultValue
        }
        return Int(args[idx + 1]) ?? defaultValue
    }
}

private struct BenchmarkConfig {
    let bytes: Int
    let chunkSize: Int
    let runs: Int
    let lineLength: Int
    let partialTop: Int
    let partialBottom: Int
}

private struct BenchmarkResult {
    let name: String
    let bytes: Int
    let elapsedSeconds: Double
    let parserState: ParserState

    var mbps: Double {
        guard elapsedSeconds > 0 else { return 0 }
        return Double(bytes) / elapsedSeconds / 1_048_576.0
    }

    var summary: String {
        let stateLabel = parserState == .ground ? "ground" : "\(parserState)"
        return "\(String(format: "%.2f", mbps)) MB/s in \(String(format: "%.3f", elapsedSeconds))s (state=\(stateLabel))"
    }
}
