import Foundation
import MateBridgeHost

/// Command-line entry for the video verification tool (T-011). Called from a 3-line hook at the top of main.swift.
enum DumpVideoCommand {
    /// Runs and exits the process if `--dump-video` is present; returns otherwise.
    static func runIfRequested() {
        guard let parsed = VideoDump.parse(CommandLine.arguments) else { return }
        switch parsed {
        case .failure(let message):
            print("error: \(message.message)")
            exit(2)
        case .success(let options):
            Task {
                exit(await VideoDump.run(options))
            }
            dispatchMain()
        }
    }
}
