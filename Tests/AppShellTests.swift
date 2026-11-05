import Testing
import UIKit

@testable import SyncBench

@MainActor
@Test func idleScreenShowsIdleStatus() {
    let controller = RunViewController()

    controller.loadViewIfNeeded()

    #expect(controller.currentStatus == "SyncBench idle")
}
