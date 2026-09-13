import Foundation

@main
struct AntigravityNativeSmoke {
    static func main() async {
        let locator = AntigravityExecutableLocator()
        guard let executable = locator.executableURL else {
            print("AGY_NATIVE_SMOKE stage=locate result=unavailable")
            exit(2)
        }

        let session = AntigravityLocalSession()
        do {
            let deadline = Date().addingTimeInterval(AntigravityQuotaClient.timeout)
            let ports = try await session.start(
                executable: executable,
                timeout: AntigravityQuotaClient.timeout
            )
            print("AGY_NATIVE_SMOKE stage=session result=ready port_count=\(ports.count)")

            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                await session.stop()
                print("AGY_NATIVE_SMOKE stage=probe result=deadline")
                exit(3)
            }

            let reading = try await AntigravityLocalProbe.fetchQuotaReading(
                ports: ports,
                timeout: remaining,
                receivedAt: Date()
            )
            await session.stop()
            let values = [
                reading.primaryFiveHour.remainingPercent,
                reading.primarySevenDay?.remainingPercent,
                reading.secondaryFiveHour.remainingPercent,
                reading.secondarySevenDay?.remainingPercent,
            ].map { $0.map(String.init) ?? "unknown" }.joined(separator: ",")
            print("AGY_NATIVE_SMOKE stage=probe result=ok source=\(reading.source) windows=\(values)")
        } catch let error as AntigravityQuotaClientError {
            await session.stop()
            print("AGY_NATIVE_SMOKE stage=probe result=\(String(describing: error))")
            exit(4)
        } catch {
            await session.stop()
            print("AGY_NATIVE_SMOKE stage=probe result=unexpected")
            exit(5)
        }
    }
}
