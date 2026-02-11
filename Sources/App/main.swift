import Cocoa

// Handle CLI commands before starting the app
let args = CommandLine.arguments

if args.count > 1 {
    let command = args[1]
    
    switch command {
    case "--add-key", "-a":
        if args.count > 2 {
            let key = args[2]
            if AIProvider.isValidKey(key) {
                let slot = ClaudeAPIClient.shared.nextAvailableSlot()
                ClaudeAPIClient.shared.addAPIKey(key, slot: slot)
                print("✓ API key added to slot \(slot)")
                exit(0)
            } else {
                print("✗ Invalid key format. Supported: sk-ant- (Anthropic), sk- (OpenAI), AIza (Gemini), sk-3mate- (3mate)")
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
            for keyInfo in keys {
                if keyInfo.hasKey {
                    print("  Slot \(keyInfo.slot): \(keyInfo.prefix ?? "***") [\(keyInfo.provider?.rawValue ?? "unknown")]")
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
        
    case "--help", "-h":
        print("""
        LuLu AI Companion - AI-powered firewall analysis
        
        Usage: LuLuAICompanion [command]
        
        Commands:
          --add-key, -a <key>     Add an API key
          --remove-key, -r [slot] Remove an API key (default slot 0)
          --list-keys, -l         List configured API keys
          --status, -s            Show status
          --help, -h              Show this help
        
        Without arguments, starts the menu bar app.
        
        Examples:
          LuLuAICompanion --add-key sk-ant-api03-xxx
          LuLuAICompanion --list-keys
        """)
        exit(0)
        
    default:
        print("Unknown command: \(command)")
        print("Use --help for usage information")
        exit(1)
    }
}

// No CLI args - start the app normally
// Use NSApplicationMain for proper lifecycle management
// AppDelegate is set via Info.plist NSPrincipalClass
let app = NSApplication.shared
let delegate = AppDelegate()
// Store delegate as associated object to prevent deallocation (NSApp.delegate is weak)
objc_setAssociatedObject(app, "appDelegate", delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
app.delegate = delegate
app.run()
