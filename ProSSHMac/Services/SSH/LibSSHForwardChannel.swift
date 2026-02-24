// Extracted from SSHTransport.swift
import Foundation

nonisolated actor LibSSHForwardChannel: SSHForwardChannel {
    private nonisolated(unsafe) var pointer: OpaquePointer?

    init(pointer: UncheckedOpaquePointer) {
        self.pointer = pointer.raw
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

        if isEOF {
            return nil
        }

        if bytesRead == 0 {
            try await Task.sleep(for: .milliseconds(10))
            return Data()
        }

        return Data(buffer[0..<Int(bytesRead)])
    }

    func write(_ data: Data) async throws {
        guard let ptr = pointer else {
            throw SSHTransportError.transportFailure(message: "Forward channel is closed.")
        }

        var errorBuffer = [CChar](repeating: 0, count: 512)
        let result = data.withUnsafeBytes { bytes -> Int32 in
            let basePtr = bytes.baseAddress?.assumingMemoryBound(to: CChar.self)
            return prossh_forward_channel_write(
                ptr,
                basePtr,
                bytes.count,
                &errorBuffer,
                errorBuffer.count
            )
        }

        if result != 0 {
            let message = errorBuffer.asString
            throw SSHTransportError.transportFailure(message: message)
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
