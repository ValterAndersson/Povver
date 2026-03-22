import XCTest
@testable import Povver

final class GhostValueResolverTests: XCTestCase {

    // MARK: - Helpers

    private func makeExercise(sets: [FocusModeSet]) -> FocusModeExercise {
        FocusModeExercise(instanceId: "inst1", exerciseId: "ex1", name: "Bench Press", position: 0, sets: sets)
    }

    private func makeUndoneSet(
        id: String,
        weight: Double? = nil,
        reps: Int? = nil,
        targetWeight: Double? = nil,
        targetReps: Int? = nil,
        targetRir: Int? = nil
    ) -> FocusModeSet {
        FocusModeSet(id: id, setType: .working, status: .planned,
                     targetWeight: targetWeight, targetReps: targetReps, targetRir: targetRir,
                     weight: weight, reps: reps)
    }

    private func makeDoneSet(id: String) -> FocusModeSet {
        FocusModeSet(id: id, setType: .working, status: .done, weight: 80, reps: 8)
    }

    // MARK: - Tests

    func testLastSessionTakesPriority() {
        let exercise = makeExercise(sets: [makeUndoneSet(id: "s1"), makeUndoneSet(id: "s2")])
        let lastSession = LastSessionExerciseData(sets: [
            LastSessionSetData(setIndex: nil, weight: 80, reps: 8, rir: 2),
            LastSessionSetData(setIndex: nil, weight: 82.5, reps: 7, rir: 1),
        ])
        let result = GhostValueResolver.resolve(exercise: exercise, lastSession: lastSession)
        XCTAssertEqual(result["s1"]?.weight, 80)
        XCTAssertEqual(result["s1"]?.reps, 8)
        XCTAssertEqual(result["s1"]?.rir, 2)
        XCTAssertEqual(result["s2"]?.weight, 82.5)
        XCTAssertEqual(result["s2"]?.reps, 7)
        XCTAssertEqual(result["s2"]?.rir, 1)
    }

    func testTemplatePrescriptionFallback() {
        let exercise = makeExercise(sets: [
            makeUndoneSet(id: "s1", targetWeight: 60, targetReps: 10, targetRir: 3)
        ])
        let result = GhostValueResolver.resolve(exercise: exercise, lastSession: nil)
        XCTAssertEqual(result["s1"]?.weight, 60)
        XCTAssertEqual(result["s1"]?.reps, 10)
        XCTAssertEqual(result["s1"]?.rir, 3)
    }

    func testBlankFallbackWhenNoPrescription() {
        let exercise = makeExercise(sets: [makeUndoneSet(id: "s1")])
        let result = GhostValueResolver.resolve(exercise: exercise, lastSession: nil)
        XCTAssertEqual(result["s1"], .empty)
    }

    func testSetsWithUserValuesAreSkipped() {
        let exercise = makeExercise(sets: [makeUndoneSet(id: "s1", weight: 70, reps: 5)])
        let lastSession = LastSessionExerciseData(sets: [
            LastSessionSetData(setIndex: nil, weight: 80, reps: 8, rir: 2),
        ])
        let result = GhostValueResolver.resolve(exercise: exercise, lastSession: lastSession)
        XCTAssertEqual(result["s1"], .empty)
    }

    func testIndexMismatchFallsToTemplate() {
        let exercise = makeExercise(sets: [
            makeUndoneSet(id: "s1"),
            makeUndoneSet(id: "s2"),
            makeUndoneSet(id: "s3", targetWeight: 65, targetReps: 12),
        ])
        let lastSession = LastSessionExerciseData(sets: [
            LastSessionSetData(setIndex: nil, weight: 80, reps: 8, rir: 2),
            LastSessionSetData(setIndex: nil, weight: 82.5, reps: 7, rir: 1),
        ])
        let result = GhostValueResolver.resolve(exercise: exercise, lastSession: lastSession)
        XCTAssertEqual(result["s1"]?.weight, 80)
        XCTAssertEqual(result["s2"]?.weight, 82.5)
        XCTAssertEqual(result["s3"]?.weight, 65)
        XCTAssertEqual(result["s3"]?.reps, 12)
    }

    func testDoneSetsAreIgnored() {
        let exercise = makeExercise(sets: [makeDoneSet(id: "s1"), makeUndoneSet(id: "s2")])
        let lastSession = LastSessionExerciseData(sets: [
            LastSessionSetData(setIndex: nil, weight: 80, reps: 8, rir: 2),
            LastSessionSetData(setIndex: nil, weight: 82.5, reps: 7, rir: 1),
        ])
        let result = GhostValueResolver.resolve(exercise: exercise, lastSession: lastSession)
        XCTAssertNil(result["s1"])
        // s2 is at index 1 in the exercise sets array, so it gets lastSession.sets[1]
        XCTAssertEqual(result["s2"]?.weight, 82.5)
    }
}
