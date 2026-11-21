import Foundation
import DeskCLICore

#if os(macOS)
let ports = SystemPorts.make()
exit(Cli.run(Array(CommandLine.arguments.dropFirst()), ports: ports))
#else
FileHandle.standardError.write(Data("desk runs on macOS only.\n".utf8))
exit(1)
#endif
