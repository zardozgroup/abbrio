import XCTest
import SnippetModel
@testable import EspansoCLI

/// Answers commands from a table instead of running anything.
private struct StubRunner: CommandRunner {
    var responses: [String: CommandResult]

    func run(
        _ executable: URL, arguments: [String], environment: [String: String]?, timeout: TimeInterval
    ) async throws -> CommandResult {
        guard let response = responses[arguments.joined(separator: " ")] else {
            throw CommandError.launchFailed("no stub for \(arguments)")
        }
        return response
    }
}

final class EspansoClientTests: XCTestCase {
    private func client(_ responses: [String: CommandResult]) -> EspansoClient {
        EspansoClient(executable: URL(fileURLWithPath: "/nonexistent/espanso"), runner: StubRunner(responses: responses))
    }

    func testVersion() async throws {
        let version = try await client(["--version": CommandResult(exitCode: 0, standardOutput: "2.4.1\n")]).version()
        XCTAssertEqual(version, EngineVersion(major: 2, minor: 4, patch: 1))
    }

    func testVersionWithUnexpectedOutput() async {
        do {
            _ = try await client(["--version": CommandResult(exitCode: 0, standardOutput: "hello")]).version()
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? CommandError, .unexpectedOutput("hello"))
        }
    }

    func testLoadedTriggers() async throws {
        let json = #"[{"triggers":[";a",";b"],"replace":"x","label":null},{"triggers":["btw"],"replace":"by the way"}]"#
        let triggers = try await client(["match list --json": CommandResult(exitCode: 0, standardOutput: json)]).loadedTriggers()
        XCTAssertEqual(triggers, [";a", ";b", "btw"])
        do {
            _ = try await client(["match list --json": CommandResult(exitCode: 2, standardError: "bad file")]).loadedTriggers()
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? CommandError, .failed(exitCode: 2, message: "bad file"))
        }
    }

    func testPaths() async throws {
        let output = """
        Config: /Users/sample/Library/Application Support/espanso
        Packages: /Users/sample/Library/Application Support/espanso/match/packages
        Runtime: /Users/sample/Library/Caches/espanso

        """
        let paths = try await client(["path": CommandResult(exitCode: 0, standardOutput: output)]).paths()
        XCTAssertEqual(paths.config.path, "/Users/sample/Library/Application Support/espanso")
        XCTAssertEqual(paths.packages?.lastPathComponent, "packages")
        XCTAssertEqual(paths.runtime?.path, "/Users/sample/Library/Caches/espanso")
    }

    func testFailedCommandCarriesTheMessage() async {
        let failing = client(["path": CommandResult(exitCode: 2, standardError: "missing default config\n")])
        do {
            _ = try await failing.paths()
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? CommandError, .failed(exitCode: 2, message: "missing default config"))
        }
    }

    func testEngineCommands() async throws {
        let ok = CommandResult(exitCode: 0)
        let client = client([
            "cmd disable": ok, "cmd enable": ok, "restart": ok, "service start": ok, "match exec -t ;sig": ok,
            "match exec -t ;gone": CommandResult(exitCode: 1, standardError: "unable to exec match: Worker process is not running, please start Espanso first.\n"),
        ])
        try await client.pause()
        try await client.resume()
        try await client.restart()
        try await client.start()
        try await client.expand(trigger: ";sig")
        do {
            try await client.expand(trigger: ";gone")
            XCTFail("expected an error")
        } catch let error as CommandError {
            XCTAssertEqual(error, .failed(exitCode: 1, message: "unable to exec match: Worker process is not running, please start Espanso first."))
        }
    }

    func testStatisticsCommands() async throws {
        let json = #"{ "top": [ { "count": 9, "trigger": ";cl" }, { "count": 2, "trigger": "Btw" } ], "total": 11, "unique": 2 }"#
        let client = client([
            "stats --json --period week --count 100000": CommandResult(exitCode: 0, standardOutput: json + "\n"),
            "stats --json --period all --count 100000": CommandResult(exitCode: 0, standardOutput: #"{ "top": [], "total": 0, "unique": 0 }"#),
            "stats clear": CommandResult(exitCode: 0), "stats prune --days 30": CommandResult(exitCode: 0),
        ])
        let week = try await client.stats(period: .week)
        XCTAssertEqual(week, [UsageCount(typed: ";cl", count: 9), UsageCount(typed: "Btw", count: 2)])
        let all = try await client.stats(period: .all)
        XCTAssertEqual(all, [])
        try await client.clearStats()
        try await client.pruneStats(olderThanDays: 30)
        XCTAssertThrowsError(try EspansoClient.parseStats("no statistics"))
    }

    func testPackageCommands() async throws {
        let client = client([
            "install dice": CommandResult(exitCode: 0, standardOutput: "package installed!\n"),
            "install dice --version 0.2.0": CommandResult(exitCode: 0, standardOutput: "ok"),
            "install mine --git https://example.invalid/me/mine --external": CommandResult(exitCode: 0, standardOutput: "ok"),
            "package update dice": CommandResult(exitCode: 0, standardOutput: "ok"),
            "uninstall dice": CommandResult(exitCode: 0, standardOutput: "ok"),
            "install gone": CommandResult(exitCode: 1, standardOutput: "unable to find package\n"),
        ])
        let output = try await client.installPackage("dice")
        XCTAssertEqual(output, "package installed!\n")
        try await client.installPackage("dice", version: "0.2.0")
        try await client.installPackage("mine", gitURL: "https://example.invalid/me/mine")
        try await client.updatePackage("dice")
        try await client.uninstallPackage("dice")
        do {
            try await client.installPackage("gone")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? CommandError, .failed(exitCode: 1, message: "unable to find package"))
        }
    }

    func testNamesAndAddressesThatCouldBeReadAsOptionsAreRefused() async {
        XCTAssertNil(EspansoClient.installArguments(name: "--force"))
        XCTAssertNil(EspansoClient.installArguments(name: "a b"))
        XCTAssertNil(EspansoClient.installArguments(name: ""))
        XCTAssertNil(EspansoClient.installArguments(name: "a", version: "-1"))
        XCTAssertNil(EspansoClient.installArguments(name: "a", gitURL: "--upload-pack=x"))
        XCTAssertNil(EspansoClient.installArguments(name: "a", gitURL: "https://example.invalid/a b"))
        XCTAssertEqual(
            EspansoClient.installArguments(name: "a_b.c-1", gitURL: "git@example.invalid:me/repo.git") ?? [],
            ["install", "a_b.c-1", "--git", "git@example.invalid:me/repo.git", "--external"]
        )
        do {
            try await client([:]).uninstallPackage("-x")
            XCTFail("expected an error")
        } catch {}
    }

    func testIsRunningFollowsTheExitCode() async {
        let running = await client(["status": CommandResult(exitCode: 0, standardOutput: "espanso is running\n")]).isRunning()
        let stopped = await client(["status": CommandResult(exitCode: 4, standardOutput: "espanso is not running\n")]).isRunning()
        let missing = await client([:]).isRunning()
        XCTAssertTrue(running)
        XCTAssertFalse(stopped)
        XCTAssertFalse(missing)
    }
}

