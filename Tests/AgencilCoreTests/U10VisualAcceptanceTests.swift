/* API contract: docs/U10-SPEC.md, AgencilCore.
 public enum SynapseEvent: Equatable, Sendable {
   case seatStarted(String)
   case claim(id: String, seat: String)
   case rebuttal(id: String, from: String, to: String)
   case agreement(id: String, between: String, and: String)
   case verdict(String, minority: [String])
 }
 public enum BurstKind: String, Equatable, Sendable { case spark, chord, thicken, retract, fill, fade }
 public struct Burst: Equatable, Sendable {
   public let key: String; public let kind: BurstKind
   public let from: String?; public let to: String?; public let duration: Double
 }
 public struct SynapseScript: Sendable {
   public init(reduceMotion: Bool = false)
   public mutating func feed(_ events: [SynapseEvent]) -> [Burst]
 }
 script.minorityThreads: [String] (sorted seat names, retained state).
 public enum MenuBarMode: Equatable, Sendable { case template, animating(fps: Int), badge }
 public enum MenuBarPolicy {
   public static let frameCount = 14
   public static func mode(live: Bool, screenAsleep: Bool, locked: Bool, reduceMotion: Bool) -> MenuBarMode
   public static func frame(tick: Int) -> Int
 }
 */
import AgencilCore
import Testing

struct U10VisualAcceptanceTests {
    private let seats = ["maya", "jonas", "lee", "orbit", "lumen"]

    @Test func fortyClaimsSparkOnceInFeedOrderAcrossChunkings() {
        let ids = (0..<40).map { "claim-\($0)" }
        let events: [SynapseEvent] = ids.enumerated().map {
            .claim(id: $0.element, seat: seats[$0.offset % seats.count])
        }
        for chunkSize in [1, 3, 7, 40] {
            var script = SynapseScript()
            var bursts: [Burst] = []
            for start in stride(from: 0, to: events.count, by: chunkSize) {
                let chunk = Array(events[start..<min(start + chunkSize, events.count)])
                bursts += script.feed(chunk + chunk)
                #expect(script.feed(chunk).isEmpty)
            }
            #expect(script.feed(events).isEmpty)
            #expect(bursts.count == 40)
            #expect(bursts.map(\.key) == ids.map { "spark:\($0)" })
            for (index, burst) in bursts.enumerated() {
                #expect(burst.kind == .spark)
                #expect(burst.from == seats[index % seats.count])
                #expect(burst.to == "core")
                #expect(burst.duration == 0.6 && burst.duration <= 1.2)
            }
        }
        var script = SynapseScript()
        #expect(script.feed([.claim(id: "shared", seat: "maya"),
                             .claim(id: "shared", seat: "lee")]).count == 1)
    }

    @Test func eventKindsDurationsAndVerdictOrder() throws {
        var script = SynapseScript()
        #expect(script.feed(seats.map { .seatStarted($0) }).isEmpty)
        let events: [SynapseEvent] = [
            .rebuttal(id: "r1", from: "maya", to: "lee"),
            .agreement(id: "a1", between: "lee", and: "jonas")
        ]
        let bursts = script.feed(events + events)
        #expect(bursts.count == 2)
        let chord = try #require(bursts.first)
        #expect(chord.key == "chord:r1" && chord.kind == .chord)
        #expect(chord.from == "maya" && chord.to == "lee" && chord.duration == 0.6)
        let thicken = try #require(bursts.last)
        #expect(thicken.key == "thicken:a1" && thicken.kind == .thicken)
        #expect(thicken.from == "lee" && thicken.to == "jonas" && thicken.duration == 0.4)
        #expect(script.feed(events).isEmpty)
        for verdict in ["PASS", "BLOCK", "INCOMPLETE"] {
            var final = SynapseScript()
            let event: SynapseEvent = .verdict(verdict, minority: ["maya", "jonas", "lee"])
            let ending = final.feed([event, event])
            #expect(ending.map(\.kind) == [.retract, .fill])
            #expect(ending.map(\.key) == ["retract", "fill:\(verdict)"])
            #expect(ending.first?.duration == 0.8)
            #expect(ending.allSatisfy { $0.duration >= 0 && $0.duration <= 1.2 })
            #expect(final.minorityThreads == ["jonas", "lee", "maya"])
            #expect(final.feed([event]).isEmpty)
            _ = final.feed([.seatStarted("orbit"), .claim(id: "later", seat: "orbit")])
            #expect(final.minorityThreads == ["jonas", "lee", "maya"])
        }
    }

    @Test func reducedMotionReplacesEveryBurstAndKeepsIdentityAndThreads() {
        let events: [SynapseEvent] = [.seatStarted("maya"), .claim(id: "c1", seat: "maya"),
            .rebuttal(id: "r1", from: "maya", to: "lee"),
            .agreement(id: "a1", between: "lee", and: "maya"),
            .verdict("PASS", minority: ["maya", "lee"])]
        var script = SynapseScript(reduceMotion: true)
        let bursts = script.feed(events + events)
        #expect(bursts.map(\.key) == ["fade:spark:c1", "fade:chord:r1", "fade:thicken:a1",
                                    "fade:retract", "fade:fill:PASS"])
        #expect(bursts.allSatisfy { $0.kind == .fade && $0.duration == 0.2 })
        #expect(bursts.first?.from == "maya" && bursts.first?.to == "core")
        #expect(script.feed(events).isEmpty)
        #expect(script.minorityThreads == ["lee", "maya"])
    }

    @Test func menuBarModeCoversAllSixteenCombinations() {
        // Index bits: live, asleep, locked, reduced. Explicit contract table.
        let expected: [MenuBarMode] = [.template, .animating(fps: 8), .template, .template,
            .template, .template, .template, .template, .template, .badge,
            .template, .template, .template, .template, .template, .template]
        for bits in 0..<16 {
            #expect(MenuBarPolicy.mode(live: bits & 1 != 0, screenAsleep: bits & 2 != 0,
                locked: bits & 4 != 0, reduceMotion: bits & 8 != 0) == expected[bits])
        }
    }

    @Test func menuBarFramesWrapIncludingNegativeTicks() {
        #expect(MenuBarPolicy.frameCount == 14)
        for tick in Array(-43...43) + [Int.min, Int.max] {
            let expected = ((tick % 14) + 14) % 14
            #expect(MenuBarPolicy.frame(tick: tick) == expected)
            #expect((0..<14).contains(MenuBarPolicy.frame(tick: tick)))
        }
    }
}
