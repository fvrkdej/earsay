// Send the running Earsay app a message.
//   swift tools/send.swift read /path/to/file.md
//   swift tools/send.swift stop
import Foundation
let args = CommandLine.arguments
let center = DistributedNotificationCenter.default()
if args.count > 2, args[1] == "read" {
    let path = URL(fileURLWithPath: args[2]).standardizedFileURL.path
    center.postNotificationName(.init("io.autimized.readaloud.readfile"), object: path, userInfo: nil, deliverImmediately: true)
} else {
    center.postNotificationName(.init("io.autimized.readaloud.stop"), object: nil, userInfo: nil, deliverImmediately: true)
}
