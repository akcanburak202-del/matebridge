import Foundation
import MateBridgeHost

/// Command-line entry for the input verification tool (T-023). Called from a one-line hook at the top of main.swift,
/// next to `--dump-video`. It POSTS REAL INPUT EVENTS to the virtual display: see `InjectTest`.
enum InjectTestCommand {
    /// Runs and exits the process if `--inject-test` is present; returns otherwise.
    static func runIfRequested() {
        guard let parsed = InjectTest.parse(CommandLine.arguments) else { return }
        switch parsed {
        case .failure(let error):
            print("error: \(error.message)")
            exit(2)
        case .success(let options):
            DispatchQueue.global().async { exit(InjectTest.run(options)) }
            dispatchMain()
        }
    }
}
