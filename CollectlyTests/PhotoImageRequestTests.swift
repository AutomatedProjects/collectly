import Foundation
import Photos
import Testing
import UIKit
@testable import Collectly

/// Records the request IDs `PhotoImageRequest` asks PhotoKit to cancel.
private final class CancelLog: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [PHImageRequestID] = []

    var cancelled: [PHImageRequestID] { lock.withLock { ids } }

    func record(_ id: PHImageRequestID) {
        lock.withLock { ids.append(id) }
    }
}

struct PhotoImageRequestTests {
    @Test func finishDeliversTheImage() async throws {
        let log = CancelLog()
        let request = PhotoImageRequest(cancelRequest: log.record)
        let image = try #require(UIImage(systemName: "photo"))
        let result = await withCheckedContinuation { continuation in
            request.start(continuation) { 7 }
            request.finish(image)
        }
        #expect(result === image)
        #expect(log.cancelled.isEmpty)
    }

    @Test func cancelAfterStartCancelsThePhotoKitRequest() async {
        let log = CancelLog()
        let request = PhotoImageRequest(cancelRequest: log.record)
        let result = await withCheckedContinuation { continuation in
            request.start(continuation) { 7 }
            request.cancel()
            request.finish(UIImage()) // a late PhotoKit callback must not resume twice
        }
        #expect(result == nil)
        #expect(log.cancelled == [7])
    }

    @Test func cancelWhileStartingStillCancelsTheRequest() async {
        let log = CancelLog()
        let request = PhotoImageRequest(cancelRequest: log.record)
        let result = await withCheckedContinuation { continuation in
            request.start(continuation) {
                request.cancel() // races with the request ID being stored
                return 9
            }
        }
        #expect(result == nil)
        #expect(log.cancelled == [9])
    }

    @Test func cancelBeforeStartNeverStartsTheRequest() async {
        let log = CancelLog()
        let request = PhotoImageRequest(cancelRequest: log.record)
        request.cancel()
        var started = false
        let result = await withCheckedContinuation { continuation in
            request.start(continuation) {
                started = true
                return 1
            }
        }
        #expect(result == nil)
        #expect(!started)
        #expect(request.isCancelled)
        #expect(log.cancelled.isEmpty)
    }
}
