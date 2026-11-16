//
//  ComposerTextFieldTests.swift
//  ReTiCAMsgrTests
//

#if canImport(UIKit)
import Combine
import SwiftUI
import Testing
import UIKit
@testable import ReTiCAMsgr

/// The composer's field must show what the model holds. A user reported sent text staying in the
/// field with Send disabled; adding a space then sent it a second time (2026-11-15). The field is
/// driven here the way the keyboard drives it: `insertText`, `setMarkedText`, `unmarkText`, and the
/// delegate's change report.
@MainActor
@Suite(.serialized)
struct ComposerTextFieldTests {

    /// Stands in for the store: like it, a write of the value already held notifies nobody.
    final class Model: ObservableObject {
        var draft = "" {
            willSet { if newValue != draft { objectWillChange.send() } }
        }
        var focused = false {
            willSet { if newValue != focused { objectWillChange.send() } }
        }
    }

    struct Host: View {
        @ObservedObject var model: Model

        var body: some View {
            VStack {
                Spacer()
                ComposerTextField(placeholder: "Message", text: $model.draft, isFocused: $model.focused)
                    .padding()
            }
        }
    }

    /// A composer on screen with the keyboard's attention, as while typing a message.
    @MainActor
    final class Rig {
        let model = Model()
        let window: UIWindow
        let field: UITextView

        @MainActor
        init() async throws {
            var scene: UIWindowScene?
            for _ in 0..<50 where scene == nil {
                scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
                if scene == nil { try await Task.sleep(for: .milliseconds(100)) }
            }
            window = UIWindow(windowScene: try #require(scene))
            window.rootViewController = UIHostingController(rootView: Host(model: model))
            window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(500))
            field = try #require(Self.textView(in: window))
            field.becomeFirstResponder()
            try await Task.sleep(for: .milliseconds(500))
        }

        @MainActor
        func tearDown() {
            field.resignFirstResponder()
            window.isHidden = true
            window.rootViewController = nil
        }

        private static func textView(in view: UIView) -> UITextView? {
            if let match = view as? UITextView { return match }
            for sub in view.subviews {
                if let match = textView(in: sub) { return match }
            }
            return nil
        }
    }

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(300))
    }

    /// What Send does to the draft.
    private func send(_ rig: Rig) {
        rig.model.draft = ""
    }

    /// What the reporter did next: one more key. With the field in step, the draft is that key.
    private func expectCleared(_ rig: Rig) async throws {
        try await settle()
        #expect(rig.field.text == "")
        rig.field.insertText(" ")
        try await settle()
        #expect(rig.model.draft == " ")
    }

    @Test func clearsAfterOrdinaryTyping() async throws {
        let rig = try await Rig()
        defer { rig.tearDown() }
        rig.field.insertText("hello")
        try await settle()
        #expect(rig.model.draft == "hello")

        send(rig)

        try await expectCleared(rig)
    }

    @Test func clearsWhileAWordIsStillBeingComposed() async throws {
        let rig = try await Rig()
        defer { rig.tearDown() }
        rig.field.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0))
        try await settle()
        #expect(rig.model.draft == "にほん")

        send(rig)

        try await expectCleared(rig)
    }

    @Test(arguments: [["に", "にほ", "にほん"], ["b", "be", "bet", "better"]])
    func clearsAfterTheKeyboardConfirmsAComposition(steps: [String]) async throws {
        let rig = try await Rig()
        defer { rig.tearDown() }
        rig.field.insertText("better and ")
        for step in steps {
            rig.field.setMarkedText(step, selectedRange: NSRange(location: (step as NSString).length, length: 0))
            try await Task.sleep(for: .milliseconds(100))
        }
        rig.field.unmarkText()
        try await settle()
        #expect(rig.model.draft == "better and " + steps.last!)

        send(rig)

        try await expectCleared(rig)
    }

    @Test func clearsAfterTheKeyboardReportsAChangeThatChangedNothing() async throws {
        let rig = try await Rig()
        defer { rig.tearDown() }
        rig.field.insertText("hello")
        try await settle()
        rig.field.delegate?.textViewDidChange?(rig.field)
        try await settle()
        #expect(rig.model.draft == "hello")

        send(rig)

        try await expectCleared(rig)
    }

    /// After a main-thread hitch the last key and the Send tap are handled back to back.
    @Test func clearsWhenTheLastKeyAndSendShareATurn() async throws {
        let rig = try await Rig()
        defer { rig.tearDown() }
        rig.field.insertText("hello wor")
        try await settle()

        rig.field.insertText("ld")
        #expect(rig.model.draft == "hello world")
        send(rig)

        try await expectCleared(rig)
    }

    @Test func showsADraftTheModelRestores() async throws {
        let rig = try await Rig()
        defer { rig.tearDown() }

        rig.model.draft = "restored draft"
        try await settle()
        #expect(rig.field.text == "restored draft")

        rig.field.insertText("!")
        try await settle()
        #expect(rig.model.draft == "restored draft!")
    }

    @Test func growsALineAtATimeUpToTheLimitThenScrolls() async throws {
        let rig = try await Rig()
        defer { rig.tearDown() }
        var heights: [CGFloat] = []
        for line in 1...8 {
            rig.field.insertText(line == 1 ? "line" : "\nline")
            try await settle()
            heights.append(rig.field.frame.height)
        }
        let oneLine = try #require(heights.first)
        #expect(oneLine > 10)
        for lines in 2...5 {
            #expect(abs(heights[lines - 1] - oneLine * CGFloat(lines)) <= 2, "\(lines) lines: \(heights)")
        }
        for lines in 6...8 {
            #expect(heights[lines - 1] == heights[4], "\(lines) lines: \(heights)")
        }
        #expect(rig.field.isScrollEnabled)

        send(rig)
        try await settle()

        #expect(rig.field.frame.height == oneLine)
    }

    @Test func focusFollowsTheModelAndTheModelFollowsTheField() async throws {
        let rig = try await Rig()
        defer { rig.tearDown() }
        #expect(rig.model.focused)

        rig.field.resignFirstResponder()
        try await settle()
        #expect(!rig.model.focused)

        rig.model.focused = true
        try await settle()
        #expect(rig.field.isFirstResponder)

        rig.model.focused = false
        try await settle()
        #expect(!rig.field.isFirstResponder)
    }
}
#endif
