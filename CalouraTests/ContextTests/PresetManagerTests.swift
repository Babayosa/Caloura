import XCTest
@testable import Caloura

@MainActor
final class PresetManagerTests: XCTestCase {

    nonisolated(unsafe) private var presetManager: PresetManager!

    override nonisolated func setUp() {
        super.setUp()
        presetManager = MainActor.assumeIsolated {
            PresetManager.shared
        }
    }

    // MARK: - Lookup by name

    func testPresetByName_quickCapture() {
        let preset = presetManager.preset(named: "Quick Capture")
        XCTAssertNotNil(preset)
        XCTAssertEqual(preset?.name, "Quick Capture")
        XCTAssertEqual(preset?.copyMode, .image)
    }

    func testPresetByName_lectureNotes() {
        let preset = presetManager.preset(named: "Lecture Notes")
        XCTAssertNotNil(preset)
        XCTAssertEqual(preset?.name, "Lecture Notes")
        XCTAssertEqual(preset?.copyMode, .citation)
        XCTAssertEqual(preset?.subfolder, "Lectures")
    }

    func testPresetByName_nonexistent() {
        let preset = presetManager.preset(named: "Nonexistent Preset")
        XCTAssertNil(preset)
    }

    // MARK: - Category to preset mapping

    func testPresetForCategory_code() {
        let preset = presetManager.presetForCategory(.code)
        XCTAssertNotNil(preset)
        XCTAssertEqual(preset?.name, "Code Snippet")
    }

    func testPresetForCategory_lecture() {
        let preset = presetManager.presetForCategory(.lecture)
        XCTAssertNotNil(preset)
        XCTAssertEqual(preset?.name, "Lecture Notes")
    }

    func testPresetForCategory_document() {
        let preset = presetManager.presetForCategory(.document)
        XCTAssertNotNil(preset)
        XCTAssertEqual(preset?.name, "Assignment")
    }

    func testPresetForCategory_web() {
        let preset = presetManager.presetForCategory(.web)
        XCTAssertNotNil(preset)
        XCTAssertEqual(preset?.name, "Assignment")
    }

    func testPresetForCategory_chat() {
        let preset = presetManager.presetForCategory(.chat)
        XCTAssertNotNil(preset)
        XCTAssertEqual(preset?.name, "Quick Capture")
    }

    // MARK: - Built-in preset initialization

    func testBuiltInPresetNames_containsAll() {
        let names = PresetManager.builtInPresetNames
        XCTAssertTrue(names.contains("Quick Capture"))
        XCTAssertTrue(names.contains("Lecture Notes"))
        XCTAssertTrue(names.contains("Code Snippet"))
        XCTAssertTrue(names.contains("Assignment"))
        XCTAssertEqual(names.count, 4)
    }

    func testAllBuiltInPresetsExist() {
        for name in PresetManager.builtInPresetNames {
            XCTAssertNotNil(presetManager.preset(named: name), "Built-in preset '\(name)' should exist")
        }
    }
}
