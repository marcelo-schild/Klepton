// Surreal Touch through Surreal Interactive's own visionOS SDK
// (github.com/surreal-interactive/SwiftSDKBinary, Apache-2.0), linked into a
// Surreal build by gen_xcodeproj.py (KL_SURREAL_SDK; see kl_surreal_sdk.h).
import Foundation
import QuartzCore
import simd

/// The pose source for Surreal mode when Surreal's SDK is linked. KleptonSurrealBackend reads
/// the controllers' own tracking and can align it to the headset only from a grip hold; on
/// hardware that drifted 15–45 cm near the head and 20–30 cm in fast swings, enough to miss
/// Half-Life: Alyx's backpack and to throw sideways. The SDK solves that alignment itself —
/// clock sync, latency, the controller-to-world and hand-to-controller transforms, whether
/// the controller is held — with its own ARKit hand tracking and its own Bluetooth
/// connection, so KleptonSurrealBackend must not be connected while it runs.
final class KleptonSurrealSDK: @unchecked Sendable {
    static let shared = KleptonSurrealSDK()

    /// Whether this app was built with the SDK — decided when the game is built for Surreal
    /// Touch (gen_xcodeproj.py), never at run time. Only consulted in Surreal mode
    /// (KleptonControllers.usesSurrealSDK).
    static var enabled: Bool {
        #if KL_SURREAL_SDK
        return true
        #else
        return false
        #endif
    }

    private let lock = NSLock()
    private var input = [KleptonHandState(), KleptonHandState()]   // under lock; the SDK's thread writes
    private var settings = SurrealInputSettings()                   // under lock
    private var started = false                                     // under lock
    private var gotButtons = false                                  // under lock
    // Render thread only.
    private var pendingPolls: [[Int64]] = [[], []]
    private var wasConnected = [false, false]
    private var nextPulse: [Double] = [0, 0]

    private let logQueue = DispatchQueue(label: "klepton.surreal.sdk.log", qos: .utility)
    private var log: FileHandle?
    private var logBytes = 0

    private init() {}

    /// Connection events and the first buttons only, to Documents/surreal-sdk.log; written on
    /// its own queue, never on the render thread, like KleptonSurrealBackend's surreal-ble.log.
    private func trace(_ message: String) {
        NSLog("[surreal-sdk] %@", message)
        let stamp = CACurrentMediaTime()
        logQueue.async { [self] in
            guard logBytes < 256 * 1024 else { return }
            if log == nil {
                let file = URL.documentsDirectory.appendingPathComponent("surreal-sdk.log")
                FileManager.default.createFile(atPath: file.path, contents: nil)
                log = try? FileHandle(forWritingTo: file)
            }
            let data = Data((String(format: "%.3f ", stamp) + message + "\n").utf8)
            try? log?.write(contentsOf: data)
            logBytes += data.count
        }
    }

    func start(settings: SurrealInputSettings) {
        #if KL_SURREAL_SDK
        lock.lock()
        self.settings = settings
        let first = !started
        started = true
        lock.unlock()
        guard first else { return }
        trace("starting Surreal Interactive's SDK")
        // Start first, as Surreal's Unity integration does: SVRStart makes a new provider
        // (make_shared<dm::SubsystemProvider>), and a callback appended before it is dropped
        // with the old one — on hardware no button ever arrived.
        SVRStart()
        SVRSetButtonCallback { _, chirality, buttons in
            KleptonSurrealSDK.shared.receive(chirality: Int(chirality), buttons: buttons)
        }
        #endif
    }

    #if KL_SURREAL_SDK
    /// The SDK's thread. The same 13-byte packet KleptonSurrealBackend decodes, so the Touch
    /// mapping, analog scale, dead zone and stick touch are the same with either source.
    private func receive(chirality: Int, buttons b: SVRButtons) {
        guard (0...1).contains(chirality) else { return }
        let flags = (b.primary_button != 0 ? 1 : 0) | (b.secondary_button != 0 ? 2 : 0)
            | (b.menu_button != 0 ? 4 : 0) | (b.stick_z_button != 0 ? 8 : 0)
        let packet = Data([UInt8](repeating: 0, count: 8)
                          + [UInt8(flags), b.trigger_button_value, b.grip_button_value, b.stick_x_value, b.stick_y_value])
        lock.lock()
        let first = !gotButtons
        gotButtons = true
        if let decoded = SurrealWire.buttons(packet, hand: chirality == 0 ? .left : .right, settings: settings) {
            input[chirality] = decoded
        }
        lock.unlock()
        if first { trace("first buttons from the SDK (hand \(chirality))") }
    }
    #endif

    /// Render thread, once per hand per frame.
    func sample(hand: Int) -> KleptonHandState {
        var released = KleptonHandState()
        released.position = [0, -10, 0]; released.orientation = simd_quatf(angle: 0, axis: [0, 1, 0])
        #if KL_SURREAL_SDK
        let chirality = Int32(hand)
        let now = SVRTimeNow()
        // As the SDK's own Unity integration does: the poll three frames back is the one
        // whose frame is finishing now, which is how the SDK learns the render latency.
        if pendingPolls[hand].count >= 3 {
            SVRRenderFinish(chirality, pendingPolls[hand].removeFirst(), now)
        }
        var pose = SVRPose(), linear = SVRVector3f(), angular = SVRVector3f()
        let connected = SVRIsConnected(chirality)
        let tracked = connected && SVRPollDevicePose(chirality, now, &pose, &linear, &angular, nil)
        pendingPolls[hand].append(now)
        if connected != wasConnected[hand] {
            wasConnected[hand] = connected
            trace("hand \(hand) \(connected ? "connected" : "disconnected")")
        }
        // Until it has aligned a controller the SDK answers (100, 100, 100): not a pose.
        guard tracked, max(abs(pose.x), abs(pose.y), abs(pose.z)) < 50 else { return released }
        lock.lock()
        var result = input[hand]
        lock.unlock()
        // The C API is the one Surreal's Unity SDK hands straight to Unity: left-handed,
        // +Z forward. ARKit is right-handed with -Z forward, so Z is mirrored — position
        // and linear velocity negate z, and a rotation (an axial quantity) negates x and y.
        // On hardware, as-is gave correlation -0.99 against the visible hand along Z and
        // inverted pitch; mirrored, the median distance to the hand was 5–7 cm.
        result.fromController = true
        result.position = SIMD3(pose.x, pose.y, -pose.z)
        result.orientation = simd_quatf(ix: -pose.qx, iy: -pose.qy, iz: pose.qz, r: pose.qw).normalized
        result.linearVelocity = SIMD3(linear.x, linear.y, -linear.z)
        result.angularVelocity = SIMD3(-angular.x, -angular.y, angular.z)
        return result
        #else
        return released
        #endif
    }

    func vibrate(hand: Int, amplitude: Float, duration: Float) {
        #if KL_SURREAL_SDK
        guard (0...1).contains(hand), amplitude > 0, amplitude.isFinite, duration.isFinite else { return }
        // The runtime's level arrives every frame; one pulse per 20 ms is plenty.
        let t = CACurrentMediaTime()
        guard t >= nextPulse[hand] else { return }
        nextPulse[hand] = t + 0.02
        _ = SVRHapticContinuous(Int32(hand), min(1, amplitude), 170, Double(min(0.25, max(0.03, duration))))
        #endif
    }
}
