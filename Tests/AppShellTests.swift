import Testing
import UIKit

@testable import SyncBench

@MainActor
@Test func idleScreenShowsIdleStatus() {
    let controller = RunViewController()

    controller.loadViewIfNeeded()

    #expect(controller.currentStatus == "SyncBench idle")
}

@Test(arguments: [(false, true), (true, false), (false, false)])
func launchWaitsForApplicationAndSceneActivation(applicationActive: Bool, sceneActive: Bool) {
    var readiness = LaunchReadiness()
    let beforeActivation = (0..<3).map { _ in
        readiness.frameDisplayed(
            applicationIsActive: applicationActive, sceneIsActive: sceneActive
        )
    }
    #expect(beforeActivation == [false, false, false])

    let afterActivation = (0..<3).map { _ in
        readiness.frameDisplayed(applicationIsActive: true, sceneIsActive: true)
    }
    #expect(afterActivation == [false, true, false])
}

@Test func launchRestartsFrameDelayWhenActivationIsInterrupted() {
    var readiness = LaunchReadiness()
    let firstFrame = readiness.frameDisplayed(applicationIsActive: true, sceneIsActive: true)
    #expect(!firstFrame)
    readiness.activationChanged()

    let afterReactivation = (0..<2).map { _ in
        readiness.frameDisplayed(applicationIsActive: true, sceneIsActive: true)
    }
    #expect(afterReactivation == [false, true])
    readiness.activationChanged()

    let afterLaunch = (0..<2).map { _ in
        readiness.frameDisplayed(applicationIsActive: true, sceneIsActive: true)
    }
    #expect(afterLaunch == [false, false])
}
