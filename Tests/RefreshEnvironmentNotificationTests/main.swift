import Combine
import Foundation

@MainActor
private final class RefreshEnvironmentNotificationProbe {
    private var cancellable: AnyCancellable?
    private(set) var deliveryCount = 0
    private(set) var deliveredOnMainThread = false

    func start(center: NotificationCenter) {
        cancellable = RefreshEnvironmentNotifications.publisher(center: center)
            .sink { [weak self] _ in
                let isMainThread = Thread.isMainThread
                Task { @MainActor [weak self] in
                    self?.recordDelivery(isMainThread: isMainThread)
                }
            }
    }

    private func recordDelivery(isMainThread: Bool) {
        deliveryCount += 1
        deliveredOnMainThread = isMainThread
    }
}

private final class NotificationCenterBox: @unchecked Sendable {
    let center = NotificationCenter()
}

@main
private enum RefreshEnvironmentNotificationTests {
    @MainActor
    static func main() async {
        let centerBox = NotificationCenterBox()
        let probe = RefreshEnvironmentNotificationProbe()
        probe.start(center: centerBox.center)

        DispatchQueue.global(qos: .userInitiated).async {
            centerBox.center.post(
                name: ProcessInfo.thermalStateDidChangeNotification,
                object: nil
            )
        }

        for _ in 0..<100 where probe.deliveryCount == 0 {
            try? await Task.sleep(for: .milliseconds(10))
        }

        guard probe.deliveryCount == 1 else {
            FileHandle.standardError.write(
                Data("FAILED: background thermal notification was not delivered exactly once\n".utf8)
            )
            exit(1)
        }
        guard probe.deliveredOnMainThread else {
            FileHandle.standardError.write(
                Data("FAILED: refresh-environment notification reached its sink off the main thread\n".utf8)
            )
            exit(1)
        }

        print("Refresh environment notification regression tests passed")
    }
}
