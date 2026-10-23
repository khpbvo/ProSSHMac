// Extracted from SSHTransport.swift
import Foundation

actor LibSSHForwardChannel: SSHForwardChannel {
    private nonisolated(unsafe) var pointer: OpaquePointer?

    /// Takes the C channel synchronously, so the transport can register this channel before it
    /// next suspends. Only valid before the channel is shared.
    nonisolated func adopt(_ pointer: UncheckedOpaquePointer) {
        self.pointer = pointer.raw
    }

    /// Asks the server to open the channel and waits for its answer without blocking the session
    /// the shell shares. `close()` may run between attempts; the open then fails.
    func open(remoteHost: String, remotePort: UInt16, sourceHost: String, sourcePort: UInt16, timeout: Duration) async throws {
        let deadline = ContinuousClock.now + timeout
        while true {
            guard let ptr = pointer else {
                throw SSHTransportError.transportFailure(message: "Forward channel was closed while opening.")
            }
            var errorBuffer = [CChar](repeating: 0, count: 512)
            let status = remoteHost.withCString { remoteHostPtr in
                sourceHost.withCString { sourceHostPtr in
                    prossh_forward_channel_open(
                        ptr,
                        remoteHostPtr,
                        remotePort,
                        sourceHostPtr,
                        sourcePort,
                        &errorBuffer,
                        errorBuffer.count
                    )
                }
            }
            if status == 1 { return }
            if status < 0 {
                await close()
                let message = errorBuffer.asString
                throw SSHTransportError.transportFailure(message: message.isEmpty ? "Failed to open forward channel." : message)
            }
            guard ContinuousClock.now < deadline else {
                await close()
                throw SSHTransportError.transportFailure(message: "The server did not open the forward channel to \(remoteHost):\(remotePort) in time.")
            }
            do {
                try await Task.sleep(for: .milliseconds(10))
            } catch {
                await close()
                throw error
            }
        }
    }

    func read() async throws -> Data? {
        guard let ptr = pointer else { return nil }

        let bufferSize = 32768
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        var isEOF = false
        var errorBuffer = [CChar](repeating: 0, count: 512)

        let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return Int32(-1) }
            let cBuffer = baseAddress.assumingMemoryBound(to: CChar.self)
            return prossh_forward_channel_read(
                ptr,
                cBuffer,
                bufferSize,
                &isEOF,
                &errorBuffer,
                errorBuffer.count
            )
        }

        if bytesRead < 0 {
            let message = errorBuffer.asString
            throw SSHTransportError.transportFailure(message: message)
        }

        // The read that drains the last bytes also reports EOF; deliver them first.
        if bytesRead > 0 {
            return Data(buffer[0..<Int(bytesRead)])
        }

        if isEOF {
            return nil
        }

        try await Task.sleep(for: .milliseconds(10))
        return Data()
    }

    /// Sends every byte. While the remote window is full libssh takes only part (or none) of it.
    func write(_ data: Data) async throws {
        var offset = 0
        while offset < data.count {
            guard let ptr = pointer else {
                throw SSHTransportError.transportFailure(message: "Forward channel is closed.")
            }

            var errorBuffer = [CChar](repeating: 0, count: 512)
            let written = data.withUnsafeBytes { bytes -> Int32 in
                let basePtr = bytes.baseAddress?.advanced(by: offset).assumingMemoryBound(to: CChar.self)
                return prossh_forward_channel_write(
                    ptr,
                    basePtr,
                    bytes.count - offset,
                    &errorBuffer,
                    errorBuffer.count
                )
            }

            if written < 0 {
                let message = errorBuffer.asString
                throw SSHTransportError.transportFailure(message: message)
            }
            offset += Int(written)
            if written == 0 {
                try await Task.sleep(for: .milliseconds(5))
            }
        }
    }

    var isOpen: Bool {
        guard let ptr = pointer else { return false }
        return prossh_forward_channel_is_open(ptr) == 1
    }

    func close() async {
        guard let ptr = pointer else { return }
        prossh_forward_channel_close(ptr)
        pointer = nil
    }
}

private extension Array where Element == CChar {
    nonisolated var asString: String {
        String(decoding: prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
