import Foundation
import Testing

@testable import TransomKit

@Suite("Host discovery")
struct HostDiscoveryTests {
    @Test("TXT fields use the shared discovery contract and real video port")
    func metadata() {
        let data = HostDiscovery.txtRecord(address: "192.168.1.20", videoPort: 48201)
        var fields: [String] = []
        var offset = 0
        while offset < data.count {
            let count = Int(data[offset])
            offset += 1
            #expect(offset + count <= data.count)
            fields.append(String(decoding: data[offset..<(offset + count)], as: UTF8.self))
            offset += count
        }
        #expect(fields.contains("v=1"))
        #expect(fields.contains("addr=192.168.1.20"))
        #expect(fields.contains("video=48201"))
        #expect(fields.contains("id=\(HostDiscovery.identity)"))
        #expect(fields.contains(where: { $0.hasPrefix("name=") }))
        #expect(HostDiscovery.identity == HostDiscovery.identity)
    }

    @Test("Control-only advertisement explicitly disables video")
    func controlOnly() {
        let data = HostDiscovery.txtRecord(address: "10.0.0.2", videoPort: nil)
        #expect(String(decoding: data, as: UTF8.self).contains("video=0"))
    }
}
