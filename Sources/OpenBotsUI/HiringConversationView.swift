import SwiftUI

/// The primary teammate-hiring surface. Conversation remains the dominant
/// interaction; the structured candidate card is a review and correction aid.
public struct HiringConversationView: View {
    private enum FocusDestination: Hashable {
        case composer
    }

    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var model: HiringConversationModel
    @FocusState private var focus: FocusDestination?
    @State private var isReviewPresented = true
    private enum Layout {
        static let minimumMainWidth: CGFloat = 340
        static let candidateReviewWidth: CGFloat = 340
    }

    private let onHired: @MainActor () -> Void
    private let onCancelled: @MainActor () -> Void

    public init(
        model: HiringConversationModel,
        onHired: @escaping @MainActor () -> Void = {},
        onCancelled: @escaping @MainActor () -> Void = {}
    ) {
        self.model = model
        self.onHired = onHired
        self.onCancelled = onCancelled
    }

    public var body: some View {
        HStack(spacing: 0) {
            conversationPane
            if isReviewPresented {
                Divider()
                reviewPane
                    .frame(width: Layout.candidateReviewWidth)
            }
        }
        // Participate in the detail's width proposal. An inspector attached
        // inside NavigationSplitView's detail could extend beyond its window.
        .preference(
            key: WorkspaceDetailMinimumWidthKey.self,
            value: Layout.minimumMainWidth + (isReviewPresented ? Layout.candidateReviewWidth + 1 : 0)
        )
        .tint(OpenBotsVisualStyle.brandAccent(for: colorScheme))
        .navigationTitle(model.conversationTitle)
        .toolbar {
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    isReviewPresented.toggle()
                } label: {
                    Label("Candidate Review", systemImage: "person.text.rectangle")
                }
                .help(isReviewPresented ? "Hide candidate review" : "Show candidate review")
                .accessibilityHint(
                    isReviewPresented
                        ? "Hide the candidate details while keeping the hiring conversation open."
                        : "Show the candidate details beside the hiring conversation."
                )
            }
        }
        .task {
            await model.load()
            focusComposerWhenReady()
        }
        .onChange(of: model.canSend) {
            focusComposerWhenReady()
        }
    }

    private var conversationPane: some View {
        VStack(spacing: 0) {
            header
            disclosure
            Divider()
            transcript
            Divider()
            composer
            Divider()
            actionBar
        }
        .frame(minWidth: Layout.minimumMainWidth, maxWidth: .infinity, minHeight: 460)
        .background(OpenBotsVisualStyle.canvas(for: colorScheme))
    }

    private var header: some View {
        HStack(spacing: OpenBotsVisualStyle.spacing16) {
            CharacterIdentityView(
                identity: model.previewIdentity,
                activity: model.mode == .reviewFixture && model.isSubmitting ? .thinkingOrWorking : .waitingForUser,
                size: 52
            )

            VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing4) {
                Text(model.conversationTitle)
                    .font(.title2.weight(.semibold))
                    .fontDesign(.rounded)
                Text("Talk through who you need. The candidate review updates beside this chat.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: OpenBotsVisualStyle.spacing16)

            Label(model.readinessTitle, systemImage: model.readinessSymbolName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityLabel("Candidate status. \(model.readinessTitle)")
        }
        .padding(.horizontal, OpenBotsVisualStyle.spacing24)
        .padding(.vertical, OpenBotsVisualStyle.spacing16)
        .background(OpenBotsVisualStyle.surface(for: colorScheme))
        .accessibilityElement(children: .combine)
    }

    private var disclosure: some View {
        Label(
            model.setupDisclosure,
            systemImage: "macwindow"
        )
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, OpenBotsVisualStyle.spacing24)
        .padding(.vertical, OpenBotsVisualStyle.spacing8)
        .background(OpenBotsVisualStyle.brandWash(for: colorScheme).opacity(0.62))
        .accessibilityLabel(model.setupDisclosure)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing16) {
                    ForEach(model.displayRows) { row in
                        hiringTurn(row)
                            .id(row.id)
                    }
                }
                .frame(maxWidth: 680, alignment: .leading)
                .padding(OpenBotsVisualStyle.spacing24)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: model.displayRows.count) {
                guard let last = model.displayRows.last else { return }
                proxy.scrollTo(last.id, anchor: .bottom)
            }
            .overlay {
                if model.displayRows.isEmpty, !model.isLoading {
                    ContentUnavailableView {
                        Label("Start with who you need", systemImage: "person.crop.circle.badge.questionmark")
                            .fontDesign(.rounded)
                    } description: {
                        Text("Describe a role in your own words. OpenBots will focus the next question and build a reviewable candidate.")
                    }
                    .padding(OpenBotsVisualStyle.spacing24)
                }
            }
        }
        .accessibilityLabel("Hiring conversation transcript")
    }

    @ViewBuilder
    private func hiringTurn(_ row: HiringConversationRow) -> some View {
        switch row.author {
        case .guide:
            HStack(alignment: .top, spacing: OpenBotsVisualStyle.spacing12) {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .font(.title2)
                    .foregroundStyle(OpenBotsVisualStyle.brandAccent(for: colorScheme))
                    .frame(width: 36, height: 36)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing4) {
                    Text("OpenBots hiring guide")
                        .font(.caption.weight(.semibold))
                    hiringTurnContent(row, background: OpenBotsVisualStyle.surface(for: colorScheme))
                }
                Spacer(minLength: 48)
            }

        case .user:
            HStack(alignment: .top) {
                Spacer(minLength: 48)
                VStack(alignment: .trailing, spacing: OpenBotsVisualStyle.spacing4) {
                    Text("You")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    hiringTurnContent(
                        row,
                        background: OpenBotsVisualStyle.brandWash(for: colorScheme)
                    )
                }
            }
        }
    }

    private func hiringTurnContent(
        _ row: HiringConversationRow,
        background: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing8) {
            StableSelectableText(row.text)

            switch row.delivery {
            case .saved:
                EmptyView()
            case .pending:
                Label("Adding to the local draft", systemImage: "clock")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            case .failed(let reason):
                Label(reason, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, OpenBotsVisualStyle.spacing12)
        .padding(.vertical, OpenBotsVisualStyle.spacing8)
        .frame(maxWidth: 560, alignment: .leading)
        .background(
            background,
            in: RoundedRectangle(
                cornerRadius: OpenBotsVisualStyle.radiusMedium,
                style: .continuous
            )
        )
        .overlay {
            RoundedRectangle(
                cornerRadius: OpenBotsVisualStyle.radiusMedium,
                style: .continuous
            )
            .stroke(.separator, lineWidth: 0.75)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityDescription)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing8) {
            Label(model.focusedPrompt, systemImage: "scope")
                .font(.callout.weight(.semibold))
                .accessibilityLabel("Current hiring question. \(model.focusedPrompt)")

            HStack(alignment: .bottom, spacing: OpenBotsVisualStyle.spacing8) {
                TextField(
                    "Describe this teammate in your own words",
                    text: $model.composerText,
                    axis: .vertical
                )
                .lineLimit(1...6)
                .fixedSize(horizontal: false, vertical: true)
                .textFieldStyle(.plain)
                .focused($focus, equals: .composer)
                .disabled(!model.acceptsConversationInput)
                .padding(.horizontal, OpenBotsVisualStyle.spacing12)
                .padding(.vertical, OpenBotsVisualStyle.spacing8)
                .accessibilityLabel("Hiring message")
                .accessibilityHint(model.composerAccessibilityHint)
                .onSubmit {
                    guard model.canSend else { return }
                    model.submitCurrentText()
                }

                Button {
                    model.submitCurrentText()
                } label: {
                    Label("Add answer", systemImage: "arrow.up")
                        .labelStyle(.iconOnly)
                        .font(.headline)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(!model.canSend)
                .accessibilityLabel("Add hiring answer")
                .accessibilityHint("Add this answer to the local guided candidate draft.")
            }
            .padding(OpenBotsVisualStyle.spacing4)
            .background(
                OpenBotsVisualStyle.surface(for: colorScheme),
                in: RoundedRectangle(
                    cornerRadius: OpenBotsVisualStyle.radiusLarge,
                    style: .continuous
                )
            )
            .overlay {
                RoundedRectangle(
                    cornerRadius: OpenBotsVisualStyle.radiusLarge,
                    style: .continuous
                )
                .stroke(.separator, lineWidth: 0.75)
            }

            if let error = model.inlineError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityLabel("Hiring error. \(error)")
            } else {
                Text(model.composerSupportText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, OpenBotsVisualStyle.spacing24)
        .padding(.vertical, OpenBotsVisualStyle.spacing12)
        .background(OpenBotsVisualStyle.surface(for: colorScheme))
    }

    private var reviewPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing16) {
                HStack {
                    Label("Candidate review", systemImage: "person.text.rectangle")
                        .font(.headline)
                    Spacer()
                    Button {
                        isReviewPresented = false
                    } label: {
                        Label("Close Candidate Review", systemImage: "xmark")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.plain)
                    .help("Close candidate review")
                }

                candidateIdentity
                readiness

                if let update = model.lastReviewUpdate {
                    candidateReviewUpdate(update)
                }

                Divider()

                VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing12) {
                    ForEach(model.reviewItems) { item in
                        reviewItem(item)
                    }
                }

                DisclosureGroup("Edit details") {
                    VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing12) {
                        Text("Conversation is the primary hiring flow. Use these fields only to correct or refine the review.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        ForEach(model.reviewItems) { item in
                            HiringCandidateFieldEditor(item: item) { text in
                                await model.revise(item.field, text: text)
                            }
                        }
                    }
                    .padding(.top, OpenBotsVisualStyle.spacing8)
                }
                .font(.callout.weight(.semibold))
            }
            .padding(OpenBotsVisualStyle.spacing24)
        }
        .background(OpenBotsVisualStyle.surface(for: colorScheme))
        .accessibilityLabel("Candidate review")
    }

    private func candidateReviewUpdate(_ update: HiringCandidateReviewUpdate) -> some View {
        VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing4) {
            Label("Candidate review updated", systemImage: "checkmark.circle.fill")
                .font(.callout.weight(.semibold))
            Text("\(update.fieldTitle): \(update.displayValue)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .padding(OpenBotsVisualStyle.spacing12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            OpenBotsVisualStyle.brandWash(for: colorScheme).opacity(0.55),
            in: RoundedRectangle(
                cornerRadius: OpenBotsVisualStyle.radiusMedium,
                style: .continuous
            )
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(update.accessibilityDescription)
    }

    private var candidateIdentity: some View {
        HStack(spacing: OpenBotsVisualStyle.spacing16) {
            CharacterIdentityView(
                identity: model.previewIdentity,
                activity: .idle,
                size: 68
            )
            VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing4) {
                Text("Candidate")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(model.previewIdentity.name)
                    .font(.title3.weight(.semibold))
                    .fontDesign(.rounded)
                Text(model.previewIdentity.role)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Candidate preview. \(model.previewIdentity.name), \(model.previewIdentity.role)"
        )
    }

    private var readiness: some View {
        VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing4) {
            Label(model.readinessTitle, systemImage: model.readinessSymbolName)
                .font(.callout.weight(.semibold))
            Text(model.readinessDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(OpenBotsVisualStyle.spacing12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            OpenBotsVisualStyle.brandWash(for: colorScheme).opacity(0.55),
            in: RoundedRectangle(
                cornerRadius: OpenBotsVisualStyle.radiusMedium,
                style: .continuous
            )
        )
        .accessibilityElement(children: .combine)
    }

    private func reviewItem(_ item: HiringCandidateReviewItem) -> some View {
        VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing4) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: OpenBotsVisualStyle.spacing8)
                Image(systemName: item.isComplete ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(item.isComplete ? .green : .secondary)
                    .accessibilityHidden(true)
            }
            StableSelectableText(
                item.displayValue,
                style: .callout,
                tone: item.isComplete ? .primary : .secondary
            )
            if item.field == .permissionIntent {
                Text("Proposed needs only — no permission is granted by hiring.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.accessibilityDescription)
    }

    private var actionBar: some View {
        HStack(spacing: OpenBotsVisualStyle.spacing12) {
            Label("Cancel creates no teammate", systemImage: "xmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Button("Cancel hiring") {
                Task {
                    if await model.cancel() {
                        onCancelled()
                    }
                }
            }
            .disabled(model.isPerformingConsequentialAction)
            .accessibilityHint("Discard the local hiring draft. No teammate is created.")

            Button {
                Task {
                    if await model.confirmHire() {
                        onHired()
                    }
                }
            } label: {
                if model.isConfirming {
                    Label("Hiring…", systemImage: "person.badge.plus")
                } else {
                    Text("Hire Teammate")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canHire)
            .accessibilityHint(model.hireAccessibilityHint)
        }
        .padding(.horizontal, OpenBotsVisualStyle.spacing24)
        .padding(.vertical, OpenBotsVisualStyle.spacing12)
        .background(OpenBotsVisualStyle.surface(for: colorScheme))
    }

    private func focusComposerWhenReady() {
        if model.canSend {
            focus = .composer
        }
    }
}

private struct HiringCandidateFieldEditor: View {
    let item: HiringCandidateReviewItem
    let save: @MainActor (String) async -> Bool

    @State private var draft: String
    @State private var isSaving = false

    init(
        item: HiringCandidateReviewItem,
        save: @escaping @MainActor (String) async -> Bool
    ) {
        self.item = item
        self.save = save
        _draft = State(initialValue: item.rawValue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing4) {
            Text(item.title)
                .font(.caption.weight(.semibold))
            HStack(alignment: .bottom, spacing: OpenBotsVisualStyle.spacing8) {
                TextField(item.editorPrompt, text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Edit \(item.title)")

                Button("Save") {
                    isSaving = true
                    Task {
                        _ = await save(draft)
                        isSaving = false
                    }
                }
                .disabled(isSaving || draft == item.rawValue)
            }
        }
        // A returned service snapshot replaces this editor with the newly
        // canonical value; stale local text never becomes a second authority.
        .id("\(item.id)-\(item.rawValue)")
    }
}
