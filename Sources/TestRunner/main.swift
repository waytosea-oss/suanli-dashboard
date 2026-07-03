import Foundation
import Testing

let exitCode = await Testing.__swiftPMEntryPoint() as CInt
exit(exitCode)
