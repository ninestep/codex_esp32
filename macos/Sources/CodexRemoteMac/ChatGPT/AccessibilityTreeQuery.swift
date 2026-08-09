import ApplicationServices
import Foundation

public enum AccessibilityTreeQueryError: Error, Equatable, Sendable {
    case permissionDenied
    case focusedElementUnavailable
    case unsupportedFocusedRole(String?)
    case unconfirmedComposerIdentity([String])
    case composerNotEditable
    case insertionFailed(AXError)
}

@MainActor
public protocol ChatGPTComposerAccessing: AnyObject {
    func insertAtFocusedComposer(text: String, processIdentifier: pid_t) throws
}

@MainActor
public final class AccessibilityTreeQuery: ChatGPTComposerAccessing {
    public static let confirmedComposerDOMClasses: Set<String> = ["ProseMirror"]

    private let confirmedComposerDOMClasses: Set<String>

    public init(confirmedComposerDOMClasses: Set<String> = AccessibilityTreeQuery.confirmedComposerDOMClasses) {
        self.confirmedComposerDOMClasses = confirmedComposerDOMClasses
    }

    public func insertAtFocusedComposer(text: String, processIdentifier: pid_t) throws {
        guard AXIsProcessTrusted() else { throw AccessibilityTreeQueryError.permissionDenied }

        let application = AXUIElementCreateApplication(processIdentifier)
        var focusedValue: CFTypeRef?
        let focusedResult = AXUIElementCopyAttributeValue(
            application,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        )
        guard focusedResult == .success,
              let focusedValue,
              CFGetTypeID(focusedValue) == AXUIElementGetTypeID()
        else { throw AccessibilityTreeQueryError.focusedElementUnavailable }

        let element = unsafeDowncast(focusedValue, to: AXUIElement.self)
        let role = stringAttribute(kAXRoleAttribute, of: element)
        guard role == kAXTextAreaRole as String else {
            throw AccessibilityTreeQueryError.unsupportedFocusedRole(role)
        }
        let domClasses = stringArrayAttribute("AXDOMClassList", of: element)
        guard !confirmedComposerDOMClasses.isDisjoint(with: domClasses) else {
            throw AccessibilityTreeQueryError.unconfirmedComposerIdentity(domClasses.sorted())
        }
        guard booleanAttribute(kAXEnabledAttribute, of: element) != false,
              isSettable(kAXSelectedTextAttribute, on: element)
        else { throw AccessibilityTreeQueryError.composerNotEditable }

        let result = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        )
        guard result == .success else { throw AccessibilityTreeQueryError.insertionFailed(result) }
    }

    private func stringAttribute(_ attribute: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func booleanAttribute(_ attribute: String, of element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? Bool
    }

    private func stringArrayAttribute(_ attribute: String, of element: AXUIElement) -> Set<String> {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let strings = value as? [String]
        else { return [] }
        return Set(strings)
    }

    private func isSettable(_ attribute: String, on element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(
            element,
            attribute as CFString,
            &settable
        ) == .success && settable.boolValue
    }
}
