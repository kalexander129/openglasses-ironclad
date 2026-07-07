import Foundation
import UIKit
import AudioToolbox

/// WebSocket client for receiving proactive notifications from OpenClaw.
/// Connects to the OpenClaw gateway's WebSocket endpoint, authenticates,
/// and listens for heartbeat/cron events to speak through TTS.
class OpenClawEventClient {
    var onNotification: ((String) -> Void)?
    /// Capture a photo for an agent `camera.snap` invoke (wired to CameraService:
    /// glasses DAT camera when registered, iPhone back camera fallback). Returns JPEG data.
    var cameraSnap: (() async throws -> Data)?
    /// Called at the moment of every agent-initiated capture so the app can announce it
    /// (speech + on-screen text). Privacy rule: NO silent captures, ever.
    var onAgentCapture: ((String) -> Void)?

    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private var isConnected = false
    private var shouldReconnect = false
    private var reconnectDelay: TimeInterval = 2
    private let maxReconnectDelay: TimeInterval = 30

    func connect() {
        guard Config.isOpenClawConfigured else {
            NSLog("[OpenClawWS] Not configured, skipping")
            return
        }
        shouldReconnect = true
        reconnectDelay = 2
        establishConnection()
    }

    func disconnect() {
        shouldReconnect = false
        isConnected = false
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        session?.invalidateAndCancel()
        session = nil
        NSLog("[OpenClawWS] Disconnected")
    }

    // MARK: - Private

    private func establishConnection() {
        // Use the new multi-gateway config; fall back to legacy if needed
        guard let gateway = Self.activeGateway() else {
            NSLog("[OpenClawWS] No configured gateway found, skipping")
            return
        }

        let wsURL = Self.webSocketURL(for: gateway)
        guard let url = URL(string: wsURL) else {
            NSLog("[OpenClawWS] Invalid URL: %@", wsURL)
            return
        }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config)
        webSocketTask = session?.webSocketTask(with: url)
        webSocketTask?.resume()

