import XCTest
@testable import Povver

final class AutoAdvanceTests: XCTestCase {

    // MARK: - Helpers

    private func makeExercise(id: String, sets: [FocusModeSet]) -> FocusModeExercise {
        FocusModeExercise(instanceId: id, exerciseId: "eid-\(id)", name: "Ex \(id)", position: 0, sets: sets)
    }

    private func undoneSet(_ id: String) -> FocusModeSet {
        FocusModeSet(id: id, setType: .working, status: .planned)
    }

    private func doneSet(_ id: String) -> FocusModeSet {
        FocusModeSet(id: id, setType: .working, status: .done, weight: 80, reps: 8)
    }

    // MARK: - Tests

    func testAdvancesToNextSetInSameExercise() {
        let exercises = [makeExercise(id: "e1", sets: [doneSet("s1"), undoneSet("s2"), undoneSet("s3")])]
        let target = AutoAdvance.findNextUndoneSet(exercises: exercises, afterExercise: "e1", afterSet: "s1")
        XCTAssertEqual(target?.setId, "s2")
        XCTAssertEqual(target?.exerciseId, "e1")
    }

    func testAdvancesToNextExercise() {
        let exercises = [
            makeExercise(id: "e1", sets: [doneSet("s1"), doneSet("s2")]),
            makeExercise(id: "e2", sets: [undoneSet("s3"), undoneSet("s4")]),
        ]
        let target = AutoAdvance.findNextUndoneSet(exercises: exercises, afterExercise: "e1", afterSet: "s2")
        XCTAssertEqual(target?.exerciseId, "e2")
        XCTAssertEqual(target?.setId, "s3")
    }

    func testReturnsNilWhenAllDone() {
        let exercises = [makeExercise(id: "e1", sets: [doneSet("s1"), doneSet("s2")])]
        let target = AutoAdvance.findNextUndoneSet(exercises: exercises, afterExercise: "e1", afterSet: "s2")
        XCTAssertNil(target)
    }

    func testSkipsDoneSetsBetweenUndone() {
        let exercises = [makeExercise(id: "e1", sets: [doneSet("s1"), doneSet("s2"), undoneSet("s3")])]
        let target = AutoAdvance.findNextUndoneSet(exercises: exercises, afterExercise: "e1", afterSet: "s1")
        XCTAssertEqual(target?.setId, "s3")
    }

    func testSkipsFullyDoneExercises() {
        let exercises = [
            makeExercise(id: "e1", sets: [doneSet("s1")]),
            makeExercise(id: "e2", sets: [doneSet("s2")]),
            makeExercise(id: "e3", sets: [undoneSet("s3")]),
        ]
        let target = AutoAdvance.findNextUndoneSet(exercises: exercises, afterExercise: "e1", afterSet: "s1")
        XCTAssertEqual(target?.exerciseId, "e3")
        XCTAssertEqual(target?.setId, "s3")
    }
}
