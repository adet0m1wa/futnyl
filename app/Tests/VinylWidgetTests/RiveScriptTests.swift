import Foundation
import XCTest
@testable import VinylWidget
@preconcurrency import RiveRuntime

@MainActor
final class RiveScriptTests: XCTestCase {
    func testNativeRuntimeExecutesBuiltScript() async throws {
        guard let path = ProcessInfo.processInfo.environment["FUTNYL_RIV_TEST_PATH"] else {
            throw XCTSkip("Set FUTNYL_RIV_TEST_PATH to a built .riv to exercise native scripting")
        }
        let worker = try await Worker(configuration: .init(enableGPUCanvas: true))
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let file = try await RiveRuntime.File(source: .data(data), worker: worker)
        let board = try await file.createArtboard("vinyl ")
        let vm = try await file.createViewModelInstance(.viewModelDefault(from: .artboardDefault(board)))
        let machine = try await board.createStateMachine()
        try await machine.bindViewModelInstances(main: vm)
        vm.setValue(of: BoolProperty(path: "isPlaying"), to: true)
        vm.setValue(of: BoolProperty(path: "spotifyOpen"), to: true)
        vm.setValue(of: BoolProperty(path: "hostManagesCovers"), to: true)
        vm.setValue(of: NumberProperty(path: "coverAOpacity"), to: 0)
        let rotation = NumberProperty(path: "rotationPanicIsland")
        let before = try await vm.value(of: rotation)
        for _ in 0..<120 { machine.advance(by: 1.0 / 60) }
        let after = try await vm.value(of: rotation)
        XCTAssertGreaterThan(abs(after - before), 1, "The Luau script must advance the record rotation")
        let opacity = try await vm.value(of: NumberProperty(path: "coverAOpacity"))
        XCTAssertEqual(opacity, 0, "The script must preserve host-controlled cover loading state")
        vm.setValue(of: BoolProperty(path: "lyricsMode"), to: true)
        for (path, value) in WidgetLayout.sceneValues(lyrics: true) {
            vm.setValue(of: NumberProperty(path: path), to: value)
        }
        vm.setValue(of: StringProperty(path: "songTitle"), to: "A very long song…")
        for _ in 0..<30 { machine.advance(by: 1.0 / 60) }
        let compactRotation = try await vm.value(of: rotation)
        XCTAssertGreaterThan(abs(compactRotation - after), 1, "The same disc must keep spinning in inline lyrics mode")
        let spare = try await vm.value(of: NumberProperty(path: "recordBOpacity"))
        XCTAssertEqual(spare, 0, "The spare disc should be hidden without the storage overlay")
        let title = try await vm.value(of: StringProperty(path: "songTitle"))
        XCTAssertEqual(title, "A very long song…")
        vm.setValue(of: BoolProperty(path: "showingRecordB"), to: true)
        for _ in 0..<60 { machine.advance(by: 1.0 / 60) }
        let oldRecord = try await vm.value(of: NumberProperty(path: "recordAOpacity"))
        let currentRecord = try await vm.value(of: NumberProperty(path: "recordBOpacity"))
        XCTAssertEqual(oldRecord, 0)
        XCTAssertEqual(currentRecord, 1)
        vm.setValue(of: BoolProperty(path: "lyricsMode"), to: false)
        for _ in 0..<2 { machine.advance(by: 1.0 / 60) }
        let restoredRecord = try await vm.value(of: NumberProperty(path: "recordAOpacity"))
        XCTAssertEqual(restoredRecord, 1, "The full turntable should restore its record change animation")
        print("Native script rotation: \(before) -> \(after)")
    }
}
