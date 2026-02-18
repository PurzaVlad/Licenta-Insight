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

    // Convert markdown lists to bullet points
    processedText = processedText.replacingOccurrences(of: "* ", with: "• ")

    // Fix malformed bold markdown: **text* → **text**
    let malformedBoldRegex = try! NSRegularExpression(pattern: "\\*\\*([^*]+)\\*(?!\\*)", options: [])
    processedText = malformedBoldRegex.stringByReplacingMatches(in: processedText, options: [], range: NSRange(location: 0, length: processedText.count), withTemplate: "**$1**")

    return renderMarkdownLines(processedText)
}

/// Parse message text into blocks — regular text and quoted chunks
func parseMessageBlocks(_ text: String) -> [MessageBlock] {
    return splitQuotedBlocks(text)
}

/// Render plain markdown (no quote delimiters) into AttributedString
func renderMarkdownLines(_ text: String) -> AttributedString {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    var output = AttributedString()

    for (idx, line) in lines.enumerated() {
        let lineText = String(line)
        if lineText.hasPrefix("## ") {
            let title = String(lineText.dropFirst(3))
            var heading = AttributedString(title)
            heading.font = .system(size: 17, weight: .semibold)
            output.append(heading)
        } else {
            do {
                var options = AttributedString.MarkdownParsingOptions()
                options.interpretedSyntax = .inlineOnlyPreservingWhitespace
                let attributedLine = try AttributedString(markdown: lineText, options: options)
                output.append(attributedLine)
            } catch {
                output.append(AttributedString(lineText))
            }
        }
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