        NSLog("[OpenClawWS] Connecting to %@ (gateway: %@)", url.absoluteString, gateway.name)
        startReceiving()
    }

    /// Find the first enabled gateway that uses the OpenClaw WebSocket protocol.
    private static func activeGateway() -> GatewayConfig? {
        let gateways = Config.enabledGateways
        if let gw = gateways.first(where: { $0.gatewayProvider.usesOpenClawProtocol && $0.isConfigured }) {
            return gw
        }
        // Fall back to legacy single-gateway config
        if Config.openClawEnabled && !Config.openClawGatewayToken.isEmpty {
            return GatewayConfig(
                id: "legacy",
                name: "Legacy OpenClaw",
                provider: GatewayProvider.openclaw.rawValue,
                lanHost: Config.openClawLanHost,
                port: Config.openClawPort,
                tunnelHost: Config.openClawTunnelHost,
                token: Config.openClawGatewayToken,
                connectionMode: Config.openClawConnectionMode.rawValue,
                enabled: true,
                priority: 0
            )
        }
        return nil
    }

    /// Build a WebSocket URL from a gateway config.
    private static func webSocketURL(for gateway: GatewayConfig) -> String {
        let mode = gateway.connectionModeEnum
        switch mode {
        case .tunnel:
            return tunnelWebSocketURL(for: gateway)
        case .lan:
            return lanWebSocketURL(for: gateway)
        case .auto:
            if !gateway.tunnelHost.isEmpty {
                return tunnelWebSocketURL(for: gateway)
            }
            return lanWebSocketURL(for: gateway)
        }
    }

    private static func tunnelWebSocketURL(for gateway: GatewayConfig) -> String {
        let base = gateway.tunnelHost
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .replacingOccurrences(of: "https://", with: "wss://")
            .replacingOccurrences(of: "http://", with: "ws://")
        return "\(base)/ws?token=\(gateway.token)"
    }

    private static func lanWebSocketURL(for gateway: GatewayConfig) -> String {
        let host = gateway.lanHost
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "https://", with: "")
        return "ws://\(host):\(gateway.port)/ws?token=\(gateway.token)"
    }

    private func startReceiving() {
        webSocketTask?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleMessage(text)
                    }
                @unknown default:
                    break
                }
                self.startReceiving()
            case .failure(let error):
                NSLog("[OpenClawWS] Receive error: %@", error.localizedDescription)
                self.isConnected = false
                self.scheduleReconnect()
            }
        }
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        if type == "event" {
            handleEvent(json)
        } else if type == "res" {
            let ok = json["ok"] as? Bool ?? false
            if ok {
                NSLog("[OpenClawWS] Connected and authenticated")
                isConnected = true
                reconnectDelay = 2
            } else {
                let error = json["error"] as? [String: Any]
                let msg = error?["message"] as? String ?? "unknown"
                if OpenClawDeviceIdentity.isPairingPending(json) {
                    NSLog("[OpenClawWS] Awaiting pairing approval on gateway — will retry via reconnect backoff")
                } else {
                    NSLog("[OpenClawWS] Connect failed: %@ (full response: %@)", msg, text)
                }
            }
        }
    }

    private func handleEvent(_ json: [String: Any]) {
        guard let event = json["event"] as? String else { return }
        let payload = json["payload"] as? [String: Any] ?? [:]

        switch event {
        case "connect.challenge":
            let nonce = (payload["nonce"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            guard !nonce.isEmpty else {
                NSLog("[OpenClawWS] connect.challenge missing nonce")
                return
            }
            sendConnectHandshake(nonce: nonce)
        case "node.invoke.request":
            handleInvokeRequest(payload)
        case "heartbeat":
            handleHeartbeatEvent(payload)
        case "cron":
            handleCronEvent(payload)
        default:
            break
        }
    }

    private func sendConnectHandshake(nonce: String) {
        let token = Self.activeGateway()?.token ?? Config.preferredGatewayToken
        let device = OpenClawDeviceIdentity.deviceConnectParams(
            clientId: "gateway-client",
            clientMode: "node",
            role: "node",
            scopes: [],
            token: token,
            nonce: nonce,
            platform: "ios"
        )
        let connectMsg: [String: Any] = [
            "type": "req",
            "id": UUID().uuidString,
            "method": "connect",
            "params": [
                "minProtocol": 4,
                "maxProtocol": 4,
                "client": [
                    "id": "gateway-client",
                    "displayName": "OpenGlasses",
                    "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
                    "platform": "ios",
                    "mode": "node"
                ] as [String: Any],
                "role": "node",
                "scopes": [] as [String],
                "caps": ["camera"] as [String],
                "commands": ["camera.list", "camera.snap", "camera.clip"] as [String],
                "permissions": ["camera.capture": true] as [String: Any],
                "auth": [
                    "token": token
                ],
                "device": device
            ] as [String: Any]
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: connectMsg),
              let string = String(data: data, encoding: .utf8) else { return }
        webSocketTask?.send(.string(string)) { error in
            if let error {
                NSLog("[OpenClawWS] Handshake send error: %@", error.localizedDescription)
            }
        }
    }

    private func handleHeartbeatEvent(_ payload: [String: Any]) {
        let status = payload["status"] as? String ?? ""
        guard status == "sent",
              let preview = payload["preview"] as? String, !preview.isEmpty else { return }

        let silent = payload["silent"] as? Bool ?? false
        guard !silent else { return }

        NSLog("[OpenClawWS] Heartbeat notification: %@", String(preview.prefix(100)))
        onNotification?(preview)
    }

    private func handleCronEvent(_ payload: [String: Any]) {
        let action = payload["action"] as? String ?? ""
        guard action == "finished" else { return }

        let summary = payload["summary"] as? String
            ?? payload["result"] as? String
            ?? ""
        guard !summary.isEmpty else { return }

        NSLog("[OpenClawWS] Cron result (%d chars): %@", summary.count, String(summary.prefix(100)))
        onNotification?(summary)
    }

    // MARK: - Node invoke (camera capability)

    private static var nodeId: String {
        OpenClawDeviceIdentity.deviceId(for: OpenClawDeviceIdentity.signingKey())
    }

    private func handleInvokeRequest(_ payload: [String: Any]) {
        guard let id = payload["id"] as? String,
              let command = payload["command"] as? String else { return }
        var params: [String: Any] = [:]
        if let pj = payload["paramsJSON"] as? String,
           let d = pj.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            params = obj
        }
        NSLog("[OpenClawWS] node.invoke.request: %@ (id=%@)", command, id)
        Task { [weak self] in
            await self?.executeInvoke(id: id, command: command, params: params)
        }
    }

    @MainActor
    private func executeInvoke(id: String, command: String, params: [String: Any]) async {
        switch command {
        case "camera.list":
            let devices: [[String: Any]] = [
                ["id": "glasses", "name": "Ray-Ban Glasses (DAT)", "position": "front", "deviceType": "glasses"],
                ["id": "phone-back", "name": "iPhone Back Camera", "position": "back", "deviceType": "builtInWideAngleCamera"]
            ]
            sendInvokeResult(id: id, ok: true, payload: ["devices": devices])

        case "camera.snap":
            guard UIApplication.shared.applicationState == .active else {
                sendInvokeError(id: id, code: "NODE_BACKGROUND_UNAVAILABLE",
                                message: "app not foreground; open OpenGlasses to allow camera capture")
                return
            }
            guard let capture = cameraSnap else {
                sendInvokeError(id: id, code: "UNAVAILABLE", message: "camera capture not wired")
                return
            }
            onAgentCapture?("Hondo is taking a photo")
            AudioServicesPlaySystemSound(1108) // camera shutter
            do {
                let raw = try await capture()
                let bounded = LLMImagePreparer.prepared(raw)
                var width = 0
                var height = 0
                if let img = UIImage(data: bounded), let cg = img.cgImage {
                    width = cg.width
                    height = cg.height
                }
                sendInvokeResult(id: id, ok: true, payload: [
                    "format": "jpg",
                    "base64": bounded.base64EncodedString(),
                    "width": width,
                    "height": height
                ])
            } catch {
                sendInvokeError(id: id, code: "CAPTURE_FAILED", message: error.localizedDescription)
            }

        case "camera.clip":
            guard UIApplication.shared.applicationState == .active else {
                sendInvokeError(id: id, code: "NODE_BACKGROUND_UNAVAILABLE",
                                message: "app not foreground; open OpenGlasses to allow camera capture")
                return
            }
            let requested = (params["durationMs"] as? NSNumber)?.intValue ?? 3000
            let durationMs = min(max(requested, 1000), 30000)
            let includeAudio = (params["includeAudio"] as? Bool) ?? true
            let facing = (params["facing"] as? String) ?? "back"
            onAgentCapture?("Hondo is recording a \(Int((Double(durationMs) / 1000.0).rounded())) second video")
            AudioServicesPlaySystemSound(1117) // begin recording
            do {
                let data = try await OpenClawClipRecorder().record(
                    durationMs: durationMs, includeAudio: includeAudio, facing: facing)
                AudioServicesPlaySystemSound(1118) // end recording
                sendInvokeResult(id: id, ok: true, payload: [
                    "format": "mp4",
                    "base64": data.base64EncodedString(),
                    "durationMs": durationMs,
                    "hasAudio": includeAudio
                ])
            } catch {
                AudioServicesPlaySystemSound(1118)
                sendInvokeError(id: id, code: "CAPTURE_FAILED", message: error.localizedDescription)
            }

        default:
            sendInvokeError(id: id, code: "UNSUPPORTED", message: "command not supported: \(command)")
        }
    }

    private func sendInvokeResult(id: String, ok: Bool, payload: [String: Any]) {
        var params: [String: Any] = [
            "id": id,
            "nodeId": Self.nodeId,
            "ok": ok
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let json = String(data: data, encoding: .utf8) {
            params["payloadJSON"] = json
        }
        sendRequest(method: "node.invoke.result", params: params)
    }

    private func sendInvokeError(id: String, code: String, message: String) {
        NSLog("[OpenClawWS] invoke error id=%@ code=%@ msg=%@", id, code, message)
        sendRequest(method: "node.invoke.result", params: [
            "id": id,
            "nodeId": Self.nodeId,
            "ok": false,
            "error": ["code": code, "message": message]
        ])
    }

    private func sendRequest(method: String, params: [String: Any]) {
        let msg: [String: Any] = [
            "type": "req",
            "id": UUID().uuidString,
            "method": method,
            "params": params
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: msg),
              let string = String(data: data, encoding: .utf8) else { return }
        webSocketTask?.send(.string(string)) { error in
            if let error {
                NSLog("[OpenClawWS] %@ send error: %@", method, error.localizedDescription)
            }
        }
    }

    private func scheduleReconnect() {
        guard shouldReconnect else { return }
        NSLog("[OpenClawWS] Reconnecting in %.0fs", reconnectDelay)
        DispatchQueue.main.asyncAfter(deadline: .now() + reconnectDelay) { [weak self] in
            guard let self, self.shouldReconnect else { return }
            self.reconnectDelay = min(self.reconnectDelay * 2, self.maxReconnectDelay)
            self.establishConnection()
        }
    }
}
