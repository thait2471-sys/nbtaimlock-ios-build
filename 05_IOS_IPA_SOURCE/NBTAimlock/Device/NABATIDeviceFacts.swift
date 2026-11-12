import Foundation
import UIKit

/// Real hardware facts, read from the OS.
///
/// The web client fills its "DEVICE OPTIMIZATION" panel from browser APIs
/// (`navigator.hardwareConcurrency`, `navigator.deviceMemory`,
/// `navigator.storage.estimate()`). iOS has direct equivalents, so this reads
/// the same categories of value natively — no estimates, no invented numbers.
///
/// Anything the OS will not disclose (total RAM on iOS is available, free RAM is
/// not) reports `nil` and the UI prints "Không xác định", exactly like the web
/// client does when a browser API is missing.
public struct NABATIDeviceFacts {
    public let model: String
    public let systemName: String
    public let systemVersion: String
    public let machineId: String
    public let cpuCores: Int
    public let physicalMemoryGB: Double
    public let screenSize: String
    public let screenScale: CGFloat
    /// Total on-device storage, in gigabytes. `nil` when the volume will not
    /// report a capacity (rare, but it happens on some managed devices).
    public let storageGB: Double?

    /// Cached instance. `volumeTotalCapacityKey` is a filesystem stat, and the
    /// dashboard re-renders on every toggle — the values it reports are fixed
    /// for the life of the process, so reading them once is both faster and
    /// more accurate than a per-render sample.
    public static let shared = current()

    public static func current() -> NABATIDeviceFacts {
        let info = ProcessInfo.processInfo
        let device = UIDevice.current
        let screen = UIScreen.main

        // `volumeTotalCapacityKey` reports the whole volume; on iOS that is the
        // device's own data partition, which is the figure a customer means by
        // "dung lượng máy".
        var storage: Double? = nil
        if let values = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeTotalCapacityKey]),
           let bytes = values.volumeTotalCapacity, bytes > 0 {
            storage = Double(bytes) / 1_073_741_824.0
        }

        return NABATIDeviceFacts(
            model: NABATIDevice.shared.modelName,
            systemName: device.systemName,
            systemVersion: device.systemVersion,
            machineId: NABATIDevice.shared.machineId,
            cpuCores: info.processorCount,
            physicalMemoryGB: Double(info.physicalMemory) / 1_073_741_824.0,
            screenSize: "\(Int(screen.bounds.width))×\(Int(screen.bounds.height))",
            screenScale: screen.scale,
            storageGB: storage
        )
    }

    public var cpuText: String {
        cpuCores > 0 ? "\(cpuCores) nhân" : "Không xác định"
    }

    public var ramText: String {
        // iOS reports physical memory in clean binary gigabytes, so one decimal
        // place is exact rather than rounded (an iPhone 15 Pro reads "8.0 GB").
        physicalMemoryGB > 0 ? String(format: "%.1f GB", physicalMemoryGB) : "Không xác định"
    }

    public var storageText: String {
        guard let storageGB = storageGB else { return "Không xác định" }
        return String(format: "%.1f GB", storageGB)
    }

    public var osText: String {
        "\(systemName) \(systemVersion)"
    }
}
