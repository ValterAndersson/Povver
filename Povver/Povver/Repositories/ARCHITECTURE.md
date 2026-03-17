# Repositories — Module Architecture

Repositories provide type-safe Firestore data access with real-time listeners and retry logic. They abstract Firestore SDK operations for ViewModels.

## File Inventory

| File | Firestore Collection(s) | Purpose |
|------|------------------------|---------|
| `BaseRepository.swift` | — | Base protocol and generic `FirestoreRepository<T>` implementation for CRUD operations |
| `retry.swift` | — | Exponential backoff retry helper (max 3 attempts) |
| `UserRepository.swift` | `users/{uid}`, `users/{uid}/user_attributes` | User profile reads, attribute updates |
| `WorkoutRepository.swift` | `users/{uid}/workouts` | Completed workout CRUD + targeted field patches (notes) |
| `ConversationRepository.swift` | `users/{uid}/conversations/{id}/cards`, `messages`, `up_next` | Conversation card snapshot listeners, messages |
| `ExerciseRepository.swift` | `exercises` | Global exercise catalog search and fetch |

## Key Patterns

- **Snapshot listeners**: `ConversationRepository` uses Firestore snapshot listeners for real-time card updates. Changes flow to `ConversationViewModel` automatically.
- **Retry with backoff**: Some repositories use the `retry()` helper from `retry.swift` for transient error resilience.
- **Codable decoding**: Repositories decode Firestore documents into `Models/` structs using `Firestore.Decoder`.

## Cross-References

- Models decoded by repositories: `Povver/Povver/Models/`
- Consumed by ViewModels: `Povver/Povver/ViewModels/`
- Firestore schema: `docs/FIRESTORE_SCHEMA.md`
