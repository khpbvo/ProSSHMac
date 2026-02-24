// Extracted from TerminalGrid.swift

import Foundation

extension TerminalGrid {

    // MARK: - A.6.3 Print Character

    /// Print a character at the cursor position with current attributes.
    /// Handles auto-wrap, insert mode, and wide characters.
    nonisolated func printCharacter(_ char: Character) {
        // If pending wrap, perform the actual wrap now
        if cursor.pendingWrap {
            performWrap()
        }

        let charStr: String
        if let scalar = char.unicodeScalars.first,
           char.unicodeScalars.count == 1,
           scalar.value < 128 {
            charStr = Self.asciiScalarStringCache[Int(scalar.value)]
        } else {
            charStr = String(char)
        }
        let isWide = char.isWideCharacter

        // Wide character at the last column: wrap first so the character
        // starts at column 0 of the next row (matching xterm/VTE behavior).
        // Without this, the primary cell is written at columns-1 but the
        // continuation cell at columns would be out of bounds.
        if isWide && cursor.col >= columns - 1 {
            if autoWrapMode {
                performWrap()
            }
        }

        let row = cursor.row
        let col = cursor.col

        // In insert mode, shift existing chars right
        if insertMode {
            let shiftCount = isWide ? 2 : 1
            insertBlanks(count: shiftCount, atRow: row, col: col)
        }

        let attributes = isWide ? currentAttributes.union(.wideChar) : currentAttributes

        // Pre-apply boldIsBright at write-time
        let fgPacked: UInt32
        if TerminalDefaults.boldIsBright && attributes.contains(.bold) {
            fgPacked = currentFgColor.packedRGBA(bold: true, boldIsBright: true)
        } else {
            fgPacked = currentFgPacked
        }

        let cp = encodeGrapheme(charStr)

        // Write the cell(s) in place.
        withActiveBuffer { buffer, base in
            let physical = physicalRow(row, base: base)
            releaseCellGrapheme(buffer[physical][col].codepoint)
            buffer[physical][col] = TerminalCell(
                codepoint: cp,
                fgPacked: fgPacked,
                bgPacked: currentBgPacked,
                ulPacked: currentUnderlinePacked,
                attributes: attributes,
                underlineStyle: currentUnderlineStyle,
                width: isWide ? 2 : 1
            )

            // For wide characters, write a continuation cell.
            if isWide && col + 1 < columns {
                releaseCellGrapheme(buffer[physical][col + 1].codepoint)
                buffer[physical][col + 1] = TerminalCell(
                    codepoint: 0,
                    fgPacked: fgPacked,
                    bgPacked: currentBgPacked,
                    ulPacked: currentUnderlinePacked,
                    attributes: currentAttributes,
                    underlineStyle: currentUnderlineStyle,
                    width: 0  // continuation
                )
            }
        }
        markDirty(row: row)

        lastPrintedChar = char

        // Advance cursor
        if isWide {
            if cursor.col + 1 < columns - 1 {
                cursor.col += 2
            } else {
                // Wide char at end — cursor goes to last col, pending wrap
                cursor.col = columns - 1
                if autoWrapMode {
                    cursor.pendingWrap = true
                }
            }
        } else {
            cursor.advanceAfterPrint(gridCols: columns, autoWrap: autoWrapMode)
        }
    }

    /// Repeat the last printed character `n` times (REP — CSI b).
    nonisolated func repeatLastCharacter(_ n: Int) {
        guard let ch = lastPrintedChar else { return }
        for _ in 0..<max(n, 1) {
            printCharacter(ch)
        }
    }

