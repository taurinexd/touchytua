import CoreImage
import Foundation

/// Helpers for `touchytua pair` / `daemon --ensure`.
public enum Setup {
    public static let launchAgentLabel = "com.taurinexd.touchytua"

    /// MagicDNS name of this Mac from `tailscale status --json`, nil when
    /// Tailscale is not running.
    public static func tailscaleDNSName(fromStatusJSON data: Data) -> String? {
        guard let status = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              status["BackendState"] as? String == "Running",
              let me = status["Self"] as? [String: Any],
              var name = me["DNSName"] as? String, !name.isEmpty else { return nil }
        if name.hasSuffix(".") { name.removeLast() }
        return name
    }

    public static func endpoints(lanIP: String?, tailscaleName: String?, port: UInt16) -> [String] {
        var out: [String] = []
        if let lanIP { out.append("lan:\(lanIP):\(port)") }
        if let tailscaleName { out.append("ts:\(tailscaleName):\(port)") }
        return out
    }

    /// First private IPv4 address on a non-loopback interface (en*).
    public static func lanIPv4() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let name = String(cString: entry.pointee.ifa_name)
            guard name.hasPrefix("en"), let addr = entry.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
        }
        return nil
    }

    /// QR modules (true = dark), one entry per module, no quiet zone.
    public static func qrMatrix(_ text: String) -> [[Bool]]? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let image = filter.outputImage else { return nil }
        let size = Int(image.extent.width)
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        CIContext().render(image, toBitmap: &pixels, rowBytes: size * 4,
                           bounds: image.extent, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        // CoreImage's origin is bottom-left: flip rows.
        return (0..<size).reversed().map { y in (0..<size).map { x in pixels[(y * size + x) * 4] < 128 } }
    }

    /// Two matrix rows per text line with half-block characters (true = filled).
    public static func halfBlocks(_ matrix: [[Bool]]) -> String {
        stride(from: 0, to: matrix.count, by: 2).map { y in
            let top = matrix[y]
            let bottom = y + 1 < matrix.count ? matrix[y + 1] : Array(repeating: false, count: top.count)
            return zip(top, bottom).map { t, b in t && b ? "█" : t ? "▀" : b ? "▄" : " " }.joined()
        }.joined(separator: "\n")
    }

    /// Terminal QR for dark backgrounds: light modules drawn, 2-module quiet zone.
    public static func terminalQR(_ text: String) -> String? {
        guard let m = qrMatrix(text) else { return nil }
        let pad = 2, n = m.count + pad * 2
        let inverted = (0..<n).map { y in (0..<n).map { x in
            let (my, mx) = (y - pad, x - pad)
            guard my >= 0, my < m.count, mx >= 0, mx < m.count else { return true }
            return !m[my][mx]
        } }
        return halfBlocks(inverted)
    }

    public static func launchAgentPlist(daemonPath: String, logPath: String) -> Data {
        let plist: [String: Any] = [
            "Label": launchAgentLabel,
            "ProgramArguments": [daemonPath],
            "RunAtLoad": true,
            "KeepAlive": true,
            "StandardOutPath": logPath,
            "StandardErrorPath": logPath,
            "ProcessType": "Background",
        ]
        return (try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)) ?? Data()
    }
}
