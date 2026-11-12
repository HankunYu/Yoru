import Foundation
import Network
import Observation
import dnssd

/// Finds SMB servers advertised on the local network over Bonjour.
@MainActor
@Observable
final class SMBDiscovery {
    struct Service: Identifiable, Hashable, Sendable {
        let name: String
        let type: String
        let domain: String
        var id: String { "\(name).\(type)\(domain)" }
    }

    private(set) var services: [Service] = []
    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: "_smb._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let services = results.compactMap { result -> Service? in
                guard case .service(let name, let type, let domain, _) = result.endpoint else { return nil }
                return Service(name: name, type: type, domain: domain)
            }
            Task { @MainActor in
                self?.services = services.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }

    /// The host name a service runs on, e.g. `nas.local`. Unlike the service's display
    /// name, this is what a connection needs, and it survives the server changing address.
    nonisolated static func hostName(of service: Service) async -> String? {
        await withCheckedContinuation { continuation in
            Resolution(continuation).start(service)
        }
    }
}

/// One `DNSServiceResolve` call. Retains itself until it finishes or times out.
private final class Resolution: @unchecked Sendable {
    private let continuation: CheckedContinuation<String?, Never>
    private let queue = DispatchQueue(label: "com.hankunyu.Yoru.smb.resolve")
    // Only touched on `queue`.
    private var reference: DNSServiceRef?
    private var retained: Unmanaged<Resolution>?

    init(_ continuation: CheckedContinuation<String?, Never>) {
        self.continuation = continuation
    }

    func start(_ service: SMBDiscovery.Service) {
        queue.async { [self] in
            let retained = Unmanaged.passRetained(self)
            self.retained = retained
            let status = DNSServiceResolve(
                &reference, 0, 0, service.name, service.type, service.domain,
                { _, _, _, error, _, hostTarget, _, _, _, context in
                    guard let context else { return }
                    let resolution = Unmanaged<Resolution>.fromOpaque(context).takeUnretainedValue()
                    let host = error == kDNSServiceErr_NoError ? hostTarget.map { String(cString: $0) } : nil
                    resolution.finish(host)
                },
                retained.toOpaque()
            )
            guard status == kDNSServiceErr_NoError, let reference else {
                finish(nil)
                return
            }
            DNSServiceSetDispatchQueue(reference, queue)
            queue.asyncAfter(deadline: .now() + 5) { [self] in finish(nil) }
        }
    }

    // Runs on `queue`: the resolve callback is delivered there too.
    private func finish(_ host: String?) {
        guard let retained else { return }
        self.retained = nil
        if let reference {
            DNSServiceRefDeallocate(reference)
        }
        reference = nil
        // Resolved names are fully qualified, with a trailing dot.
        continuation.resume(returning: host.map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 })
        retained.release()
    }
}
