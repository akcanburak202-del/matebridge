import Foundation
import MateBridgeCore
import MateBridgeHost

/// Command-line entry for the encoder throughput bench (T-047). Synthetic frames only: touches no display, input or network.
enum EncodeBenchCommand {
    static func runIfRequested() {
        guard let parsed = EncodeBenchOptions.parse(CommandLine.arguments) else { return }
        switch parsed {
        case .failure(let error):
            print("error: \(error.message)")
            exit(2)
        case .success(let options):
            exit(EncodeBench.runAll(options))
        }
    }
}
