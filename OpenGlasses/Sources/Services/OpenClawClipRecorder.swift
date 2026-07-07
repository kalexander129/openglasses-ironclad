import AVFoundation
import Foundation

/// One-shot iPhone camera video clip recorder for the OpenClaw node `camera.clip` command.
///
/// Records a short mp4 (medium preset to keep the base64 payload well under the gateway's
/// message limits) and returns the file contents. NOTE: the Meta DAT SDK exposes photo
/// capture + a live frame stream for the glasses but no video-file capture API, so
/// agent-initiated clips always come from the iPhone camera (back by default).
final class OpenClawClipRecorder: NSObject, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let output = AVCaptureMovieFileOutput()
    private let queue = DispatchQueue(label: "com.openglasses.openclaw.clip")
    private var continuation: CheckedContinuation<Data, Error>?

    /// Record a clip of `durationMs` (caller clamps) and return mp4 data.
    func record(durationMs: Int, includeAudio: Bool, facing: String) async throws -> Data {
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
        }
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            throw CameraError.permissionDenied
        }
        var audio = includeAudio
        if audio {
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .audio)
            }
            audio = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        }
        let useAudio = audio

        return try await withCheckedThrowingContinuation { cont in
            queue.async { [self] in
                // Don't tear down the app's playAndRecord audio session (wake word / TTS).
                session.automaticallyConfiguresApplicationAudioSession = false
                session.beginConfiguration()
                if session.canSetSessionPreset(.medium) { session.sessionPreset = .medium }
                let position: AVCaptureDevice.Position = (facing == "front") ? .front : .back
                guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
                        ?? AVCaptureDevice.default(for: .video),
                      let input = try? AVCaptureDeviceInput(device: device),
                      session.canAddInput(input) else {
                    session.commitConfiguration()
                    cont.resume(throwing: CameraError.captureFailed)
                    return
                }
                session.addInput(input)
                if useAudio,
                   let mic = AVCaptureDevice.default(for: .audio),
                   let micInput = try? AVCaptureDeviceInput(device: mic),
                   session.canAddInput(micInput) {
                    session.addInput(micInput)
                }
                guard session.canAddOutput(output) else {
                    session.commitConfiguration()
                    cont.resume(throwing: CameraError.captureFailed)
                    return
                }
                session.addOutput(output)
                session.commitConfiguration()
                session.startRunning()

                DispatchQueue.main.async { self.continuation = cont }

                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("openclaw-clip-\(UUID().uuidString).mp4")
                output.maxRecordedDuration = CMTime(value: CMTimeValue(durationMs), timescale: 1000)
                output.startRecording(to: url, recordingDelegate: self)
            }
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput,
                    didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection],
                    error: Error?) {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
        DispatchQueue.main.async { [self] in
            let cont = continuation
            continuation = nil
            // Hitting maxRecordedDuration reports AVError.maximumDurationReached — the file
            // is still complete and valid, so prefer the data over the error.
            if let data = try? Data(contentsOf: outputFileURL), !data.isEmpty {
                try? FileManager.default.removeItem(at: outputFileURL)
                cont?.resume(returning: data)
            } else if let error {
                cont?.resume(throwing: error)
            } else {
                cont?.resume(throwing: CameraError.captureFailed)
            }
        }
    }
}
