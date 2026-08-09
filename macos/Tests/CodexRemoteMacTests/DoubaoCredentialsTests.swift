import XCTest
@testable import CodexRemoteMac

final class DoubaoCredentialsTests: XCTestCase {
    func testValidCredentialsBuildDeterministicCookieHeaderWithoutLoggingSecrets() {
        let credentials = DoubaoASRCredentials(
            cookies: ["session": "secret-value", "alpha": "first"],
            deviceID: "device-id",
            webID: "web-id"
        )

        XCTAssertTrue(credentials.isValid)
        XCTAssertEqual(credentials.cookieHeader, "alpha=first; session=secret-value")
    }

    func testCredentialsRequireCookiesAndBothIdentifiers() {
        XCTAssertFalse(DoubaoASRCredentials(cookies: [:], deviceID: "d", webID: "w").isValid)
        XCTAssertFalse(DoubaoASRCredentials(cookies: ["a": "b"], deviceID: "", webID: "w").isValid)
        XCTAssertFalse(DoubaoASRCredentials(cookies: ["a": "b"], deviceID: "d", webID: "").isValid)
    }

    @MainActor
    func testSpeechFactoryUsesProvidedCredentialsWithoutReadingKeychain() {
        let missingFactory = DoubaoSpeechRecognitionSessionFactory()
        XCTAssertEqual(missingFactory.dependencyStatus, .speechRecognitionUnavailable)

        let credentials = DoubaoASRCredentials(
            cookies: ["session": "value"],
            deviceID: "device-id",
            webID: "web-id"
        )
        let readyFactory = DoubaoSpeechRecognitionSessionFactory(credentials: credentials)
        XCTAssertEqual(readyFactory.dependencyStatus, .ready)
    }
}
