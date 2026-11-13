import Foundation

// crewshelf-hook: the plugin's hook client. Reads the hook JSON on stdin, talks to the Crewshelf app over its socket,
// prints a decision only when the user made one, and always exits 0. No app, no socket, any error: no output.

signal(SIGPIPE, SIG_IGN)
let input = FileHandle.standardInput.readDataToEndOfFile()
if let out = runHook(argv: Array(CommandLine.arguments.dropFirst()), stdin: input,
                     env: ProcessInfo.processInfo.environment) {
    FileHandle.standardOutput.write(out)
}
exit(0)
