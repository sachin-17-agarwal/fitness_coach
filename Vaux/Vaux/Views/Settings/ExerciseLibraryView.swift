// ExerciseLibraryView.swift
// Vaux
//
// Browse and extend the `exercises` table. Until now the only way to add
// a new exercise was the chat command `add exercise <name>`; this view
// makes it discoverable. Edits are deliberately out of scope — historical
// `workout_sets` rows reference exercises by name, so renaming would
// silently break tonnage history.

import SwiftUI

@Observable
final class ExerciseLibraryViewModel {
    var exercises: [Exercise] = []
    var isLoading = false
    var errorMessage: String?
    var searchText = ""

    private let client: SupabaseClient

    init(client: SupabaseClient = .shared) {
        self.client = client
    }

    var filtered: [Exercise] {
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else {
            return exercises
        }
        let needle = searchText.lowercased()
        return exercises.filter { ex in
            if ex.name.lowercased().contains(needle) { return true }
            if let group = ex.muscleGroup?.lowercased(), group.contains(needle) { return true }
            if let aliases = ex.aliases,
               aliases.contains(where: { $0.lowercased().contains(needle) }) {
                return true
            }
            return false
        }
    }

    var grouped: [(muscleGroup: String, exercises: [Exercise])] {
        let buckets = Dictionary(grouping: filtered) { ex in
            (ex.muscleGroup?.isEmpty == false ? ex.muscleGroup! : "Other")
        }
        return buckets
            .map { (muscleGroup: $0.key, exercises: $0.value.sorted { $0.name < $1.name }) }
            .sorted { $0.muscleGroup < $1.muscleGroup }
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        do {
            let rows: [Exercise] = try await client.fetch("exercises", order: "name.asc")
            exercises = rows
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    /// Insert a new exercise and reload. The Supabase row is keyed by `id`
    /// not `name`, so duplicates by name are possible — guard against
    /// that client-side before posting.
    func add(name: String, muscleGroup: String) async -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedGroup = muscleGroup.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            errorMessage = "Name is required"
            return false
        }
        if exercises.contains(where: { $0.name.caseInsensitiveCompare(trimmedName) == .orderedSame }) {
            errorMessage = "\(trimmedName) is already in the library"
            return false
        }

        do {
            let body: [String: Any] = [
                "name": trimmedName,
                "muscle_group": trimmedGroup.isEmpty ? "Unknown" : trimmedGroup,
                "aliases": [],
            ]
            _ = try await client.insert("exercises", body: body)
            await load()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Record another spelling of a lift ("Machine Chest Fly" for "Cable
    /// Chest Fly") so every reader — the strength page, the reviews, the
    /// programme's history — treats the two as one. Twelve lifts in the log
    /// had two or three spellings on 25 Sep 2026; the case-only ones were
    /// merged by a data fix, the real variants are recorded here.
    func addAlias(to exercise: Exercise, alias: String) async -> Bool {
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let id = exercise.id else {
            errorMessage = "Alias is required"
            return false
        }
        if trimmed.caseInsensitiveCompare(exercise.name) == .orderedSame {
            errorMessage = "That is the exercise's own name"
            return false
        }
        if exercises.contains(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            errorMessage = "\(trimmed) is a separate exercise in the library — remove it first if the two are one lift"
            return false
        }
        var aliases = exercise.aliases ?? []
        if aliases.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) { return true }
        aliases.append(trimmed)
        do {
            _ = try await client.update("exercises", body: ["aliases": aliases], match: ["id": id.uuidString])
            await load()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}

struct ExerciseLibraryView: View {
    @State private var viewModel = ExerciseLibraryViewModel()
    @State private var showingAddSheet = false
    /// The exercise an alias is being added to, when the sheet is up.
    @State private var aliasTarget: Exercise?

    var body: some View {
        ZStack {
            TechBackground(accent: .signal)

            VStack(spacing: 0) {
                searchBar
                content
            }
        }
        .navigationTitle("Exercises")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Haptic.medium()
                    showingAddSheet = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(Color.signal)
                }
            }
        }
        .task { await viewModel.load() }
        .sheet(isPresented: $showingAddSheet) {
            AddExerciseSheet(onAdd: { name, group in
                let ok = await viewModel.add(name: name, muscleGroup: group)
                if ok { Haptic.success() } else { Haptic.error() }
                return ok
            })
        }
        .sheet(item: $aliasTarget) { exercise in
            AddAliasSheet(exercise: exercise, onAdd: { alias in
                let ok = await viewModel.addAlias(to: exercise, alias: alias)
                if ok { Haptic.success() } else { Haptic.error() }
                return ok
            })
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.textTertiary)
            TextField("Search…", text: $viewModel.searchText)
                .textFieldStyle(.plain)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(size: 14))
                .foregroundStyle(.white)
            if !viewModel.searchText.isEmpty {
                Button {
                    viewModel.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.textTertiary)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.cardBorder, lineWidth: 0.5)
        )
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading && viewModel.exercises.isEmpty {
            VStack {
                Spacer()
                ProgressView().tint(.white)
                Spacer()
            }
        } else if let error = viewModel.errorMessage, viewModel.exercises.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(Color.recoveryRed)
                Text(error)
                    .multilineTextAlignment(.center)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.textSecondary)
                    .padding(.horizontal, 32)
                Spacer()
            }
        } else {
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 14, pinnedViews: [.sectionHeaders]) {
                    ForEach(viewModel.grouped, id: \.muscleGroup) { section in
                        Section(header: sectionHeader(section.muscleGroup, count: section.exercises.count)) {
                            VStack(spacing: 6) {
                                ForEach(section.exercises) { ex in
                                    exerciseRow(ex)
                                }
                            }
                        }
                    }
                    Spacer(minLength: 24)
                }
                .padding(.horizontal, 16)
            }
            .vauxRefreshable { await viewModel.load() }
        }
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack {
            Eyebrow(text: title, color: .signal)
            Text("\(count)")
                .font(.eyebrowSmall)
                .foregroundStyle(Color.fg2)
            Spacer()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .background(Color.ink0)
    }

    private func exerciseRow(_ ex: Exercise) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(ex.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.fg0)
                if let aliases = ex.aliases, !aliases.isEmpty {
                    Text(aliases.joined(separator: " • "))
                        .font(.system(size: 11))
                        .foregroundStyle(Color.fg2)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Button {
                Haptic.light()
                aliasTarget = ex
            } label: {
                Image(systemName: "text.badge.plus")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.fg2)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add another spelling of \(ex.name)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.cardBorder, lineWidth: 0.5)
        )
    }
}

