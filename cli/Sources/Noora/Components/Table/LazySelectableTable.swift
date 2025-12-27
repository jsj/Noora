import Foundation
import Logging

/// Selection info passed to the onSelectionChange callback
public struct SelectionInfo: Sendable {
    public let selectedIndex: Int
    public let totalRows: Int
    public let isNearEnd: Bool

    public init(selectedIndex: Int, totalRows: Int, threshold: Int = 5) {
        self.selectedIndex = selectedIndex
        self.totalRows = totalRows
        self.isNearEnd = totalRows - selectedIndex <= threshold
    }
}

/// An interactive table that supports lazy loading via selection change callbacks.
struct LazySelectableTable<Updates: AsyncSequence> where Updates.Element == TableData {
    let initialData: TableData
    let updates: Updates
    let style: TableStyle
    let pageSize: Int
    let renderer: Rendering
    let standardPipelines: StandardPipelines
    let terminal: Terminaling
    let theme: Theme
    let keyStrokeListener: KeyStrokeListening
    let logger: Logger?
    let tableRenderer: TableRenderer
    let onSelectionChange: @Sendable (SelectionInfo) -> Void
    private let renderQueue = DispatchQueue(label: "lazy-selectable-table-render")

    func run() async throws -> Int {
        guard terminal.isInteractive else {
            throw NooraError.nonInteractiveTerminal
        }

        guard initialData.isValid else {
            throw NooraError.invalidTableData
        }

        guard !initialData.rows.isEmpty else {
            throw NooraError.emptyTable
        }

        let state = LazySelectableState(
            data: initialData,
            selectedIndex: 0,
            viewport: TableViewport(
                startIndex: 0,
                size: min(pageSize, initialData.rows.count),
                totalRows: initialData.rows.count
            )
        )

        // Notify initial selection
        onSelectionChange(SelectionInfo(selectedIndex: 0, totalRows: initialData.rows.count))

        let group = DispatchGroup()

        terminal.inRawMode {
            terminal.withoutCursor {
                render(state.snapshot())

                group.enter()
                Task {
                    await consumeUpdates(state: state)
                    group.leave()
                }

                group.enter()
                Task {
                    listenForInput(state: state)
                    group.leave()
                }

                group.wait()
            }
        }

        return try state.result()
    }

    private func consumeUpdates(state: LazySelectableState) async {
        do {
            for try await newData in updates {
                if Task.isCancelled || state.shouldStop() {
                    break
                }

                guard let snapshot = state.updateData(newData, pageSize: pageSize) else {
                    if !newData.isValid || newData.rows.isEmpty {
                        logger?.warning("Table data is invalid: row cell counts don't match column count")
                    }
                    continue
                }
                render(snapshot)
            }
        } catch {
            logger?.warning("Table updates stream failed: \(error)")
        }
    }

    private func listenForInput(state: LazySelectableState) {
        keyStrokeListener.listen(terminal: terminal) { keyStroke in
            if state.shouldStop() {
                return .abort
            }

            switch keyStroke {
            case .upArrowKey, .printable("k"):
                if let snapshot = state.moveSelection(delta: -1) {
                    render(snapshot)
                    notifySelectionChange(snapshot)
                }
                return .continue

            case .downArrowKey, .printable("j"):
                if let snapshot = state.moveSelection(delta: 1) {
                    render(snapshot)
                    notifySelectionChange(snapshot)
                }
                return .continue

            case .pageUp:
                if let snapshot = state.moveSelection(delta: -pageSize) {
                    render(snapshot)
                    notifySelectionChange(snapshot)
                }
                return .continue

            case .pageDown:
                if let snapshot = state.moveSelection(delta: pageSize) {
                    render(snapshot)
                    notifySelectionChange(snapshot)
                }
                return .continue

            case .home:
                if let snapshot = state.moveTo(index: 0) {
                    render(snapshot)
                    notifySelectionChange(snapshot)
                }
                return .continue

            case .end:
                if let snapshot = state.moveToEnd() {
                    render(snapshot)
                    notifySelectionChange(snapshot)
                }
                return .continue

            case .returnKey:
                state.selectCurrent()
                onSelectionChange(SelectionInfo(selectedIndex: -1, totalRows: 0)) // Signal completion
                return .abort

            case .escape:
                state.cancel()
                onSelectionChange(SelectionInfo(selectedIndex: -1, totalRows: 0)) // Signal completion
                return .abort

            default:
                return .continue
            }
        }
    }

