import SwiftUI
import Foundation

func formatMarkdownText(_ text: String) -> AttributedString {
    var processedText = text

    // Convert markdown lists to bullet points
    processedText = processedText.replacingOccurrences(of: "* ", with: "• ")

    // Fix malformed bold markdown: **text* → **text**
    let malformedBoldRegex = try! NSRegularExpression(pattern: "\\*\\*([^*]+)\\*(?!\\*)", options: [])
    processedText = malformedBoldRegex.stringByReplacingMatches(in: processedText, options: [], range: NSRange(location: 0, length: processedText.count), withTemplate: "**$1**")

    // Support custom heading pattern: "## "
    let lines = processedText.split(separator: "\n", omittingEmptySubsequences: false)
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
