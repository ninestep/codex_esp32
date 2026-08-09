import Foundation

public enum ChatGPTComposerTextEmitterError: Error, Equatable, Sendable {
    case emptyText
    case application(ChatGPTApplicationLocatorError)
    case accessibility(AccessibilityTreeQueryError)
}

@MainActor
public final class ChatGPTComposerTextEmitter: RecognizedTextEmitting {
    private let applicationLocator: ChatGPTApplicationLocator
    private let accessibilityQuery: any ChatGPTComposerAccessing

    public init(
        applicationLocator: ChatGPTApplicationLocator = ChatGPTApplicationLocator(),
        accessibilityQuery: any ChatGPTComposerAccessing = AccessibilityTreeQuery()
    ) {
        self.applicationLocator = applicationLocator
        self.accessibilityQuery = accessibilityQuery
    }

    public func emit(text: String) throws {
        guard !text.isEmpty else { throw ChatGPTComposerTextEmitterError.emptyText }
        let application: ChatGPTApplication
        do {
            application = try applicationLocator.locate()
        } catch let error as ChatGPTApplicationLocatorError {
            throw ChatGPTComposerTextEmitterError.application(error)
        }
        do {
            try accessibilityQuery.insertAtFocusedComposer(
                text: text,
                processIdentifier: application.processIdentifier
            )
        } catch let error as AccessibilityTreeQueryError {
            throw ChatGPTComposerTextEmitterError.accessibility(error)
        }
    }
}
