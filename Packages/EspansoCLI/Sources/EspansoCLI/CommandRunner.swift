public import Foundation
import Subprocess
import System

/// What a finished command produced.
public struct CommandResult: Hashable, Sendable {
    public var exitCode: Int32
    public var standardOutput: String
    public var standardError: String

    public init(exitCode: Int32, standardOutput: String = "", standardError: String = "") {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    public var succeeded: Bool { exitCode == 0 }
}

public enum CommandError: Error, Equatable, Sendable {
    /// The executable could not be started.
    case launchFailed(String)
    /// The command ran longer than allowed and was stopped.
    case timedOut(seconds: TimeInterval)
    /// The command finished with a non-zero exit code.
    case failed(exitCode: Int32, message: String)
    /// The command printed more than the runner accepts.
    case outputTooLarge
    /// The command succeeded but printed something unexpected.
    case unexpectedOutput(String)
}

/// Runs an executable and collects its output. Tests replace it with a stub.
public protocol CommandRunner: Sendable {
    func run(
        _ executable: URL,
        arguments: [String],
        environment: [String: String]?,
        timeout: TimeInterval
    ) async throws -> CommandResult
}

/// Runs commands as child processes.
public struct ProcessRunner: CommandRunner {
    /// The most a command may print before the run fails, so a runaway command can't fill memory.
    static let outputLimit = 16 * 1024 * 1024
    static let errorLimit = 1024 * 1024

    public init() {}

    /// Runs the command and waits for it to finish.
    ///
    /// The process is stopped when the timeout passes or when the calling task is cancelled.
    public func run(
        _ executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval
    ) async throws -> CommandResult {
        try await withThrowingTaskGroup(of: CommandResult?.self) { group in
            group.addTask {
                try await Self.launch(executable, arguments: arguments, environment: environment)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                return nil
            }
            defer { group.cancelAll() }
            // Whichever finishes first decides: the command's result, or nil from the timer.
            if let result = try await group.next() ?? nil {
                return result
            }
            group.cancelAll()
            // Wait for the process to be stopped before reporting the timeout.
            _ = try? await group.next()
            throw CommandError.timedOut(seconds: timeout)
        }
    }

    private static func launch(
        _ executable: URL,
        arguments: [String],
        environment: [String: String]?
    ) async throws -> CommandResult {
        var options = PlatformOptions()
        // On cancellation: ask the process to quit, then force it if it hasn't.
        options.teardownSequence = [.gracefulShutDown(allowedDurationToNextStep: .milliseconds(200))]

        var variables: [Environment.Key: String] = [:]
        for (name, value) in environment ?? [:] {
            if let key = Environment.Key(rawValue: name) { variables[key] = value }
        }

        do {
            let result = try await Subprocess.run(
                .path(FilePath(executable.path)),
                arguments: Arguments(arguments),
                environment: environment == nil ? .inherit : .custom(variables),
                platformOptions: options,
                output: .string(limit: outputLimit),
                error: .string(limit: errorLimit)
            )
            let exitCode: Int32
            switch result.terminationStatus {
            case .exited(let code):
                exitCode = Int32(code)
            case .signaled(let signal):
                // The convention shells use for a process ended by a signal.
                exitCode = 128 + Int32(signal)
            @unknown default:
                exitCode = -1
            }
            return CommandResult(
                exitCode: exitCode,
                standardOutput: result.standardOutput,
                standardError: result.standardError
            )
        } catch let error as SubprocessError {
            switch error.code {
            case .executableNotFound, .spawnFailed:
                throw CommandError.launchFailed(String(describing: error))
            case .outputLimitExceeded:
                throw CommandError.outputTooLarge
            default:
                throw error
            }
        }
    }
}
