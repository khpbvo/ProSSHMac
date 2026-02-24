import Foundation

@MainActor
protocol HostStoreProtocol {
    func loadHosts() async throws -> [Host]
    func saveHosts(_ hosts: [Host]) async throws
}
