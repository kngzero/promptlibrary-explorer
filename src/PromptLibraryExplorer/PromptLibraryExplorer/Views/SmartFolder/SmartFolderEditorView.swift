import SwiftUI

struct SmartFolderEditorView: View {
    @Environment(ExplorerViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss

    @State var folder: SmartFolder
    let isNew: Bool
    var onSave: (SmartFolder) -> Void

    init(folder: SmartFolder? = nil, onSave: @escaping (SmartFolder) -> Void) {
        let f = folder ?? SmartFolder(name: "", criteria: SmartFolderCriteria())
        _folder = State(initialValue: f)
        self.isNew = folder == nil
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(isNew ? "New Smart Folder" : "Edit Smart Folder")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Color.appPrimaryText)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(Color.appBackground)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.appBorder).frame(height: 1)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // Name
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Name")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.appMuted)
                        TextField("Smart Folder Name", text: $folder.name)
                            .textFieldStyle(.roundedBorder)
                    }

                    // Search Query
                    VStack(alignment: .leading, spacing: 6) {
                        Text("File Name Contains")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.appMuted)
                        TextField("Search query...", text: $folder.criteria.searchQuery)
                            .textFieldStyle(.roundedBorder)
                    }

                    // File Types
                    VStack(alignment: .leading, spacing: 8) {
                        Text("File Types")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.appMuted)

                        LazyVGrid(columns: [
                            GridItem(.flexible()),
                            GridItem(.flexible()),
                            GridItem(.flexible()),
                        ], spacing: 8) {
                            ForEach(SmartFolderFileType.allCases, id: \.self) { fileType in
                                Toggle(isOn: Binding(
                                    get: { folder.criteria.fileTypes.contains(fileType) },
                                    set: { isOn in
                                        if isOn {
                                            folder.criteria.fileTypes.insert(fileType)
                                        } else {
                                            folder.criteria.fileTypes.remove(fileType)
                                        }
                                    }
                                )) {
                                    Text(fileType.displayName)
                                        .font(.system(size: 12))
                                }
                                .toggleStyle(.checkbox)
                            }
                        }
                    }

                    // Minimum Rating
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Minimum Rating")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.appMuted)

                        Picker("", selection: $folder.criteria.minRating) {
                            Text("Any").tag(0)
                            ForEach(1...5, id: \.self) { stars in
                                Text("\(stars)+ \(String(repeating: "\u{2605}", count: stars))").tag(stars)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    // Date Range
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Modified Date")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.appMuted)

                        Picker("", selection: $folder.criteria.dateRange) {
                            ForEach(SmartFolderDateRange.allCases, id: \.self) { range in
                                Text(range.displayName).tag(range)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }
                .padding(20)
            }

            // Footer
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Create" : "Save") {
                    onSave(folder)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(folder.name.trimmingCharacters(in: .whitespaces).isEmpty || !folder.criteria.isActive)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Color.appBackground)
            .overlay(alignment: .top) {
                Rectangle().fill(Color.appBorder).frame(height: 1)
            }
        }
        .frame(width: 480, height: 520)
        .background(Color.appBackground)
    }
}