final class EspansoLocatorTests: XCTestCase {
    func testOrderOfCandidates() {
        let locator = EspansoLocator(
            override: URL(fileURLWithPath: "/custom/espanso"),
            searchPath: "/usr/bin:/opt/homebrew/bin::/opt/tools",
            isExecutable: { _ in false }
        )
        XCTAssertEqual(locator.candidates, [
            "/custom/espanso",
            "/usr/bin/espanso",
            "/opt/homebrew/bin/espanso",
            "/opt/tools/espanso",
            "/usr/local/bin/espanso",
            "/Applications/Espanso.app/Contents/MacOS/espanso",
        ])
        XCTAssertNil(locator.locate())
    }

    func testFirstExecutableWins() {
        let locator = EspansoLocator(
            searchPath: "/usr/bin",
            isExecutable: { $0 == "/usr/local/bin/espanso" || $0.hasPrefix("/Applications") }
        )
        XCTAssertEqual(locator.locate()?.path, "/usr/local/bin/espanso")
    }

    func testOverrideThatIsMissingFallsThrough() {
        let locator = EspansoLocator(
            override: URL(fileURLWithPath: "/gone/espanso"),
            searchPath: "",
            isExecutable: { $0 == "/opt/homebrew/bin/espanso" }
        )
        XCTAssertEqual(locator.locate()?.path, "/opt/homebrew/bin/espanso")
    }
}

final class EngineLogTests: XCTestCase {
    func testSeesAReloadWrittenAfterThePosition() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = EngineLog(runtimeFolder: folder)
        XCTAssertEqual(log.position(), 0)
        XCTAssertFalse(log.hasReloaded(since: 0))

        let old = "10:00:00 [daemon] [INFO] configuration change detected, restarting worker process...\n"
        try old.write(to: log.url, atomically: true, encoding: .utf8)
        let position = log.position()
        XCTAssertTrue(log.hasReloaded(since: 0))
        XCTAssertFalse(log.hasReloaded(since: position))
        let waited = await log.waitForReload(since: position, timeout: .milliseconds(300))
        XCTAssertFalse(waited)

