// Trims Unicode's emoji-test.txt into ReTiCaMsgrCore's bundled emoji.tsv.
// Keeps fully-qualified entries only, drops skin-tone variants and the "Component" group.
// Usage: swift scripts/trim-emoji-test.swift <emoji-test.txt> <out.tsv>
import Foundation

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write(Data("usage: trim-emoji-test.swift <in> <out>\n".utf8))
    exit(1)
}
let input = try String(contentsOfFile: args[1], encoding: .utf8)
let skinTones: Set<String> = ["1F3FB", "1F3FC", "1F3FD", "1F3FE", "1F3FF"]
var group = ""
var out: [String] = []
for line in input.split(separator: "\n", omittingEmptySubsequences: true) {
    if line.hasPrefix("# group: ") {
        group = String(line.dropFirst("# group: ".count))
        continue
    }
    if line.hasPrefix("#") || group == "Component" { continue }
    // "1F600 ; fully-qualified # 😀 E1.0 grinning face"
    let halves = line.split(separator: "#", maxSplits: 1)
    guard halves.count == 2 else { continue }
    let lhs = halves[0].split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
    guard lhs.count == 2, lhs[1] == "fully-qualified" else { continue }
    let codepoints = lhs[0].split(separator: " ").map(String.init)
    if codepoints.contains(where: skinTones.contains) { continue }
    // rhs: " 😀 E1.0 grinning face"
    let rhs = halves[1].trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 2)
    guard rhs.count == 3 else { continue }
    out.append("\(group)\t\(rhs[0])\t\(rhs[2])")
}
try (out.joined(separator: "\n") + "\n").write(toFile: args[2], atomically: true, encoding: .utf8)
print("wrote \(out.count) emoji")