    private func notifySelectionChange(_ snapshot: LazySelectableState.Snapshot) {
        let info = SelectionInfo(
            selectedIndex: snapshot.selectedIndex,
            totalRows: snapshot.data.rows.count
        )
        onSelectionChange(info)
    }

    private func render(_ snapshot: LazySelectableState.Snapshot) {
        let visibleRows = Array(snapshot.data.rows[snapshot.viewport.startIndex ..< snapshot.viewport.endIndex])
        let visibleData = TableData(columns: snapshot.data.columns, rows: visibleRows)
        let selectedInViewport = snapshot.selectedIndex - snapshot.viewport.startIndex

        var lines: [String] = []
        lines.append(renderTableWithSelectionHighlighting(
            data: visibleData,
            selectedIndex: selectedInViewport
        ))
        lines.append("")
        lines.append(renderNavigationHelp(
            selectedIndex: snapshot.selectedIndex,
            totalRows: snapshot.data.rows.count,
            viewport: snapshot.viewport
        ))

        let output = lines.joined(separator: "\n")
        renderQueue.sync {
            renderer.render(output, standardPipeline: standardPipelines.output)
        }
    }

    private func renderTableWithSelectionHighlighting(data: TableData, selectedIndex: Int) -> String {
        guard data.isValid else {
            logger?.warning("Table data is invalid: row cell counts don't match column count")
            return ""
        }

        let layout = tableRenderer.calculateLayout(data: data, style: style, terminal: terminal)
        var lines: [String] = []

        lines.append(tableRenderer.renderBorder(.top, layout: layout, style: style, theme: theme, terminal: terminal))

        lines.append(tableRenderer.renderRow(
            data.columns.map { TerminalText("\(.primary($0.title.plain()))") },
            layout: layout,
            style: style,
            theme: theme,
            terminal: terminal,
            columns: data.columns,
            isHeader: true
        ))

        if style.headerSeparator {
            lines.append(tableRenderer.renderBorder(.middle, layout: layout, style: style, theme: theme, terminal: terminal))
        }

        for (index, row) in data.rows.enumerated() {
            let isSelected = index == selectedIndex
            if isSelected {
                lines.append(renderSelectedRow(
                    row,
                    layout: layout,
                    columns: data.columns
                ))
            } else {
                lines.append(tableRenderer.renderRow(
                    row,
                    layout: layout,
                    style: style,
                    theme: theme,
                    terminal: terminal,
                    columns: data.columns
                ))
            }
        }

        lines.append(tableRenderer.renderBorder(.bottom, layout: layout, style: style, theme: theme, terminal: terminal))

        return lines.joined(separator: "\n")
    }

    private func renderSelectedRow(
        _ cells: [TerminalText],
        layout: TableLayout,
        columns: [TableColumn]
    ) -> String {
        var parts: [String] = []
        let chars = style.borderCharacters
        let borderColor = theme.muted

        parts.append(chars.vertical.hexIfColoredTerminal(borderColor, terminal).onHexIfColoredTerminal(
            style.selectionColor,
            terminal
        ))

        for (index, cell) in cells.enumerated() {
            let width = layout.columnWidths[index]
            let alignment = columns[index].alignment

            let leftPadding = String(repeating: " ", count: style.cellPadding)
            parts.append(leftPadding.onHexIfColoredTerminal(style.selectionColor, terminal))

            let plainText = cell.plain()
            let truncatedText = plainText.count > width ? String(plainText.prefix(width - 1)) + "…" : plainText

            let contentPadding = width - truncatedText.count
            let cellContent: String

            switch alignment {
            case .left:
                cellContent = truncatedText + String(repeating: " ", count: contentPadding)
            case .right:
                cellContent = String(repeating: " ", count: contentPadding) + truncatedText
            case .center:
                let leftPad = contentPadding / 2
                let rightPad = contentPadding - leftPad
                cellContent = String(repeating: " ", count: leftPad) + truncatedText + String(repeating: " ", count: rightPad)
            }

            parts.append(cellContent.hexIfColoredTerminal(style.selectionTextColor, terminal).onHexIfColoredTerminal(
                style.selectionColor,
                terminal
            ))

            let rightPadding = String(repeating: " ", count: style.cellPadding)
            parts.append(rightPadding.onHexIfColoredTerminal(style.selectionColor, terminal))

            if index < cells.count - 1 {
                parts.append(chars.vertical.hexIfColoredTerminal(borderColor, terminal).onHexIfColoredTerminal(
                    style.selectionColor,
                    terminal
                ))
            }
        }

        parts.append(chars.vertical.hexIfColoredTerminal(borderColor, terminal).onHexIfColoredTerminal(
            style.selectionColor,
            terminal
        ))

        return parts.joined()
    }

