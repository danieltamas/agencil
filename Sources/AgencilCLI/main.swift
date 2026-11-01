import AgencilCore
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
// install.sh finds this literal in the binary with `strings` before it replaces or removes the file.
if arguments == ["--identify"] {
    print("agencil-cli: the Agencil command")
    exit(0)
}
exit(CommandLineTool().run(arguments))
