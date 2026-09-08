import Foundation

/// Align equal content first; pair replacements only between stable anchors.
enum TableAlignment {
    static func pairs(_ old: [String], _ new: [String]) -> [(Int?, Int?)] {
        let changes = new.difference(from: old)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in changes {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var result: [(Int?, Int?)] = [], a = 0, b = 0
        while a < old.count || b < new.count {
            var left: [Int] = [], right: [Int] = []
            while a < old.count && removed.contains(a) { left.append(a); a += 1 }
            while b < new.count && inserted.contains(b) { right.append(b); b += 1 }
            for i in 0..<max(left.count, right.count) {
                result.append((i < left.count ? left[i] : nil, i < right.count ? right[i] : nil))
            }
            if a < old.count && b < new.count { result.append((a, b)); a += 1; b += 1 }
            else if a < old.count { result.append((a, nil)); a += 1 }
            else if b < new.count { result.append((nil, b)); b += 1 }
        }
        return result
    }

    static func align(_ old: ComparedSheet, _ new: ComparedSheet) -> (ComparedSheet, ComparedSheet) {
        func signature(_ values: [String]) -> String {
            values.map { "\($0.utf8.count):\($0)" }.joined()
        }
        func columns(_ sheet: ComparedSheet) -> [String] {
            (0..<sheet.columnCount).map { column in
                signature((0..<sheet.rowCount).compactMap { row in
                    let text = sheet.cells[GridAddress(row: row, column: column)]?.text ?? ""
                    return text.isEmpty ? nil : text
                })
            }
        }
        // Headers remain stable when rows are added. Full content disambiguates
        // duplicate headers when only columns have changed.
        func headers(_ sheet: ComparedSheet) -> [String] {
            (0..<sheet.columnCount).map { sheet.cells[GridAddress(row: 0, column: $0)]?.text ?? "" }
        }
        let oh = headers(old), nh = headers(new)
        let useHeaders = Set(oh.filter { !$0.isEmpty }).count == oh.count &&
            Set(nh.filter { !$0.isEmpty }).count == nh.count && !Set(oh).intersection(nh).isEmpty
        let cols = pairs(useHeaders ? oh : columns(old), useHeaders ? nh : columns(new))
        let common = cols.filter { $0.0 != nil && $0.1 != nil }
        func rows(_ sheet: ComparedSheet, oldSide: Bool) -> [String] {
            (0..<sheet.rowCount).map { row in
                signature(common.map { pair in
                    sheet.cells[GridAddress(row: row, column: (oldSide ? pair.0 : pair.1)!)]?.text ?? ""
                })
            }
        }
        let rowPairs = pairs(rows(old, oldSide: true), rows(new, oldSide: false))
        func remap(_ sheet: ComparedSheet, oldSide: Bool) -> ComparedSheet {
            var cells: [GridAddress: GridCell] = [:]
            for (r, pair) in rowPairs.enumerated() {
                guard let sourceRow = oldSide ? pair.0 : pair.1 else { continue }
                for (c, pair) in cols.enumerated() {
                    guard let sourceColumn = oldSide ? pair.0 : pair.1 else { continue }
                    if let cell = sheet.cells[GridAddress(row: sourceRow, column: sourceColumn)] {
                        cells[GridAddress(row: r, column: c)] = cell
                    }
                }
            }
            return ComparedSheet(name: sheet.name, cells: cells, rowCount: rowPairs.count, columnCount: cols.count)
        }
        return (remap(old, oldSide: true), remap(new, oldSide: false))
    }
}
