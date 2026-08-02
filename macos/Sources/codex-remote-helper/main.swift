import Foundation

FileHandle.standardError.write(Data("codex-remote-helper: command required\n".utf8))
exit(64)
