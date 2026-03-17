# Models — Module Architecture

Codable structs that mirror Firestore document schemas. All models use `decodeIfPresent` with sensible defaults for resilience against schema changes.

## File Inventory

| File | Firestore Collection | Purpose |
|------|---------------------|---------|
| `User.swift` | `users/{uid}` | User profile (`id`, `email`, `displayName`) |
| `UserAttributes.swift` | `users/{uid}/user_attributes/{uid}` | Preferences (`weightFormat`, `heightFormat`, `timezone`) |
| `Workout.swift` | `users/{uid}/workouts/{id}` | Completed workout with exercises and analytics. Also contains `UpsertWorkoutRequest`, `UpsertExercise`, `UpsertSet` encodable structs for the `upsertWorkout` endpoint |
| `WorkoutTemplate.swift` | `users/{uid}/templates/{id}` | Reusable workout plan with exercises and sets |
| `Routine.swift` | `users/{uid}/routines/{id}` | Routine model for `getRoutine` API response — weekly program with ordered `template_ids`, frequency, cursor tracking |
| `Exercise.swift` | `exercises/{id}` | Global exercise catalog entry (`name`, `primaryMuscles`, `equipment`) |
| `MuscleGroup.swift` | — | Muscle group enumeration used by `Exercise` |
| `ActiveWorkout.swift` | — | In-memory active workout state (exercises, sets, duration) |
| `ActiveWorkoutDoc.swift` | `users/{uid}/active_workouts/{id}` | Firestore-synced active workout document |
| `FocusModeModels.swift` | `users/{uid}/active_workouts/{id}` | `FocusModeWorkout` and related types for Focus Mode UI |
| `StreamEvent.swift` | — | SSE event model (9-event contract: `message`, `tool_start`, `tool_end`, `artifact`, `clarification`, `status`, `heartbeat`, `done`, `error`) |
| `ChatMessage.swift` | — | Chat UI message with author, content, timestamp |
| `WorkspaceEvent.swift` | `users/{uid}/conversations/{id}/messages/{id}` | Conversation event from agent |

## Codable Patterns

All models follow the same pattern for Firestore resilience:

```swift
struct MyModel: Codable {
    @DocumentID var id: String?
    var name: String
    var optional_field: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        optional_field = try container.decodeIfPresent(String.self, forKey: .optional_field)
    }
}
```

- `@DocumentID` for Firestore document IDs
- `decodeIfPresent` + default for every field
- Snake case field names matching Firestore conventions

## Cross-References

- Models are decoded by Repositories (`Povver/Povver/Repositories/`)
- Schema contracts documented in `docs/FIRESTORE_SCHEMA.md`
- Conversation-specific models live in `UI/Canvas/Models.swift` (not in this directory)
