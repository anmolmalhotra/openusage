//
//  PiUsageFixture.swift
//  OpenUsageTests
//
//  Created by Anmol Malhotra on 03/10/26.
//

import Foundation
@testable import OpenUsage

/// Keeps tests of native provider history independent of the machine's Pi transcripts.
enum PiUsageFixture {
    static func emptyScanner() -> PiUsageScanner {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("no-pi-\(UUID().uuidString)")
        return PiUsageScanner(
            environment: FakeEnvironment(["PI_CODING_AGENT_SESSION_DIR": directory.path]),
            homeDirectory: { directory }, incrementalScanner: IncrementalJSONLScanner<PiUsageScanner.Entry>()
        )
    }
}
