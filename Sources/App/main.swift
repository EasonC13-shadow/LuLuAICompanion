import Cocoa

// MARK: - LuLu Control Functions

func executeLuLuAction(allow: Bool, duration: String?) -> Bool {
    let buttonName = allow ? "Allow" : "Block"
    
    // First, set duration if allowing
    if allow, let dur = duration {
        let durationText = dur.lowercased() == "always" ? "Always" : "Process lifetime"
        
        let durationScript = """
        tell application "System Events"
            tell process "LuLu"
                set frontmost to true
                delay 0.3
                try
                    -- Try clicking radio button directly
                    click radio button "\(durationText)" of window 1
                on error
                    try
                        -- Try in a group
                        click radio button "\(durationText)" of group 1 of window 1
                    end try
                end try
            end tell
        end tell
        """
        
        let durationProcess = Process()
        durationProcess.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        durationProcess.arguments = ["-e", durationScript]
        
        do {
            try durationProcess.run()
            durationProcess.waitUntilExit()
            if durationProcess.terminationStatus != 0 {
                print("Warning: Could not set duration to \(durationText)")
            }
        } catch {
            print("Warning: Error setting duration: \(error)")
        }
        
        // Small delay between actions
        Thread.sleep(forTimeInterval: 0.2)
    }
    
    // Click the Allow/Block button
    let clickScript = """
    tell application "System Events"
        tell process "LuLu"
            set frontmost to true
            delay 0.2
            try
                click button "\(buttonName)" of window 1
                return "ok"
            on error errMsg
                return "error: " & errMsg
            end try
        end tell
    end tell
    """
    
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", clickScript]
    
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    
    do {
        try process.run()
        process.waitUntilExit()
        
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        
        if process.terminationStatus == 0 && output.contains("ok") {
            print("✓ Clicked \(buttonName) on LuLu alert")
            return true
        } else {
            print("✗ Failed to click \(buttonName): \(output)")
            return false
        }
    } catch {
        print("✗ Error: \(error)")
        return false
    }
}

// MARK: - CLI Command Handler

// Handle CLI commands before starting the app
let args = CommandLine.arguments

if args.count > 1 {
    let command = args[1]
    
    switch command {
    case "--add-key", "-a":
        if args.count > 2 {
            let key = args[2]
            if key.hasPrefix("sk-ant-") {
                let slot = ClaudeAPIClient.shared.nextAvailableSlot()
                ClaudeAPIClient.shared.addAPIKey(key, slot: slot)
                print("✓ API key added to slot \(slot)")
                exit(0)
            } else {
                print("✗ Invalid key format. Key should start with 'sk-ant-'")
                exit(1)
            }
        } else {
            print("Usage: LuLuAICompanion --add-key <api-key>")
            exit(1)
        }
        
    case "--remove-key", "-r":
        let slot = args.count > 2 ? Int(args[2]) ?? 0 : 0
        ClaudeAPIClient.shared.removeAPIKey(slot: slot)
        print("✓ API key removed from slot \(slot)")
        exit(0)
        
    case "--list-keys", "-l":
        let keys = ClaudeAPIClient.shared.listKeys()
        if keys.isEmpty || keys.allSatisfy({ !$0.hasKey }) {
            print("No API keys configured")
        } else {
            print("Configured API keys:")
            for (slot, hasKey, prefix) in keys {
                if hasKey {
                    print("  Slot \(slot): \(prefix ?? "***")")
                }
            }
        }
        
        // Also check environment
        if ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] != nil {
            print("  [env] ANTHROPIC_API_KEY is set")
        }
        exit(0)
        
    case "--status", "-s":
        let keyCount = ClaudeAPIClient.shared.apiKeys.count
        print("LuLu AI Companion")
        print("  API keys: \(keyCount)")
        print("  Has key: \(ClaudeAPIClient.shared.hasAPIKey ? "yes" : "no")")
        exit(0)
        
    case "--lulu-allow":
        // Allow the current LuLu alert
        let duration = args.count > 2 ? args[2] : "process"  // "always" or "process"
        let success = executeLuLuAction(allow: true, duration: duration)
        exit(success ? 0 : 1)
        
    case "--lulu-block":
        // Block the current LuLu alert
        let success = executeLuLuAction(allow: false, duration: nil)
        exit(success ? 0 : 1)
        
    case "--help", "-h":
        print("""
        LuLu AI Companion - AI-powered firewall analysis
        
        Usage: LuLuAICompanion [command]
        
        Commands:
          --add-key, -a <key>     Add an API key
          --remove-key, -r [slot] Remove an API key (default slot 0)
          --list-keys, -l         List configured API keys
          --status, -s            Show status
          --lulu-allow [duration] Click Allow on LuLu alert (duration: always|process)
          --lulu-block            Click Block on LuLu alert
          --help, -h              Show this help
        
        Without arguments, starts the menu bar app.
        
        Examples:
          LuLuAICompanion --add-key sk-ant-api03-xxx
          LuLuAICompanion --lulu-allow always
          LuLuAICompanion --lulu-block
        """)
        exit(0)
        
    default:
        print("Unknown command: \(command)")
        print("Use --help for usage information")
        exit(1)
    }
}

// No CLI args - start the app normally
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