    /// Print a run of printable ASCII bytes using a bulk fast path.
    /// Calls `withActiveCells` once for the entire run, skips wide-character
    /// checks (ASCII is never wide), and calls `markDirty` once per affected
    /// row range. This avoids per-character overhead in high-throughput output.
    /// Accepts Data + range to avoid per-chunk byte array materialization from VTParser.
    nonisolated func printASCIIBytesBulk(_ bytes: Data, range: Range<Int>) {
        guard !range.isEmpty else { return }

        // Insert mode is rare; fall back to the per-character path for all
        // bytes so that insertBlanks() is called for each character.
        if insertMode {
            let charset: Charset = (activeCharset == 1) ? g1Charset : g0Charset
            let needsCharsetMapping = charset != .ascii
            for i in range {
                let byte = bytes[i]
                guard byte >= 0x20 && byte <= 0x7E else { continue }
                let ch: Character
                if needsCharsetMapping {
                    switch charset {
                    case .ascii:
                        ch = Self.asciiCharacterCache[Int(byte)]
                    case .ukNational:
                        ch = (byte == 0x23) ? "£" : Self.asciiCharacterCache[Int(byte)]
                    case .decSpecialGraphics:
                        if (0x60...0x7E).contains(byte),
                           let mapped = DECSpecialGraphics.mapCharacter(byte) {
                            ch = mapped
                        } else {
                            ch = Self.asciiCharacterCache[Int(byte)]
                        }
                    }
                } else {
                    ch = Self.asciiCharacterCache[Int(byte)]
                }
                printCharacter(ch)
            }
            return
        }

        let charset: Charset = (activeCharset == 1) ? g1Charset : g0Charset
        let needsCharsetMapping = charset != .ascii

        // Capture cached packed colors once for the entire run.
        // Pre-apply boldIsBright at write-time so snapshot() needs no per-cell check.
        let attrs = currentAttributes
        let fgPacked: UInt32
        if TerminalDefaults.boldIsBright && attrs.contains(.bold) {
            fgPacked = currentFgColor.packedRGBA(bold: true, boldIsBright: true)
        } else {
            fgPacked = currentFgPacked
        }
        let bgPacked = currentBgPacked
        let ulPacked = currentUnderlinePacked
        let ulStyle = currentUnderlineStyle

        withActiveBufferState { buf, base, rowMap in
            var dirtyRowLo = Int.max
            var dirtyRowHi = -1

            for i in range {
                let byte = bytes[i]
                guard byte >= 0x20 && byte <= 0x7E else { continue }

                // Handle pending wrap
                if cursor.pendingWrap {
                    // Mark the current line as wrapped
                    let lastCol = columns - 1
                    let wrappedPhysical = physicalRow(cursor.row, base: base, map: rowMap)
                    var lastCell = buf[wrappedPhysical][lastCol]
                    lastCell.attributes.insert(.wrapped)
                    lastCell.isDirty = true
                    buf[wrappedPhysical][lastCol] = lastCell

                    dirtyRowLo = min(dirtyRowLo, cursor.row)
                    dirtyRowHi = max(dirtyRowHi, cursor.row)

                    cursor.col = 0
                    cursor.pendingWrap = false

                    if cursor.row == scrollBottom {
                        // Inline scrollUp(lines: 1), using O(1) ring rotation
                        // for the common full-screen scroll region.
                        if !usingAlternateBuffer {
                            let topPhysical = physicalRow(scrollTop, base: base, map: rowMap)
                            var topRow = buf[topPhysical]
                            let graphemeOverrides = resolveSideTableEntries(in: &topRow)
                            let isWrapped = topRow.last.map { $0.attributes.contains(.wrapped) } ?? false
                            scrollback.push(cells: topRow, isWrapped: isWrapped, graphemeOverrides: graphemeOverrides)
                        }

                        if scrollTop == 0 && scrollBottom == rows - 1 {
                            base += 1
                            if base == rows { base = 0 }
                        } else {
                            let regionCount = scrollBottom - scrollTop + 1
                            var regionKeys = [Int]()
                            regionKeys.reserveCapacity(regionCount)
                            for row in scrollTop...scrollBottom {
                                regionKeys.append(logicalRowIndex(row, base: base))
                            }
                            let regionPhysicalRows = regionKeys.map { rowMap[$0] }
                            for i in 0..<regionCount {
                                rowMap[regionKeys[i]] = regionPhysicalRows[(i + 1) % regionCount]
                            }
                        }

                        let bottomPhysical = physicalRow(scrollBottom, base: base, map: rowMap)
                        buf[bottomPhysical] = makeBlankRow()
                        dirtyRowLo = min(dirtyRowLo, scrollTop)
                        dirtyRowHi = max(dirtyRowHi, scrollBottom)
                    } else if cursor.row < rows - 1 {
                        cursor.row += 1
                    }
                }

                // Resolve character string and codepoint — ASCII is never wide
                let charStr: String
                let codepoint: UInt32
                if needsCharsetMapping {
                    switch charset {
                    case .ascii:
                        charStr = Self.asciiScalarStringCache[Int(byte)]
                        codepoint = UInt32(byte)
                    case .ukNational:
                        if byte == 0x23 {
                            charStr = "£"
                            codepoint = 0xA3 // £ Unicode scalar
                        } else {
                            charStr = Self.asciiScalarStringCache[Int(byte)]
                            codepoint = UInt32(byte)
                        }
                    case .decSpecialGraphics:
                        if (0x60...0x7E).contains(byte),
                           let mapped = DECSpecialGraphics.mapCharacter(byte) {
                            charStr = String(mapped)
                            codepoint = mapped.unicodeScalars.first?.value ?? UInt32(byte)
                        } else {
                            charStr = Self.asciiScalarStringCache[Int(byte)]
                            codepoint = UInt32(byte)
                        }
                    }
                } else {
                    charStr = Self.asciiScalarStringCache[Int(byte)]
                    codepoint = UInt32(byte)
                }

                let row = cursor.row
                let col = cursor.col
                let physical = physicalRow(row, base: base, map: rowMap)

                buf[physical][col] = TerminalCell(
                    codepoint: codepoint,
                    fgPacked: fgPacked,
                    bgPacked: bgPacked,
                    ulPacked: ulPacked,
                    attributes: attrs,
                    underlineStyle: ulStyle,
                    width: 1
                )

                dirtyRowLo = min(dirtyRowLo, row)
                dirtyRowHi = max(dirtyRowHi, row)

                lastPrintedChar = needsCharsetMapping
                    ? charStr.first ?? Self.asciiCharacterCache[Int(byte)]
                    : Self.asciiCharacterCache[Int(byte)]

                // Advance cursor (ASCII is always width 1)
                if cursor.col >= columns - 1 {
                    if autoWrapMode {
                        cursor.pendingWrap = true
                    }
                } else {
                    cursor.col += 1
                }
            }

            // Batch mark dirty for all affected rows
            if dirtyRowLo <= dirtyRowHi {
                for r in dirtyRowLo...dirtyRowHi {
                    markDirty(row: r)
                }
            }
        }
    }

