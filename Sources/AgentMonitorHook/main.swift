// Codex lifecycle hook: reads one JSON event on stdin, writes a state record, prints nothing, exits 0.
import CodexHookKit
import Foundation

CodexHookKit.handle(input: FileHandle.standardInput.readDataToEndOfFile())
exit(0)
