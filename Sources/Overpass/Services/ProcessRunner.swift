import Foundation

/// The one place Overpass spawns external processes with a custom
/// environment. Two lessons baked in:
///
/// 1. Both stdout and stderr pipes are drained continuously while the child
///    runs — the kernel pipe buffer is ~64 KB and a chatty child blocks on
///    write() forever if nobody reads.
/// 2. The pipes (and the `Process`) are kept alive until BOTH pipes hit EOF,
///    not merely until the child exits. Wine's `wineserver` daemon (and
///    games launched via `wine start`) inherit the pipes and outlive the
///    process we spawned; if the read ends were deallocated at termination,
///    later writers would take SIGPIPE and we would never see EOF — which
///    is exactly the "leaked continuation" hang bottle creation hit.
enum ProcessRunner {
    struct Result: Sendable {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    /// Everything the readability handlers need to keep alive. The handlers
    /// capture the box, the box owns the pipes/process, and the cycle is
    /// broken when each handler nils itself at EOF.
    private final class Box: @unchecked Sendable {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let queue = DispatchQueue(label: "ProcessRunner")
        var stdoutData = Data()
        var stderrData = Data()
        var stdoutOpen = true
        var stderrOpen = true
        var terminationStatus: Int32?
        var didFinish = false
        var logHandle: FileHandle?
        var keepOutput = true
        var onFinish: ((Result) -> Void)?
        var onEOF: (() -> Void)?

        func finishIfReady() {
            guard !didFinish, let status = terminationStatus, !stdoutOpen, !stderrOpen else { return }
            didFinish = true
            try? logHandle?.close()
            logHandle = nil
            let result = Result(
                status: status,
                stdout: String(data: stdoutData, encoding: .utf8) ?? "",
                stderr: String(data: stderrData, encoding: .utf8) ?? ""
            )
            let cb = onFinish
            onFinish = nil
            cb?(result)
        }

        func closeLogIfDrained() {
            guard !stdoutOpen, !stderrOpen else { return }
            try? logHandle?.close()
            logHandle = nil
            let cb = onEOF
            onEOF = nil
            cb?()
        }
    }

    private static func openLog(_ url: URL?) -> FileHandle? {
        guard let url else { return nil }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        return handle
    }

    /// Configures and starts the child; returns the box so callers can wait
    /// (`run`) or walk away (`spawn`).
    private static func start(
        executable: URL,
        arguments: [String],
        environment: [String: String]?,
        currentDirectory: URL?,
        logURL: URL?,
        keepOutput: Bool,
        onLine: (@Sendable (String) -> Void)?
    ) throws -> Box {
        let box = Box()
        let process = box.process
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = box.stdoutPipe
        process.standardError = box.stderrPipe
        box.logHandle = openLog(logURL)
        box.keepOutput = keepOutput

        func install(_ pipe: Pipe, isStdout: Bool) {
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                box.queue.async {
                    if chunk.isEmpty {
                        if isStdout { box.stdoutOpen = false } else { box.stderrOpen = false }
                        handle.readabilityHandler = nil
                        box.closeLogIfDrained()
                        box.finishIfReady()
                    } else {
                        if box.keepOutput {
                            if isStdout { box.stdoutData.append(chunk) } else { box.stderrData.append(chunk) }
                        }
                        box.logHandle?.write(chunk)
                        if let onLine, let text = String(data: chunk, encoding: .utf8) {
                            for line in text.split(whereSeparator: \.isNewline) { onLine(String(line)) }
                        }
                    }
                }
            }
        }
        install(box.stdoutPipe, isStdout: true)
        install(box.stderrPipe, isStdout: false)

        process.terminationHandler = { finished in
            box.queue.async {
                box.terminationStatus = finished.terminationStatus
                box.finishIfReady()
            }
        }

        do {
            try process.run()
        } catch {
            box.stdoutPipe.fileHandleForReading.readabilityHandler = nil
            box.stderrPipe.fileHandleForReading.readabilityHandler = nil
            try? box.logHandle?.close()
            throw error
        }
        return box
    }

    /// Runs to completion. Resolves once the child has exited AND both pipes
    /// have reached EOF (i.e. every inherited writer is gone too).
    static func run(
        _ executable: URL,
        _ arguments: [String],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        logURL: URL? = nil,
        onLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> Result {
        let box = try start(
            executable: executable, arguments: arguments, environment: environment,
            currentDirectory: currentDirectory, logURL: logURL, keepOutput: true, onLine: onLine
        )
        return await withCheckedContinuation { continuation in
            box.queue.async {
                box.onFinish = { continuation.resume(returning: $0) }
                box.finishIfReady()
            }
        }
    }

    /// Fire-and-forget: output streams into `logURL` until every writer
    /// closes, the caller gets the `Process` back immediately.
    static func spawn(
        _ executable: URL,
        _ arguments: [String],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        logURL: URL
    ) throws -> Process {
        let box = try start(
            executable: executable, arguments: arguments, environment: environment,
            currentDirectory: currentDirectory, logURL: logURL, keepOutput: false, onLine: nil
        )
        return box.process
    }
}