    private func renderNavigationHelp(
        selectedIndex: Int,
        totalRows: Int,
        viewport _: TableViewport
    ) -> String {
        let currentPage = (selectedIndex / pageSize) + 1
        let totalPages = (totalRows + pageSize - 1) / pageSize

        let status = "Row \(selectedIndex + 1) of \(totalRows)"
        let pageInfo = totalPages > 1 ? " (Page \(currentPage)/\(totalPages))" : ""
        let controls = "↑↓/jk: Navigate, Enter: Select, Esc: Cancel"

        if totalPages > 1 {
            let pageControls = "PgUp/PgDn: Page, Home/End: First/Last"
            return "\(status)\(pageInfo)\n\(controls), \(pageControls)"
                .hexIfColoredTerminal(theme.muted, terminal)
        } else {
            return "\(status)\n\(controls)"
                .hexIfColoredTerminal(theme.muted, terminal)
        }
    }
}

private final class LazySelectableState {
    struct Snapshot {
        let data: TableData
        let selectedIndex: Int
        let viewport: TableViewport
    }

    private let queue = DispatchQueue(label: "lazy-selectable-table")
    private var data: TableData
    private var selectedIndex: Int
    private var viewport: TableViewport
    private var stopped = false
    private var selection: Int?

    init(data: TableData, selectedIndex: Int, viewport: TableViewport) {
        self.data = data
        self.selectedIndex = selectedIndex
        self.viewport = viewport
    }

    func snapshot() -> Snapshot {
        queue.sync {
            Snapshot(data: data, selectedIndex: selectedIndex, viewport: viewport)
        }
    }

    func updateData(_ newData: TableData, pageSize: Int) -> Snapshot? {
        queue.sync {
            guard newData.isValid, !newData.rows.isEmpty else { return nil }
            data = newData

            if selectedIndex >= data.rows.count {
                selectedIndex = max(0, data.rows.count - 1)
            }

            viewport = TableViewport(
                startIndex: min(viewport.startIndex, max(0, data.rows.count - 1)),
                size: min(pageSize, data.rows.count),
                totalRows: data.rows.count
            )

            var v = viewport
            v.scrollToShow(selectedIndex)
            viewport = v

            return Snapshot(data: data, selectedIndex: selectedIndex, viewport: viewport)
        }
    }

    func moveSelection(delta: Int) -> Snapshot? {
        queue.sync {
            guard !data.rows.isEmpty else { return nil }
            let maxIndex = max(0, data.rows.count - 1)
            selectedIndex = min(max(0, selectedIndex + delta), maxIndex)
            var v = viewport
            v.scrollToShow(selectedIndex)
            viewport = v
            return Snapshot(data: data, selectedIndex: selectedIndex, viewport: viewport)
        }
    }

    func moveTo(index: Int) -> Snapshot? {
        queue.sync {
            guard !data.rows.isEmpty else { return nil }
            selectedIndex = min(max(index, 0), data.rows.count - 1)
            var v = viewport
            v.scrollToShow(selectedIndex)
            viewport = v
            return Snapshot(data: data, selectedIndex: selectedIndex, viewport: viewport)
        }
    }

    func moveToEnd() -> Snapshot? {
        queue.sync {
            guard !data.rows.isEmpty else { return nil }
            selectedIndex = data.rows.count - 1
            var v = viewport
            v.scrollToShow(selectedIndex)
            viewport = v
            return Snapshot(data: data, selectedIndex: selectedIndex, viewport: viewport)
        }
    }

    func selectCurrent() {
        queue.sync {
            stopped = true
            selection = selectedIndex
        }
    }

    func cancel() {
        queue.sync {
            stopped = true
            selection = nil
        }
    }

    func shouldStop() -> Bool {
        queue.sync { stopped }
    }

    func result() throws -> Int {
        try queue.sync {
            guard let selection else {
                throw NooraError.userCancelled
            }
            return selection
        }
    }
}
