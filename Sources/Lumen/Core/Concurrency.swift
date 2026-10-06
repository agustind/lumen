import Foundation

/// Runs `operation` for every item concurrently and hands each result to `onResult` on the
/// main actor as soon as it's ready; returns when all have finished.
///
/// Used instead of main-actor `withTaskGroup`, which crashed in optimized builds
/// (`__cxa_pure_virtual` in `AsyncTask::completeFuture`) when fanning out addon requests.
@MainActor
func forEachConcurrently<Item, Result>(
    _ items: [Item],
    operation: @escaping @Sendable (Item) async -> Result,
    onResult: @escaping @MainActor (Item, Result) -> Void
) async {
    let tasks = items.map { item in
        Task { @MainActor in
            let result = await operation(item)
            guard !Task.isCancelled else { return }
            onResult(item, result)
        }
    }
    await withTaskCancellationHandler {
        for task in tasks { await task.value }
    } onCancel: {
        tasks.forEach { $0.cancel() }
    }
}
