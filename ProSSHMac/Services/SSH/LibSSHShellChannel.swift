// Extracted from SSHTransport.swift
import Foundation

nonisolated actor LibSSHShellChannel: SSHShellChannel {
    nonisolated let rawOutput: AsyncStream<Data>

    private nonisolated(unsafe) let handle: OpaquePointer
    private nonisolated(unsafe) var rawContinuation: AsyncStream<Data>.Continuation
    private var readerTask: Task<Void, Never>?
    private var isClosed = false

    private init(
        handle: OpaquePointer,
        rawContinuation: AsyncStream<Data>.Continuation,
        rawOutput: AsyncStream<Data>
    ) {
        self.handle = handle
        self.rawContinuation = rawContinuation
        self.rawOutput = rawOutput
    }

    nonisolated static func create(
        handle: UncheckedOpaquePointer,
        pty: PTYConfiguration,
        enableAgentForwarding: Bool
    ) async throws -> LibSSHShellChannel {
        var capturedRawContinuation: AsyncStream<Data>.Continuation?
        let rawOutput = AsyncStream<Data> { continuation in
            capturedRawContinuation = continuation
        }
        guard let rawContinuation = capturedRawContinuation else {
            throw SSHTransportError.transportFailure(message: "Failed to initialize shell raw output stream.")
        }

        var errorBuffer = [CChar](repeating: 0, count: 512)
        let openResult = pty.terminalType.withCString { termPtr in
            prossh_libssh_open_shell(
                handle.raw,
                Int32(pty.columns),
                Int32(pty.rows),
                termPtr,
                enableAgentForwarding,
                &errorBuffer,
                errorBuffer.count
            )
        }

        if openResult != 0 {
            throw SSHTransportError.transportFailure(message: errorBuffer.asString)
        }

        let channel = LibSSHShellChannel(
            handle: handle.raw,
            rawContinuation: rawContinuation,
            rawOutput: rawOutput
        )
        await channel.startReaderTask()
        return channel
    }

    private func startReaderTask() {
        readerTask = Task { [weak self] in
            await self?.readLoop()
        }
    }

    func send(_ input: String) async throws {
        try await send(bytes: Array(input.utf8))
    }

    func send(bytes: [UInt8]) async throws {
        if isClosed {
            return
        }

        if bytes.isEmpty {
            return
        }

        var errorBuffer = [CChar](repeating: 0, count: 512)
        let writeResult = bytes.withUnsafeBytes { payload in
            let ptr = payload.baseAddress?.assumingMemoryBound(to: CChar.self)
            return prossh_libssh_channel_write(
                handle,
                ptr,
                payload.count,
                &errorBuffer,
                errorBuffer.count
            )
        }

        if writeResult != 0 {
            throw SSHTransportError.transportFailure(message: errorBuffer.asString)
        }
    }

    func resizePTY(columns: Int, rows: Int) async throws {
        guard !isClosed else { return }

        var errorBuffer = [CChar](repeating: 0, count: 512)
        let result = prossh_libssh_channel_resize_pty(
            handle,
            Int32(columns),
            Int32(rows),
            &errorBuffer,
            errorBuffer.count
        )

        if result != 0 {
            throw SSHTransportError.transportFailure(message: errorBuffer.asString)
        }
    }

    func close() async {
        guard !isClosed else { return }
        isClosed = true
        readerTask?.cancel()
        readerTask = nil
        prossh_libssh_channel_close(handle)
        rawContinuation.finish()
    }

    private func readLoop() async {
        let bufferSize = 32768
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        var errorBuffer = [CChar](repeating: 0, count: 512)

        while !Task.isCancelled && !isClosed {
            var bytesRead = Int32(0)
            var isEOF = false

            let readResult = buffer.withUnsafeMutableBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return Int32(-1) }
                let cBuffer = baseAddress.assumingMemoryBound(to: CChar.self)
                return prossh_libssh_channel_read(
                    handle,
                    cBuffer,
                    bufferSize,
                    &bytesRead,
                    &isEOF,
                    &errorBuffer,
                    errorBuffer.count
                )
            }

            if readResult != 0 {
                let message = errorBuffer.asString
                if !message.isEmpty {
                    rawContinuation.yield(Data("I/O error: \(message)".utf8))
                }
                break
            }

            if bytesRead > 0 {
                rawContinuation.yield(Data(buffer[0..<Int(bytesRead)]))
            }

            if isEOF {
                break
            }

            if bytesRead == 0 {
                try? await Task.sleep(for: .milliseconds(40))
            }
        }

        await close()
    }
}

private extension Array where Element == CChar {
    nonisolated var asString: String {
        String(decoding: prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