    /// Process plain ground-state text bytes in bulk.
    /// Supports printable ASCII plus CR/LF controls.
    /// Accepts Data + range to avoid extra copies from VTParser.
    nonisolated func processGroundTextBytes(_ bytes: Data, range: Range<Int>) {
        guard !range.isEmpty else { return }

        var runStart: Int = -1

        for idx in range {
            let byte = bytes[idx]
            if byte >= 0x20 && byte <= 0x7E {
                if runStart < 0 {
                    runStart = idx
                }
                continue
            }

            // Flush printable run
            if runStart >= 0 {
                printASCIIBytesBulk(bytes, range: runStart..<idx)
                runStart = -1
            }

            switch byte {
            case 0x0A: // LF
                lineFeed()
            case 0x0D: // CR
                carriageReturn()
            default:
                break
            }
        }

        // Flush trailing printable run
        if runStart >= 0 {
            printASCIIBytesBulk(bytes, range: runStart..<range.upperBound)
        }
    }

    /// Perform the actual line wrap: CR + LF, scrolling if needed.
    nonisolated func performWrap() {
        // Mark the current line as wrapped
        if cursor.col < columns {
            let row = cursor.row
            let lastCol = columns - 1
            withActiveBuffer { buffer, base in
                let physical = physicalRow(row, base: base)
                var lastCell = buffer[physical][lastCol]
                lastCell.attributes.insert(.wrapped)
                lastCell.isDirty = true
                buffer[physical][lastCol] = lastCell
            }
        }

        cursor.col = 0
        cursor.pendingWrap = false

        if cursor.row == scrollBottom {
            scrollUp(lines: 1)
        } else if cursor.row < rows - 1 {
            cursor.row += 1
        }
    }

}
