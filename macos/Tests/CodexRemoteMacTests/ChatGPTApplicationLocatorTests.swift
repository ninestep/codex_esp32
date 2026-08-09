import XCTest
@testable import CodexRemoteMac

@MainActor
final class ChatGPTApplicationLocatorTests: XCTestCase {
    func testLocatesSingleSupportedApplication() throws {
        let expected = ChatGPTApplication(processIdentifier: 42, bundleIdentifier: "com.openai.codex")
        let locator = ChatGPTApplicationLocator(
            applicationProvider: StubRunningApplicationProvider(applications: [
                ChatGPTApplication(processIdentifier: 1, bundleIdentifier: "com.apple.TextEdit"),
                expected,
            ])
        )

        XCTAssertEqual(try locator.locate(), expected)
    }

    func testRejectsMissingApplication() {
        let locator = ChatGPTApplicationLocator(
            applicationProvider: StubRunningApplicationProvider(applications: [])
        )

        XCTAssertThrowsError(try locator.locate()) { error in
            XCTAssertEqual(error as? ChatGPTApplicationLocatorError, .notRunning)
        }
    }

    func testRejectsMultipleSupportedInstances() {
        let locator = ChatGPTApplicationLocator(
            applicationProvider: StubRunningApplicationProvider(applications: [
                ChatGPTApplication(processIdentifier: 1, bundleIdentifier: "com.openai.codex"),
                ChatGPTApplication(processIdentifier: 2, bundleIdentifier: "com.openai.codex"),
            ])
        )

        XCTAssertThrowsError(try locator.locate()) { error in
            XCTAssertEqual(error as? ChatGPTApplicationLocatorError, .multipleInstances)
        }
    }

    func testRejectsCaseVariantAsUnconfirmedIdentity() {
        let locator = ChatGPTApplicationLocator(
            applicationProvider: StubRunningApplicationProvider(applications: [
                ChatGPTApplication(processIdentifier: 1, bundleIdentifier: "COM.OPENAI.CODEX"),
            ])
        )

        XCTAssertThrowsError(try locator.locate()) { error in
            XCTAssertEqual(
                error as? ChatGPTApplicationLocatorError,
                .unsupportedIdentity("COM.OPENAI.CODEX")
            )
        }
    }
}

@MainActor
private final class StubRunningApplicationProvider: RunningApplicationProviding {
    let applications: [ChatGPTApplication]

    init(applications: [ChatGPTApplication]) {
        self.applications = applications
    }

    func runningApplications() -> [ChatGPTApplication] { applications }
}
