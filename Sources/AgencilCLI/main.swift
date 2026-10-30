import AgencilCore
import Foundation

// The installer recognises its own command by the `agencil:` prefix of the usage error before it replaces or removes the file.
exit(CommandLineTool().run(Array(CommandLine.arguments.dropFirst())))
