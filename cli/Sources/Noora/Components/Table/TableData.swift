import Foundation

/// Semantic styling options for table content
public enum TableCellStyle {
    case plain(String)
    case primary(String)
    case secondary(String)
    case success(String)
    case warning(String)
    case danger(String)
    case muted(String)
    case accent(String)

    /// Convert to TerminalText
    func toTerminalText() -> TerminalText {
        switch self {
        case let .plain(text):
            return TerminalText(stringLiteral: text)
        case let .primary(text):
            return TerminalText("\(.primary(text))")
        case let .secondary(text):
            return TerminalText("\(.secondary(text))")
        case let .success(text):
            return TerminalText("\(.success(text))")
        case let .warning(text):
            return TerminalText("\(.danger(text))")
        case let .danger(text):
            return TerminalText("\(.danger(text))")
        case let .muted(text):
            return TerminalText("\(.muted(text))")
        case let .accent(text):
            return TerminalText("\(.accent(text))")
        }
    }

    /// Creates a styled cell for a monetary value (green for positive, red for negative)
    /// - Parameters:
    ///   - value: The numeric value
    ///   - formatted: The formatted string to display (e.g., "$1,234.56")
    ///   - invertSign: If true, treats negative as positive (for debts shown as positive numbers)
    public static func money(_ value: Double, formatted: String, invertSign: Bool = false) -> TableCellStyle {
        let isPositive = invertSign ? value < 0 : value >= 0
        return isPositive ? .success(formatted) : .danger(formatted)
    }

    /// Creates a styled cell for a monetary value with automatic formatting
    /// - Parameters:
    ///   - value: The numeric value
    ///   - currencySymbol: Currency symbol (default "$")
    ///   - invertSign: If true, treats negative as positive (for debts)
    public static func money(_ value: Double, currencySymbol: String = "$", invertSign: Bool = false) -> TableCellStyle {
        let absValue = abs(value)
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        let formattedNumber = formatter.string(from: NSNumber(value: absValue)) ?? String(format: "%.2f", absValue)
        let prefix = value < 0 ? "-" : ""
        let formatted = "\(prefix)\(currencySymbol)\(formattedNumber)"
        return money(value, formatted: formatted, invertSign: invertSign)
    }
}

/// A row in a table, containing cells with TerminalText content
public typealias TableRow = [TerminalText]

/// A row in a table using semantic styling
public typealias StyledTableRow = [TableCellStyle]

/// Represents a section in a table with optional header
public struct TableSection {
    /// Optional section header text
    public let header: TerminalText?

    /// Rows in this section
    public let rows: [TableRow]

    /// Creates a new section
    public init(header: TerminalText? = nil, rows: [TableRow]) {
        self.header = header
        self.rows = rows
    }

    /// Creates a new section with styled rows
    public init(header: TerminalText? = nil, styledRows: [StyledTableRow]) {
        self.header = header
        self.rows = styledRows.map { row in
            row.map { $0.toTerminalText() }
        }
    }
}

/// Represents the data structure for a table
public struct TableData {
    /// Column definitions for the table
    public let columns: [TableColumn]

    /// Data rows for the table
    public let rows: [TableRow]

    /// Sections for grouped tables (alternative to flat rows)
    public let sections: [TableSection]?

    /// Footer row (e.g., totals)
    public let footer: TableRow?

    /// Creates a new table data structure
    /// - Parameters:
    ///   - columns: Column definitions
    ///   - rows: Data rows (each row must have same count as columns)
    public init(columns: [TableColumn], rows: [TableRow]) {
        self.columns = columns
        self.rows = rows
        self.sections = nil
        self.footer = nil
    }

    /// Creates a new table data structure with sections
    /// - Parameters:
    ///   - columns: Column definitions
    ///   - sections: Grouped sections with optional headers
    ///   - footer: Optional footer row (e.g., totals)
    public init(columns: [TableColumn], sections: [TableSection], footer: TableRow? = nil) {
        self.columns = columns
        self.sections = sections
        self.rows = sections.flatMap { $0.rows }
        self.footer = footer
    }

    /// Creates a new table data structure with styled content
    /// - Parameters:
    ///   - columns: Column definitions
    ///   - rows: Data rows using semantic styling
    public init(columns: [TableColumn], styledRows: [StyledTableRow]) {
        self.columns = columns
        self.rows = styledRows.map { row in
            row.map { $0.toTerminalText() }
        }
        self.sections = nil
        self.footer = nil
    }

    /// Validates that all rows have the correct number of cells
    public var isValid: Bool {
        rows.allSatisfy { $0.count == columns.count }
    }

    /// Returns a subset of rows for pagination
    /// - Parameters:
    ///   - page: Page number (0-indexed)
    ///   - pageSize: Number of rows per page
    /// - Returns: Subset of rows for the requested page
    public func page(at page: Int, size pageSize: Int) -> [TableRow] {
        let startIndex = page * pageSize
        let endIndex = min(startIndex + pageSize, rows.count)

        guard startIndex < rows.count else { return [] }
        return Array(rows[startIndex ..< endIndex])
    }

    /// Total number of pages given a page size
    public func pageCount(size pageSize: Int) -> Int {
        guard pageSize > 0 else { return 1 }
        return (rows.count + pageSize - 1) / pageSize
    }
}

/// Represents a viewport into table rows for scrolling
public struct TableViewport {
    /// First visible row index
    public var startIndex: Int

    /// Number of visible rows
    public let size: Int

    /// Total number of rows
    public let totalRows: Int

    /// Creates a new viewport
    public init(startIndex: Int = 0, size: Int, totalRows: Int) {
        self.startIndex = startIndex
        self.size = size
        self.totalRows = totalRows
    }

    /// Last visible row index
    public var endIndex: Int {
        min(startIndex + size, totalRows)
    }

    /// Adjusts viewport to ensure the given index is visible
    public mutating func scrollToShow(_ index: Int) {
        if index < startIndex {
            // Scroll up
            startIndex = index
        } else if index >= endIndex {
            // Scroll down
            startIndex = max(0, index - size + 1)
        }
    }

    /// Whether the viewport can scroll up
    public var canScrollUp: Bool {
        startIndex > 0
    }

    /// Whether the viewport can scroll down
    public var canScrollDown: Bool {
        endIndex < totalRows
    }
}
