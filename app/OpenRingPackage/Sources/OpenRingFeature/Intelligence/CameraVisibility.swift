import Foundation
import RingClient

/// Cameras the user has chosen not to see (for example a shared location).
public enum CameraVisibility {
    private static let key = "hiddenCameras"

    public static var hidden: Set<Int> {
        Set(UserDefaults.standard.array(forKey: key) as? [Int] ?? [])
    }

    public static func isHidden(_ id: Int) -> Bool { hidden.contains(id) }

    public static func setHidden(_ id: Int, _ hide: Bool) {
        var h = hidden
        if hide { h.insert(id) } else { h.remove(id) }
        UserDefaults.standard.set(Array(h), forKey: key)
    }

    public static func visible(_ devices: [RingDevice]) -> [RingDevice] {
        let h = hidden
        return devices.filter { !h.contains($0.id) }
    }
}
