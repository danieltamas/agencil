/* API contract: docs/U10-SPEC.md, Agencil target.
 @MainActor final class RingSceneController {
   let layer: CALayer
   init(seats: [String], reduceMotion: Bool, visible: Bool)
   func play(_ events: [SynapseEvent])
   func setVisible(_ visible: Bool)
   func setLive(_ live: Bool)
   private(set) var sparkLog: [String]
   func showFinalFrame()
 }
 enum SynapseProbe {
   static func animationCount(in layer: CALayer?) -> Int
   static func animatedKeyPaths(in layer: CALayer?) -> Set<String>
 }
 struct CouncilRingView: View {
   init(seats: [String], events: [SynapseEvent], live: Bool, reduceMotion: Bool = false)
 }
 Existing HouseRender.png and environment(\.stillImage, true) render the final frame.
 */
import AgencilCore
import AppKit
import SwiftUI
import Testing
@testable import Agencil

@Suite(.serialized) @MainActor struct U10SceneTests {
    private let seats = ["maya", "jonas", "lee", "orbit", "lumen"]
    private var claims: [SynapseEvent] {
        (0..<40).map { .claim(id: "claim-\($0)", seat: seats[$0 % seats.count]) }
    }

    @Test func hiddenEventsNeverAnimateLogOrReplay() {
        let scene = RingSceneController(seats: seats, reduceMotion: false, visible: false)
        #expect(SynapseProbe.animationCount(in: scene.layer) == 0)
        scene.play(claims)
        scene.setLive(true)
        #expect(SynapseProbe.animationCount(in: scene.layer) == 0)
        #expect(scene.sparkLog.isEmpty)
        scene.setLive(false)
        scene.setVisible(true)
        #expect(SynapseProbe.animationCount(in: scene.layer) == 0)
        scene.play(claims)
        #expect(scene.sparkLog.isEmpty)
        #expect(SynapseProbe.animationCount(in: scene.layer) == 0)
        scene.play([.claim(id: "fresh", seat: "maya")])
        #expect(scene.sparkLog == ["fresh"])
        scene.setVisible(false)
        scene.setLive(true)
        scene.play([.rebuttal(id: "hidden-r", from: "maya", to: "lee"),
                    .verdict("PASS", minority: ["lee"])])
        #expect(SynapseProbe.animationCount(in: scene.layer) == 0)
    }

    @Test func breathRunsOnlyWhenVisibleAndLive() {
        let scene = RingSceneController(seats: seats, reduceMotion: false, visible: true)
        scene.setLive(false)
        #expect(SynapseProbe.animatedKeyPaths(in: scene.layer).isEmpty)
        scene.setLive(true)
        #expect(!SynapseProbe.animatedKeyPaths(in: scene.layer).isEmpty)
        scene.setLive(false)
        #expect(SynapseProbe.animatedKeyPaths(in: scene.layer).isEmpty)
        scene.setLive(true)
        scene.setVisible(false)
        #expect(SynapseProbe.animationCount(in: scene.layer) == 0)
    }

    @Test func reducedMotionUsesOnlyOpacityEvenWhileLiveAndPlaying() {
        let scene = RingSceneController(seats: seats, reduceMotion: true, visible: true)
        scene.setLive(true)
        #expect(SynapseProbe.animatedKeyPaths(in: scene.layer).isSubset(of: ["opacity"]))
        let events = claims + [.rebuttal(id: "r", from: "maya", to: "lee"),
            .agreement(id: "a", between: "maya", and: "lee"), .verdict("PASS", minority: ["lee"])]
        for event in events {
            scene.play([event])
            #expect(SynapseProbe.animatedKeyPaths(in: scene.layer).isSubset(of: ["opacity"]))
        }
        scene.showFinalFrame()
        #expect(SynapseProbe.animationCount(in: scene.layer) == 0)
    }

    @Test func fortySparksAreDistinctAndNeverReplay() {
        for reduced in [false, true] {
            let scene = RingSceneController(seats: seats, reduceMotion: reduced, visible: true)
            scene.play(claims)
            #expect(scene.sparkLog == (0..<40).map { "claim-\($0)" })
            scene.play(claims)
            for chunk in stride(from: 0, to: 40, by: 5) {
                scene.play(Array(claims[chunk..<chunk + 5]))
            }
            #expect(scene.sparkLog.count == 40)
            #expect(Set(scene.sparkLog).count == 40)
            #expect(scene.sparkLog == (0..<40).map { "claim-\($0)" })
        }
    }

    @Test func stillImageDependsOnFinalStateAndActuallyDrawsVerdict() throws {
        let verdict: SynapseEvent = .verdict("PASS", minority: ["lee"])
        let first = claims + [.rebuttal(id: "r1", from: "maya", to: "lee"), verdict]
        let second: [SynapseEvent] = [.seatStarted("jonas"), .claim(id: "other", seat: "lee"),
            .agreement(id: "a2", between: "jonas", and: "maya"), verdict]
        for look in Look.allCases {
            func render(_ events: [SynapseEvent]) throws -> Data {
                try HouseRender.png(CouncilRingView(seats: seats, events: events, live: false)
                    .environment(\.stillImage, true), look: look, scale: 1,
                    now: DemoStore.now, width: 300, height: 240)
            }
            let a = try render(first)
            let b = try render(second)
            let empty = try render([])
            let bitmap = try #require(NSBitmapImageRep(data: a))
            #expect(bitmap.pixelsWide == 300 && bitmap.pixelsHigh == 240)
            #expect(a == b)
            #expect(a != empty)
        }
    }
}
