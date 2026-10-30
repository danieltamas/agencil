import AgencilCore
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "version":
    print("agencil \(AgencilVersion.current())")
default:
    // The installer recognises its own command by this marker before it replaces or removes the file.
    FileHandle.standardError.write(Data("agencil-cli: usage: agencil version\n".utf8))
    exit(2)
}
