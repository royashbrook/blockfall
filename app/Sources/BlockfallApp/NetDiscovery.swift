// ============================================================================
// Blockfall — Bonjour discovery (Track H, Swift side)
// Publishes "_blockfall._udp" when hosting and browses/resolves to find a host
// when joining. Resolves to an IPv4 address handed to the C engine's
// bf_net_client_connect. (LAN behavior is verified on real machines, per the
// M4 acceptance — two+ Airs on one network.)
// ============================================================================
import Foundation

final class NetDiscovery: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    static let serviceType = "_blockfall._udp."
    private var service: NetService?
    private var browser: NetServiceBrowser?
    private var resolving: [NetService] = []
    var onHostFound: ((String, UInt16) -> Void)?

    func publish(port: Int32) {
        let name = Host.current().localizedName ?? "Blockfall Host"
        let s = NetService(domain: "local.", type: NetDiscovery.serviceType, name: name, port: port)
        s.delegate = self
        s.publish()
        service = s
        NSLog("Blockfall: hosting, published \(NetDiscovery.serviceType) on :\(port)")
    }

    func browse() {
        let b = NetServiceBrowser()
        b.delegate = self
        b.searchForServices(ofType: NetDiscovery.serviceType, inDomain: "local.")
        browser = b
        NSLog("Blockfall: browsing for a host…")
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        service.delegate = self
        resolving.append(service)
        service.resolve(withTimeout: 5)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let addrs = sender.addresses else { return }
        for data in addrs {
            if let ip = NetDiscovery.ipv4(from: data) {
                onHostFound?(ip, UInt16(sender.port))
                break
            }
        }
    }

    private static func ipv4(from data: Data) -> String? {
        return data.withUnsafeBytes { raw -> String? in
            guard let base = raw.baseAddress else { return nil }
            let sa = base.assumingMemoryBound(to: sockaddr.self)
            guard sa.pointee.sa_family == sa_family_t(AF_INET) else { return nil }
            var addr = base.assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN))
            return String(cString: buf)
        }
    }
}
