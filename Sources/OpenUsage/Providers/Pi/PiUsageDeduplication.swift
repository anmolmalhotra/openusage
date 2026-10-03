//
//  PiUsageDeduplication.swift
//  OpenUsage
//
//  Created by Anmol Malhotra on 03/10/26.
//

import Foundation

/// Pi forks create new headers but copy existing response entries. Only sessions connected by a
/// declared parent path or shared header identity can share request fingerprints; unrelated sessions
/// remain independent even when their short entry IDs and usage happen to match exactly.
enum PiUsageDeduplication {
    private enum Identity: Hashable {
        case session(String)
        case path(String)
    }
    
    private struct Request: Hashable {
        var lineage: Identity
        var id: String
        var timestamp: Date
        var provider: String?
        var card: String
        var model: String
        var tokens: [Int]
        var isFast: Bool
        var total: Int
        var cost: Double?
    }
    
    static func deduplicate(_ entries: [PiUsageScanner.Entry]) -> [PiUsageScanner.Entry] {
        var graph = LineageGraph()
        for entry in entries {
            guard let source = entry.sourcePath else { continue }
            if let session = entry.sessionID {
                graph.connect(.path(source), .session(session))
            }
            if let parent = entry.parentPath {
                // A missing or header-only parent still links its children through the declared path.
                graph.connect(.path(source), .path(parent))
            }
        }
        var seenSessionEntries: Set<String> = []
        var seenRequests: Set<Request> = []
        var result: [PiUsageScanner.Entry] = []
        result.reserveCapacity(entries.count)
        for entry in entries {
            if let key = entry.deduplicationKey, !seenSessionEntries.insert(key).inserted { continue }
            let identity = entry.sessionID.map(Identity.session) ?? entry.sourcePath.map(Identity.path)
            if let identity, let id = entry.id {
                let request = Request(
                    lineage: graph.root(identity), id: id, timestamp: entry.timestamp,
                    provider: entry.providerID, card: entry.cardID, model: entry.model,
                    tokens: [entry.tokens.input, entry.tokens.cacheRead, entry.tokens.cacheWrite5m,
                             entry.tokens.cacheWrite1h, entry.tokens.output],
                    isFast: entry.tokens.isFast, total: entry.reportedTotalTokens, cost: entry.carriedCost
                )
                guard seenRequests.insert(request).inserted else { continue }
            }
            result.append(entry)
        }
        return result
    }
    
    /// Union-find keeps deep fork chains linear in practice and terminates even for cyclic metadata.
    private struct LineageGraph {
        var parents: [Identity: Identity] = [:]
        var ranks: [Identity: Int] = [:]
        
        mutating func root(_ identity: Identity) -> Identity {
            var current = identity
            var path: [Identity] = []
            while let parent = parents[current] {
                path.append(current)
                current = parent
            }
            for element in path { parents[element] = current }
            return current
        }
        
        mutating func connect(_ first: Identity, _ second: Identity) {
            let firstRoot = root(first)
            let secondRoot = root(second)
            guard firstRoot != secondRoot else { return }
            let firstRank = ranks[firstRoot, default: 0]
            let secondRank = ranks[secondRoot, default: 0]
            if firstRank < secondRank {
                parents[firstRoot] = secondRoot
            } else {
                parents[secondRoot] = firstRoot
                if firstRank == secondRank { ranks[firstRoot] = firstRank + 1 }
            }
        }
    }
}
