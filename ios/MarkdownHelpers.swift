import Foundation
import SwiftUI

struct MessageBlock {
    let text: String
    let isQuoted: Bool
}

func formatMarkdownText(_ text: String) -> AttributedString {
    var processedText = text

    // Strip quote delimiters so they don't render if this path is used
    processedText = processedText.replacingOccurrences(of: ">>>", with: "")
    processedText = processedText.replacingOccurrences(of: "<<<", with: "")

    // Ensure list markers always start on their own line (even if the model puts them inline).
    // Only match "- " (hyphen), NOT "* " — asterisks are used in **bold** and *italic* markers.
    processedText = processedText.replacingOccurrences(of: "([^\\n])(- )", with: "$1\n- ", options: .regularExpression)
    processedText = processedText.replacingOccurrences(of: "([^\\n])(\\d+\\. )", with: "$1\n$2", options: .regularExpression)

    // Convert markdown list markers to bullet points (line-start only)
    processedText = processedText.replacingOccurrences(of: "(?m)^\\* ", with: "• ", options: .regularExpression)
    processedText = processedText.replacingOccurrences(of: "(?m)^- ", with: "• ", options: .regularExpression)

    // Fix malformed bold markdown: **text* → **text**
    let malformedBoldRegex = try! NSRegularExpression(pattern: "\\*\\*([^*]+)\\*(?!\\*)", options: [])
    processedText = malformedBoldRegex.stringByReplacingMatches(in: processedText, options: [], range: NSRange(location: 0, length: processedText.count), withTemplate: "**$1**")

    return renderMarkdownLines(processedText)
}

/// Parse message text into blocks — regular text and quoted chunks
func parseMessageBlocks(_ text: String) -> [MessageBlock] {
    return splitQuotedBlocks(text)
}

/// Render plain markdown (no quote delimiters) into AttributedString.
/// Handles: # h1–h4, **bold**, *italic*, `code`, - bullets, 1. lists, > blockquotes,
/// ``` code blocks, and --- horizontal rules.
func renderMarkdownLines(_ text: String) -> AttributedString {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }
    var output = AttributedString()

    var mdOptions = AttributedString.MarkdownParsingOptions()
    mdOptions.interpretedSyntax = .inlineOnlyPreservingWhitespace

    var inCodeBlock = false

    for (idx, lineText) in lines.enumerated() {
        let attributed: AttributedString

        // Code fence toggle — skip the fence line itself
        if lineText.hasPrefix("```") {
            inCodeBlock.toggle()
            if idx < lines.count - 1 { output.append(AttributedString("\n")) }
            continue
        }

        if inCodeBlock {
            var code = AttributedString(lineText)
            code.font = .system(size: 13, weight: .regular, design: .monospaced)
            attributed = code
        } else {
            let trimmed = lineText.trimmingCharacters(in: .whitespaces)

            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                // Horizontal rule → blank separator line
                attributed = AttributedString("")

            } else if trimmed.hasPrefix("#### ") {
                var h = AttributedString(String(trimmed.dropFirst(5)))
                h.font = .system(size: 13, weight: .semibold)
                attributed = h

            } else if trimmed.hasPrefix("### ") {
                var h = AttributedString(String(trimmed.dropFirst(4)))
                h.font = .system(size: 15, weight: .semibold)
                attributed = h

            } else if trimmed.hasPrefix("## ") {
                var h = AttributedString(String(trimmed.dropFirst(3)))
                h.font = .system(size: 17, weight: .semibold)
                attributed = h

            } else if trimmed.hasPrefix("# ") {
                var h = AttributedString(String(trimmed.dropFirst(2)))
                h.font = .system(size: 20, weight: .bold)
                attributed = h

            } else if trimmed.hasPrefix("> ") {
                // Blockquote — visual │ prefix + inline markdown
                let quote = String(trimmed.dropFirst(2))
                let body = (try? AttributedString(markdown: quote, options: mdOptions)) ?? AttributedString(quote)
                attributed = AttributedString("│ ") + body

            } else {
                // Default: inline markdown (bold, italic, `code`, numbered lists, bullets, plain text)
                do {
                    attributed = try AttributedString(markdown: lineText, options: mdOptions)
                } catch {
                    attributed = AttributedString(lineText)
                }
            }
        }

        output.append(attributed)
        if idx < lines.count - 1 {
            output.append(AttributedString("\n"))
        }
    }

    return output
}

/// Split text into alternating regular / quoted blocks using >>> / <<< delimiters
private func splitQuotedBlocks(_ text: String) -> [MessageBlock] {
    var blocks: [MessageBlock] = []
    var remaining = text

    while let openRange = remaining.range(of: ">>>") {
        let before = String(remaining[remaining.startIndex..<openRange.lowerBound])
        if !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            blocks.append(MessageBlock(text: before, isQuoted: false))
        }

        let afterOpen = remaining[openRange.upperBound...]
        if let closeRange = afterOpen.range(of: "<<<") {
            let quoted = String(afterOpen[afterOpen.startIndex..<closeRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !quoted.isEmpty {
                blocks.append(MessageBlock(text: quoted, isQuoted: true))
            }
            remaining = String(afterOpen[closeRange.upperBound...])
        } else {
            let quoted = String(afterOpen).trimmingCharacters(in: .whitespacesAndNewlines)
            if !quoted.isEmpty {
                blocks.append(MessageBlock(text: quoted, isQuoted: true))
            }
            remaining = ""
            break
        }
    }

    if !remaining.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        blocks.append(MessageBlock(text: remaining, isQuoted: false))
    }

    return blocks
}
