import Foundation

/// `Crewshelf --help`. Everything after `--ctl` belongs to `--ctl` (`Crewshelf --ctl` prints its own list).
public let appUsage = """
    usage: Crewshelf                       start the shelf (normally from Finder, or at login)
           Crewshelf --demo                five made-up agents, in their own folder and settings
           Crewshelf --demo --ctl <cmd>    talk to that demo instead of the real app
           Crewshelf --ctl <cmd>           talk to the running app (Crewshelf --ctl lists the commands)
           Crewshelf --dump [--steps N]    print what Crewshelf reads from ~/.claude: real session names, paths and
                                           commands, so read it before you paste it anywhere
           Crewshelf --jump <session>      bring a session's terminal tab to the front (the bubble's Open)
           Crewshelf --done <session>      stop a background agent (claude stop), or hide a tab
           Crewshelf --notify-test         send one test banner
           Crewshelf --remove-login-item   remove this copy's login item (uninstall.sh uses it)
           Crewshelf --help
    """

public enum AppCommand: Equatable {
    case run           // start the app (or a CLI command the app handles)
    case help
    case bad(String)   // an option it doesn't know: print usage, exit 2, start nothing
}

/// Options before `--ctl`. Single-dash words are left alone: macOS and Xcode pass `-NSSomething YES` style
/// arguments to apps, and a launch from Finder must never be refused.
public func parseAppArgs(_ args: [String]) -> AppCommand {
    let flags: Set<String> = ["--demo", "--dump", "--notify-test", "--remove-login-item"]
    let valued: Set<String> = ["--steps", "--jump", "--done"]
    var i = 0
    while i < args.count {
        let a = args[i]
        if a == "--ctl" { return .run }
        if a == "--help" || a == "-h" { return .help }
        if valued.contains(a) { i += 2; continue }
        if a.hasPrefix("--") && !flags.contains(a) { return .bad(a) }
        i += 1
    }
    return .run
}