// MARK: - Alias sheet

struct AddAliasSheet: View {
    @Environment(\.dismiss) private var dismiss
    let exercise: Exercise
    /// Returns true when the alias was stored, so the sheet closes itself.
    let onAdd: (String) async -> Bool

    @State private var alias = ""
    @State private var isSaving = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                TechBackground(accent: .signal)
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Eyebrow(text: "Another spelling of \(exercise.name)")
                        TextField("e.g. Machine Chest Fly", text: $alias)
                            .textFieldStyle(.plain)
                            .font(.system(size: 16))
                            .foregroundStyle(.white)
                            .focused($focused)
                            .submitLabel(.done)
                            .onSubmit { Task { await save() } }
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.ink2))
                    }
                    Text("Sets already logged under this spelling count as \(exercise.name) everywhere — the strength page, the reviews, the programme's history.")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.fg2)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        Task { await save() }
                    } label: {
                        Text(isSaving ? "Saving…" : "Save alias")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.signalInk)
                            .frame(maxWidth: .infinity)
                            .frame(height: 46)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.signal))
                    }
                    .buttonStyle(PressScaleStyle(scale: 0.97))
                    .disabled(isSaving || alias.trimmingCharacters(in: .whitespaces).isEmpty)
                    Spacer()
                }
                .padding(18)
            }
            .navigationTitle("Add alias")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Color.textSecondary)
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium])
    }

    private func save() async {
        guard !isSaving else { return }
        isSaving = true
        let ok = await onAdd(alias)
        isSaving = false
        if ok { dismiss() }
    }
}

// MARK: - Add sheet

struct AddExerciseSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// Called when the user taps Save. Returns true if the insert
    /// succeeded so the sheet can close itself.
    let onAdd: (String, String) async -> Bool

    @State private var name = ""
    @State private var muscleGroup = ""
    @State private var isSaving = false
    @FocusState private var nameFocused: Bool

    private let muscleGroupOptions = [
        "Chest", "Back", "Shoulders", "Biceps", "Triceps",
        "Quads", "Hamstrings", "Glutes", "Calves",
        "Core", "Cardio", "Full Body",
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                TechBackground(accent: .signal)

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        nameField
                        muscleGroupPicker
                        Spacer(minLength: 8)
                        saveButton
                    }
                    .padding(18)
                }
            }
            .navigationTitle("Add exercise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Color.textSecondary)
                }
            }
            .onAppear { nameFocused = true }
        }
        .presentationDetents([.medium, .large])
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Eyebrow(text: "Name")
            TextField("e.g. Romanian Deadlift", text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .foregroundStyle(.white)
                .focused($nameFocused)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.cardBorder, lineWidth: 0.5)
                )
        }
    }

    private var muscleGroupPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Eyebrow(text: "Muscle group")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(muscleGroupOptions, id: \.self) { option in
                        let isSelected = muscleGroup == option
                        Button {
                            Haptic.selection()
                            muscleGroup = option
                        } label: {
                            Text(option)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(isSelected ? Color.signal : Color.fg1)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(
                                    Capsule()
                                        .fill(isSelected ? Color.signal.opacity(0.08) : Color.ink3)
                                )
                                .overlay(
                                    Capsule()
                                        .stroke(isSelected ? Color.signal.opacity(0.22) : Color.line2, lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            TextField("Or type your own…", text: $muscleGroup)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.cardBorder, lineWidth: 0.5)
                )
        }
    }

    private var saveButton: some View {
        let canSave = !name.trimmingCharacters(in: .whitespaces).isEmpty && !isSaving
        return Button {
            Haptic.medium()
            Task {
                isSaving = true
                let ok = await onAdd(name, muscleGroup)
                isSaving = false
                if ok { dismiss() }
            }
        } label: {
            HStack {
                if isSaving {
                    ProgressView().tint(Color.signalInk).scaleEffect(0.85)
                } else {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                }
                Text(isSaving ? "Saving…" : "Save")
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(canSave ? Color.signalInk : Color.fg2)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(canSave ? Color.signal : Color.ink3)
            )
        }
        .buttonStyle(PressScaleStyle())
        .disabled(!canSave)
    }
}