        let handle = try FileHandle(forWritingTo: log.url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("10:00:05 [daemon] [INFO] configuration change detected, restarting worker process...\n".utf8))
        try handle.close()
        XCTAssertTrue(log.hasReloaded(since: position))
    }

    func testReadsStateChangesInOrder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = EngineLog(runtimeFolder: folder)
        XCTAssertEqual(log.events(since: nil).events, [])

        func append(_ text: String) throws {
            if !FileManager.default.fileExists(atPath: log.url.path) {
                FileManager.default.createFile(atPath: log.url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: log.url)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
            try handle.close()
        }
        try append("""
        10:00:00 [daemon(1)] [INFO] spawning the worker process...
        10:00:01 [worker(2)] [INFO] monitoring the status of secure input
        10:00:02 [worker(2)] [INFO] toggled enabled state, is_enabled = false
        10:00:03 [worker(2)] [INFO] toggled enabled state, is_enabled = true

        """)
        let first = log.events(since: nil)
        XCTAssertEqual(first.events, [.workerStarted, .paused, .resumed])

        // A line that isn't finished yet waits for the next read.
        try append("10:00:04 [worker(2)] [INFO] secure input has been acquired, preventing espanso from working correctly. Our guess is that this is caused by 'Notes', but")
        let second = log.events(since: first.position)
        XCTAssertEqual(second.events, [])
        XCTAssertEqual(second.position, first.position)
        try append(" there are cases in which the detection is unreliable. Full path: /x\n10:00:09 [worker(2)] [INFO] secure input has been disabled\n")
        let third = log.events(since: second.position)
        XCTAssertEqual(third.events, [.secureInputAcquired(holder: "Notes"), .secureInputReleased])
        XCTAssertEqual(log.events(since: third.position).events, [])

        // A shorter file is a new log.
        try "10:01:00 [worker(3)] [INFO] toggled enabled state, is_enabled = false\n".write(to: log.url, atomically: true, encoding: .utf8)
        XCTAssertEqual(log.events(since: third.position).events, [.paused])
    }
}

final class ProcessRunnerTests: XCTestCase {
    private let shell = URL(fileURLWithPath: "/bin/sh")

    func testCapturesOutputErrorsAndExitCode() async throws {
        let result = try await ProcessRunner().run(
            shell, arguments: ["-c", "echo out; echo err >&2; exit 3"], timeout: 5
        )
        XCTAssertEqual(result, CommandResult(exitCode: 3, standardOutput: "out\n", standardError: "err\n"))
    }

    func testEnvironmentIsPassed() async throws {
        let result = try await ProcessRunner().run(
            shell, arguments: ["-c", "printf %s \"$SAMPLE_VALUE\""], environment: ["SAMPLE_VALUE": "set"], timeout: 5
        )
        XCTAssertEqual(result.standardOutput, "set")
    }

    func testLargeOutputDoesNotBlock() async throws {
        let result = try await ProcessRunner().run(
            shell, arguments: ["-c", "head -c 300000 /dev/zero | tr '\\0' 'x'"], timeout: 10
        )
        XCTAssertEqual(result.standardOutput.count, 300_000)
    }

    func testTimeout() async {
        do {
            _ = try await ProcessRunner().run(shell, arguments: ["-c", "sleep 5"], timeout: 0.3)
            XCTFail("expected a timeout")
        } catch {
            XCTAssertEqual(error as? CommandError, .timedOut(seconds: 0.3))
        }
    }

    func testCancellingTheCallerStopsTheProcess() async throws {
        let shell = shell
        let started = ContinuousClock.now
        let task = Task { try await ProcessRunner().run(shell, arguments: ["-c", "sleep 5"], timeout: 10) }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        let result = await task.result
        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(2))
    }

    func testTooMuchOutputIsAnError() async {
        do {
            _ = try await ProcessRunner().run(
                shell, arguments: ["-c", "head -c 17000000 /dev/zero | tr '\\0' 'x'"], timeout: 10
            )
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? CommandError, .outputTooLarge)
        }
    }

    func testMissingExecutable() async {
        do {
            _ = try await ProcessRunner().run(URL(fileURLWithPath: "/nonexistent/tool"), arguments: [], timeout: 1)
            XCTFail("expected a launch failure")
        } catch {
            guard case .launchFailed = error as? CommandError else {
                return XCTFail("unexpected error \(error)")
            }
        }
    }

    /// A stand-in executable that prints what the real commands print.
    func testClientAgainstAStubExecutable() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let stub = folder.appendingPathComponent("espanso")
        let script = """
        #!/bin/sh
        case "$1" in
          --version) echo "2.4.1" ;;
          path) echo "Config: $STUB_CONFIG"; echo "Packages: $STUB_CONFIG/match/packages"; echo "Runtime: /tmp/run" ;;
          status) echo "espanso is not running"; exit 4 ;;
          *) exit 64 ;;
        esac
        """
        try script.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)

        let located = EspansoLocator(override: stub, searchPath: "").locate()
        XCTAssertEqual(located?.path, stub.path)

        let client = EspansoClient(executable: stub, environment: ["STUB_CONFIG": "/tmp/sample config"])
        let version = try await client.version()
        let paths = try await client.paths()
        let running = await client.isRunning()
        XCTAssertEqual(version.description, "2.4.1")
        XCTAssertEqual(paths.config.path, "/tmp/sample config")
        XCTAssertFalse(running)
    }
}
