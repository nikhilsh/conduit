# apps/ios — Conduit iOS app

Native SwiftUI app for the Conduit harness. Connects to the Go broker over
WebSocket, drives Claude/Codex agent sessions, and renders streaming chat,
terminal, and browser views with full tablet and phone layouts.

## Layout

```
apps/ios/
├── project.yml                    xcodegen spec — generates Conduit.xcodeproj
├── build-rust.sh                  builds ConduitCore.xcframework from ../../core/
├── Sources/
│   ├── ConduitApp.swift           @main entry point
│   ├── AppDelegate.swift          UIApplicationDelegate (push, lifecycle)
│   ├── SessionStore.swift         @Observable central state — boxes, sessions, WS client
│   ├── SlashCommandRegistry.swift /command definitions and dispatch
│   ├── Telemetry.swift            Sentry breadcrumb/capture helpers
│   ├── Models/                    non-UI state and coordinators
│   │   ├── AgentLoginCoordinator.swift   OAuth login flow orchestration
│   │   ├── AgentLoginLoopbackServer.swift loopback HTTP server for OAuth redirect
│   │   ├── AgentAccountStatus.swift      account/subscription state model
│   │   ├── AppearanceStore.swift         theme/font/appearance persistence
│   │   ├── ApproveSessionIntent.swift    App Intent for notification approvals
│   │   ├── BuildInfo.swift               version + git SHA at runtime
│   │   ├── ChatAutoScrollController.swift scroll-to-bottom controller
│   │   ├── DeviceIdentity.swift          stable device ID
│   │   ├── FeatureFlags.swift            runtime feature flag store
│   │   ├── Keychain.swift                Keychain read/write helpers
│   │   ├── MessageRenderCache.swift      parsed markdown result cache
│   │   ├── NetworkReachabilityObserver.swift NWPathMonitor wrapper
│   │   ├── OAuthClient.swift             PKCE OAuth client (Claude/Codex)
│   │   ├── PendingChatQueue.swift        durable outbound message queue
│   │   ├── PushNotificationManager.swift APNs token registration + routing
│   │   ├── ReplyHaptics.swift            haptic feedback on agent reply
│   │   ├── SavedSessionsStore.swift      local session list persistence
│   │   ├── SshCredentialStore.swift      SSH key/credential keychain store
│   │   ├── StreamingRendererCoordinator.swift incremental markdown render pipeline
│   │   ├── SyntaxHighlightCache.swift    code-block highlight cache
│   │   ├── TurnActivityAttributes.swift  Live Activity attribute types
│   │   ├── TurnActivityModel.swift       Live Activity state model
│   │   ├── TurnLiveActivityBridge.swift  broker → Live Activity event bridge
│   │   └── TurnLiveActivityController.swift ActivityKit start/update/end
│   ├── Theme/                     app-level design tokens
│   │   ├── Theme.swift            root theme environment object
│   │   ├── NeonTheme.swift        Neon dark-mode palette
│   │   ├── NeonChrome.swift       chrome/border accents
│   │   ├── NeonComponents.swift   shared Neon-themed component styles
│   │   ├── Palette.swift          semantic color tokens
│   │   ├── Typography.swift       font scale definitions
│   │   ├── Background.swift       layered background modifiers
│   │   ├── Glass.swift            frosted-glass effect helpers
│   │   └── AppearanceColorScheme.swift  dark/light/auto scheme binding
│   ├── Shared/                    reusable views used across screens
│   │   ├── BrowserTab.swift       WKWebView browser surface
│   │   ├── GhosttyTerminalView.swift    Ghostty-backed terminal SwiftUI view
│   │   ├── LANDiscoveryBrowser.swift    Bonjour-based broker discovery
│   │   ├── PairingURL.swift        QR/deep-link pairing URL parser
│   │   ├── QRScannerSheet.swift    camera QR scanner sheet
│   │   ├── SSHLoginSheet.swift     SSH host + credential entry sheet
│   │   ├── SavedTranscriptView.swift    read-only transcript viewer
│   │   ├── ServerPill.swift        connection-status pill badge
│   │   ├── ServerPillRow.swift     pill row for server list cells
│   │   ├── SessionNaming.swift     auto-name generation helpers
│   │   ├── SessionSearchView.swift full-text session search UI
│   │   ├── SessionsScreen.swift    session list screen (phone primary)
│   │   ├── SyntaxHighlighting.swift  Highlight.js-based code renderer
│   │   ├── TerminalAccessoryBar.swift  keyboard accessory bar for terminal input
│   │   ├── RenameSessionValidator.swift name validation rules
│   │   ├── AgentAvatar.swift       per-agent icon/color avatar
│   │   ├── AnimatedSplashView.swift    animated launch splash
│   │   ├── DesignSystem.swift      shared layout constants
│   │   └── VoiceDictationSheet.swift   voice-to-text dictation sheet
│   ├── Voice/
│   │   └── VoiceTranscriber.swift  SFSpeechRecognizer streaming transcription
│   └── ConduitUI/                 screen-level UI module
│       ├── ConduitUI.swift         module entry / public surface
│       ├── Views/                  full screens and sheets
│       │   ├── ConduitRootView.swift          navigation root (phone + tablet)
│       │   ├── ConduitHomeView.swift           home session list (phone)
│       │   ├── ConduitTabletHome.swift         two-column tablet home
│       │   ├── ConduitTabletActivityBar.swift  tablet right-edge activity bar
│       │   ├── ConduitTabletRightPane.swift    tablet detail pane
│       │   ├── ConduitSessionsRail.swift       sidebar sessions rail
│       │   ├── ConduitChatView.swift           streaming chat conversation view
│       │   ├── ConduitSettingsView.swift       settings (servers, appearance, etc.)
│       │   ├── ConduitAddServerSheet.swift     add/edit server sheet
│       │   ├── ConduitAgentPickerSheet.swift   agent + model selector sheet
│       │   ├── ConduitAgentLoginSheet.swift    in-app OAuth login sheet
│       │   ├── ConduitAppearanceSheet.swift    theme/font appearance controls
│       │   ├── ConduitOnboardingView.swift     first-launch onboarding flow
│       │   ├── ConduitProjectView.swift        per-project session list
│       │   ├── ConduitDiscoveryView.swift      LAN broker discovery screen
│       │   ├── ConduitFoundSessionsSheet.swift found external sessions list
│       │   ├── ConduitFoundWatchView.swift     watch-mode for discovered sessions
│       │   ├── ConduitForkSheet.swift          branch-a-copy session fork sheet
│       │   ├── ConduitFanOutView.swift         fan-out multi-session view
│       │   ├── ConduitDiffReviewView.swift     git diff review surface
│       │   ├── ConduitApprovalsView.swift      pending tool-call approvals
│       │   ├── ConduitSessionInfoView.swift    session metadata/info panel
│       │   ├── ConduitSessionRecapView.swift   session recap/summary view
│       │   ├── ConduitBoxHealthView.swift      broker/box health diagnostics
│       │   ├── ConduitCommandPalette.swift     slash-command palette overlay
│       │   ├── ConduitComposerAttachSheet.swift file/image attachment picker
│       │   ├── ConduitRenameSessionSheet.swift rename session sheet
│       │   ├── ConduitConnectionHealthViews.swift connection state banners
│       │   ├── ConduitNeonAppearanceControls.swift Neon theme tweaker
│       │   ├── ConduitUsageCard.swift          usage stats card
│       │   ├── ConduitAccountUsageCard.swift   account-level usage card
│       │   ├── ConduitUsageSurfaces.swift      usage surface composites
│       │   ├── ConduitOutcomeChips.swift       session-outcome chip badges
│       │   ├── ConduitDebugMenuView.swift      developer debug panel
│       │   ├── ConduitEmptyDetail.swift        placeholder for empty detail pane
│       │   └── ConduitLicensesView.swift       third-party licenses screen
│       ├── Models/                 view-scoped observable models
│       │   ├── ConduitChatViewModel.swift      streaming message ingest + display state
│       │   ├── ConduitComposerAttachment.swift attachment model
│       │   ├── ConduitConversationRenderer.swift full conversation render pipeline
│       │   ├── ConduitDiffReviewModel.swift    diff review state
│       │   ├── ConduitFoundSessionsModel.swift external-session discovery model
│       │   ├── ConduitHomeViewModel.swift      home screen session/filter model
│       │   ├── ConduitSessionInfoViewModel.swift session info fetch/display model
│       │   └── ConduitTranscriptExport.swift   transcript share/export helper
│       ├── Theme/                  ConduitUI design tokens
│       │   ├── ConduitPalette.swift        palette tokens
│       │   ├── ConduitTypography.swift     typography scale
│       │   ├── ConduitGlass.swift          glass-effect modifiers
│       │   ├── ConduitMarkdownHeadingScaler.swift  heading-size scaler
│       │   └── ConduitNeonAccentModifiers.swift    Neon accent view modifiers
│       └── Components/            small reusable UI atoms
│           ├── AnimatedBrandMark.swift
│           ├── ConduitCard.swift
│           ├── ConduitChip.swift
│           ├── ConduitHeader.swift
│           ├── ConduitListRow.swift
│           ├── ConduitMark.swift
│           ├── ConduitPillButton.swift
│           └── ConduitSwipeBack.swift
├── Widgets/                       WidgetKit / Live Activity extension
│   ├── ConduitWidgetsBundle.swift  widget bundle entry
│   └── TurnLiveActivity.swift      agent-turn Live Activity widget
├── GhosttyVT/                     local Swift package — Ghostty terminal bindings
│   └── Sources/GhosttyVT/
│       ├── Ghostty.App.swift      Ghostty app lifecycle wrapper
│       ├── Ghostty.Surface.swift  terminal surface SwiftUI bridge
│       ├── GhosttyTheme.swift     theme → Ghostty config mapping
│       ├── GhosttyFont.swift      font selection helpers
│       └── QueryResponseFilter.swift  VT response-query filter
├── Tests/ConduitTests/            unit test suite (70+ files)
│   ├── ConduitUI/                 ConduitUI model tests
│   └── *.swift                    model, store, and protocol tests
└── ConduitCore/                   populated by build-rust.sh (gitignored)
```

## Build

**There is no local Xcode on the development box. All iOS verification is CI-only.**

CI runs `xcodebuild test` of `ConduitTests` on `macos-15` using the
`iPhone 16` simulator. A green CI build means the code compiles and unit tests
pass — it does not mean the UI has been verified on a device. Any UI/layout
fix must be flagged as "needs on-device verification".

The Rust core bindings are compiled by `build-rust.sh` before xcodegen
generates `Conduit.xcodeproj`. The Ghostty terminal xcframework is fetched
by `scripts/fetch-ghostty-kit-xcframework.sh` (see CI workflow for the pinned
version; upstream 404s are a known flake — rerun, do not fix).

## Further reading

- `docs/ARCHITECTURE.md` — system overview (broker, core, apps)
- `docs/WEBSOCKET-PROTOCOL.md` — broker WebSocket message wire format
- `docs/ROADMAP.md` — feature backlog and in-progress work
