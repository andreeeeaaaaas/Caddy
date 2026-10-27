import AppKit
import SwiftUI

/// Help › Report an issue…: a summary, what happened and who to follow up
/// with, sent to the issue relay with the app and Mac's details. If it can't
/// be sent, the report can be copied instead.
struct ReportIssueSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// Remembered, so it's filled in next time.
    @AppStorage("reportContact") private var contact = ""
    @State private var title = ""
    @State private var description = ""
    @State private var sending: Task<Void, Never>?
    @State private var issue: Int?
    @State private var failure: String?
    @State private var copied = false

    private var report: IssueReport {
        IssueReport(title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                    description: description.trimmingCharacters(in: .whitespacesAndNewlines),
                    contact: contact.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var isComplete: Bool { !report.title.isEmpty && !report.description.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Report an Issue")
                .font(.title2.bold())
            if let issue {
                confirmation(issue)
            } else {
                form
            }
        }
        .padding(22)
        .frame(width: 480)
        .onDisappear { sending?.cancel() }
    }

    @ViewBuilder
    private var form: some View {
        group("Summary") {
            TextField("Summary", text: $title, prompt: Text("e.g. Export leaves out the frames"))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
        }
        group("What happened?") {
            TextEditor(text: $description)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 3)
                .padding(.vertical, 6)
                .frame(height: 140)
                .overlay(alignment: .topLeading) {
                    if description.isEmpty {
                        Text("What you did, what you expected and what happened instead.")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .allowsHitTesting(false)
                    }
                }
                .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
        }
        group("Your name or email") {
            TextField("Your name or email", text: $contact, prompt: Text("Optional, so we can follow up"))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
        }

        Text("\(IssueReport.System.current.summary) is sent with it. Your scripts and videos aren’t.")
            .font(.caption)
            .foregroundStyle(.secondary)

        if let failure {
            Label(failure, systemImage: "xmark.octagon.fill")
                .font(.callout)
                .foregroundStyle(.secondary)
                .symbolRenderingMode(.multicolor)
        }

        HStack {
            if failure != nil {
                Button(copied ? "Copied" : "Copy Report", action: copy)
                    .disabled(!isComplete)
            }
            if sending != nil {
                ProgressView()
                    .controlSize(.small)
                Text("Sending…")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Send", action: send)
                .keyboardShortcut(.defaultAction)
                .disabled(!isComplete || sending != nil)
        }
    }

    private func confirmation(_ issue: Int) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Thanks, it’s reported.")
                        .font(.headline)
                    Text(contact.isEmpty ? "Reference #\(issue)." : "Reference #\(issue). We’ll be in touch if we need more.")
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.green)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func send() {
        failure = nil
        copied = false
        let report = report
        sending = Task {
            do {
                issue = try await report.send()
            } catch is CancellationError {
            } catch {
                failure = error.localizedDescription
            }
            sending = nil
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report.plainText, forType: .string)
        copied = true
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content()
        }
    }
}
