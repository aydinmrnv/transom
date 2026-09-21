import Foundation
import Testing
@testable import TransomKit

@Suite("Independent window streams")
struct WindowVideoTests {
    @Test("window envelope preserves identity, dimensions and every payload byte")
    func envelope() {
        let inner = VideoWire.encodeFrame(seq: 9, ptsMicros: 1234, keyframe: true, data: Data([0, 255, 1]))
        let size = WireSize(w: 2600, h: 1800)
        let packet = VideoWire.encodeWindow(id: UInt64.max, generation: 7, size: size, payload: inner)
        #expect(packet.count == 25 + inner.count)
        #expect(Array(packet[17..<25]) == [0, 0, 10, 40, 0, 0, 7, 8])
        #expect(VideoWire.decode(packet) == .window(id: UInt64.max, generation: 7, size: size,
            message: .frame(seq: 9, ptsMicros: 1234, keyframe: true, data: Data([0,255,1]))))
        for count in 0..<packet.count - 3 { #expect(VideoWire.decode(Data(packet.prefix(count))) == nil) }
        #expect(VideoWire.decode(VideoWire.encodeWindow(id: 1, generation: 1, size: size, payload: packet)) == nil)
        for bad in [WireSize(w: 0, h: 10), WireSize(w: 8193, h: 10)] {
            #expect(VideoWire.decode(VideoWire.encodeWindow(id: 1, generation: 1, size: bad, payload: inner)) == nil)
        }
    }
}
