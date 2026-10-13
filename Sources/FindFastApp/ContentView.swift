import SwiftUI
import AppKit
import FindFastCore

struct ContentView: View {
    @StateObject private var viewModel = SearchViewModel()
    @FocusState private var searchFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            pathRow
            Divider()
            searchRow
            Divider()
            statusRow
            resultsArea
        }
        .frame(minWidth: 720, minHeight: 540)
        .onChange(of: viewModel.sortOrder) { _, _ in
            viewModel.queryChanged()
        }
        .onChange(of: viewModel.sortAscending) { _, _ in
            viewModel.queryChanged()
        }
        .onChange(of: viewModel.isIndexing) { _, isIndexing in
            if !isIndexing { searchFieldFocused = true }
        }
        .onAppear {
            viewModel.loadAndWatch()
            // Without this, the window can be key while no control is first
            // responder, so keystrokes land nowhere — search apps should
            // default focus into the search box, not require a manual click.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                searchFieldFocused = true
            }
        }
    }

    private var pathRow: some View {
        HStack(spacing: 8) {
            Button {
                chooseFolder()
            } label: {
                Image(systemName: "folder")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Choose a folder to scan")
            .disabled(viewModel.isIndexing)
            TextField("Root path to index", text: $viewModel.rootPath)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .onSubmit {
                    // Enter in the path field = "switch to this root":
                    // cache-aware (instant if already scanned before),
                    // unlike Rescan which always forces a full rescan.
                    viewModel.loadAndWatch()
                }
            Spacer()
            Button {
                viewModel.rebuildIndex()
            } label: {
                Label(
                    viewModel.isIndexing ? "Indexing…" : "Rescan", systemImage: "arrow.clockwise"
                )
                .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(viewModel.isIndexing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.regularMaterial)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: viewModel.rootPath)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        viewModel.rootPath = url.path
        viewModel.loadAndWatch()
    }

    private var searchRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 20))
                .foregroundStyle(
                    LinearGradient(colors: [.purple, .blue], startPoint: .top, endPoint: .bottom)
                )
            TextField("파일 검색 — 초성(ㄴㄴ), 확장자(*.sql ext:py), 혼합(report *.swift)", text: $viewModel.queryText)
                .textFieldStyle(.plain)
                .font(.system(size: 20))
                .focused($searchFieldFocused)
                .onChange(of: viewModel.queryText) { _, _ in
                    viewModel.queryChanged()
                }

            if viewModel.isIndexing {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 16, height: 16)
            } else if !viewModel.queryText.isEmpty {
                Button {
                    viewModel.queryText = ""
                    viewModel.queryChanged()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1)
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var statusRow: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(viewModel.isIndexing ? Color.orange : Color.green)
                .frame(width: 6, height: 6)
                .animation(.easeInOut(duration: 0.25), value: viewModel.isIndexing)
            Text(viewModel.statusText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Picker("", selection: $viewModel.sortOrder) {
                Text("관련도").tag(SearchSortOrder.relevance)
                Text("이름").tag(SearchSortOrder.name)
                Text("수정일").tag(SearchSortOrder.modified)
                Text("생성일").tag(SearchSortOrder.created)
            }
            .pickerStyle(.segmented)
            .frame(width: 260)
            .disabled(viewModel.isIndexing)
            Button {
                viewModel.sortAscending.toggle()
            } label: {
                Image(systemName: viewModel.sortAscending ? "arrow.up" : "arrow.down")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(viewModel.sortOrder == .relevance ? Color.secondary.opacity(0.4) : .secondary)
            .disabled(viewModel.isIndexing || viewModel.sortOrder == .relevance)
            .help(viewModel.sortAscending ? "오름차순" : "내림차순")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var resultsArea: some View {
        if viewModel.results.isEmpty, !viewModel.queryText.isEmpty, !viewModel.isIndexing {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 32))
                    .foregroundStyle(.tertiary)
                Text("No results")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(viewModel.results, id: \.path) { result in
                ResultRow(result: result)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        NSWorkspace.shared.open(URL(fileURLWithPath: result.path))
                    }
                    .contextMenu {
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting(
                                [URL(fileURLWithPath: result.path)])
                        }
                        Button("Copy Path") {
                            let pasteboard = NSPasteboard.general
                            pasteboard.clearContents()
                            pasteboard.setString(result.path, forType: .string)
                        }
                    }
            }
            .listStyle(.plain)
            .animation(.easeInOut(duration: 0.15), value: viewModel.results.map(\.path))
        }
    }
}

private struct ResultRow: View {
    let result: SearchResult
    @State private var isHovered = false

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    private var relativeModifiedTime: String {
        let date = Date(timeIntervalSince1970: TimeInterval(result.mtime))
        return Self.relativeDateFormatter.localizedString(for: date, relativeTo: Date())
    }

    private var relativeCreatedTime: String {
        let date = Date(timeIntervalSince1970: TimeInterval(result.crtime))
        return Self.relativeDateFormatter.localizedString(for: date, relativeTo: Date())
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: result.path))
                .resizable()
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(result.path)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("·")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Text("수정 \(relativeModifiedTime)")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .fixedSize()
                    Text("·")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Text("생성 \(relativeCreatedTime)")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            Spacer()
            if !result.isDirectory {
                Text(ByteCountFormatter.string(fromByteCount: Int64(result.size), countStyle: .file))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.secondary.opacity(isHovered ? 0.08 : 0))
        )
        .onHover { hovering in
            isHovered = hovering
        }
    }
}
