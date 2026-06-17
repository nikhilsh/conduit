# apps/android — Conduit Android app

Native Jetpack Compose app for the Conduit harness. Connects to the Go broker
over WebSocket, drives Claude/Codex agent sessions, and renders streaming chat,
terminal, and browser views with full tablet and phone layouts.

## Layout

```
apps/android/
├── settings.gradle.kts
├── build.gradle.kts
├── gradle.properties
├── gradle/                        Gradle wrapper
├── gradlew, gradlew.bat
├── build-rust.sh                  compiles core/ for the 4 Android ABIs
└── app/src/main/
    ├── AndroidManifest.xml
    ├── assets/                    bundled assets (fonts, etc.)
    ├── res/                       launcher icons, strings, themes
    └── kotlin/sh/nikhil/conduit/
        ├── MainActivity.kt        single-activity entry point
        ├── SessionStore.kt        central ViewModel — boxes, sessions, WS client
        ├── AgentModelCatalog.kt   live model + effort catalog (from broker)
        ├── AppearanceStore.kt     theme/font/appearance persistence
        ├── ConnectionHealth.kt    WS connection health state model
        ├── FeatureFlags.kt        runtime feature flag store
        ├── PairingURL.kt          QR/deep-link pairing URL parser
        ├── PendingChatQueue.kt    durable outbound message queue
        ├── SavedSessionsStore.kt  local session list persistence
        ├── SessionNaming.kt       auto-name generation helpers
        ├── SshCredentialStore.kt  SSH credential secure store
        ├── Telemetry.kt           Sentry breadcrumb/capture helpers
        ├── TerminalScrollbackCache.kt  terminal scrollback persistence
        ├── auth/                  OAuth + agent credential flows
        │   ├── AgentAccountStatus.kt         account/subscription state model
        │   ├── AgentCredentialEnvelope.kt    per-box credential envelope
        │   ├── AgentLoginCoordinator.kt      OAuth login flow orchestration
        │   ├── AgentLoginLoopbackServer.kt   loopback HTTP server for OAuth redirect
        │   ├── OAuthClient.kt                PKCE OAuth client (Claude/Codex)
        │   ├── OAuthStore.kt                 token persistence
        │   └── SessionStoreAgentLoginTransport.kt  login → session store bridge
        ├── push/                  push notification providers
        │   ├── PushProvider.kt               provider interface
        │   ├── PushProviders.kt              provider registry
        │   ├── PushStore.kt                  registration token store
        │   ├── PushSettingsSection.kt        push settings UI section
        │   ├── ConduitFcmService.kt          FCM receiver service
        │   ├── FcmPushProvider.kt            FCM push provider
        │   ├── ConduitUnifiedPushReceiver.kt UnifiedPush receiver
        │   ├── UnifiedPushProvider.kt        UnifiedPush provider
        │   └── ApprovalActionReceiver.kt     notification action handler
        ├── state/
        │   └── NetworkReachabilityObserver.kt  network path change observer
        ├── voice/
        │   └── VoiceTranscriber.kt           SpeechRecognizer streaming transcription
        ├── widget/                agent-turn dynamic widget / notification
        │   ├── TurnActivityBridgeCore.kt     broker event → widget bridge
        │   ├── TurnActivityController.kt     widget start/update/end lifecycle
        │   └── TurnActivityModel.kt          widget state model
        └── ui/                    all screens and shared UI
            ├── AppRoot.kt                    navigation root (phone + tablet)
            ├── HomeScreen.kt                 home session list (phone)
            ├── NeonTabletHome.kt             two-column tablet home
            ├── NeonTabletActivityBar.kt      tablet right-edge activity bar
            ├── NeonTabletRail.kt             tablet sessions rail
            ├── NeonTabletRightPane.kt        tablet detail pane
            ├── ChatPage.kt                   streaming chat conversation view
            ├── SettingsScreen.kt             settings (servers, appearance, etc.)
            ├── AddServerSheet.kt             add/edit server sheet
            ├── AgentPickerSheet.kt           agent + model selector sheet
            ├── AgentLoginSheet.kt            in-app OAuth login sheet
            ├── AppearanceSheet.kt            theme/font appearance controls
            ├── OnboardingScreen.kt           first-launch onboarding flow
            ├── ProjectListScreen.kt          project list screen
            ├── ProjectScreen.kt              per-project session list
            ├── DiscoveryScreen.kt            LAN broker discovery screen
            ├── FoundSessionsSheet.kt         found external sessions list
            ├── FoundSessionsModel.kt         external-session discovery model
            ├── ThreadSwitcherSheet.kt        branch-a-copy / thread switcher
            ├── FanOutScreen.kt               fan-out multi-session view
            ├── DiffReviewScreen.kt           git diff review surface
            ├── ApprovalsScreen.kt            pending tool-call approvals
            ├── SessionInfoScreen.kt          session metadata/info panel
            ├── SessionRecapScreen.kt         session recap/summary view
            ├── BoxHealthScreen.kt            broker/box health diagnostics
            ├── CommandPaletteScreen.kt       slash-command palette overlay
            ├── ComposerAttachSheet.kt        file/image attachment picker
            ├── HistoryScreen.kt              session history list
            ├── SessionSearchScreen.kt        full-text session search
            ├── SavedTranscriptScreen.kt      read-only transcript viewer
            ├── SSHLoginSheet.kt              SSH host + credential entry sheet
            ├── QRScannerSheet.kt             camera QR scanner sheet
            ├── HostKeyPromptDialog.kt        SSH TOFU host-key prompt
            ├── VoiceDictationScreen.kt       voice-to-text dictation screen
            ├── BrowserPage.kt                WebView browser surface
            ├── TermuxTerminalView.kt         Termux-based terminal surface
            ├── WebTerminal.kt                web-based terminal fallback
            ├── TerminalAccessoryBar.kt       keyboard accessory bar for terminal
            ├── TerminalPalette.kt            terminal color palette
            ├── InSessionBottomBar.kt         in-session bottom navigation bar
            ├── InlineVoiceButton.kt          inline voice input button
            ├── ExpandedComposerView.kt       full-screen composer expansion
            ├── PendingQuestions.kt           pending agent question cards
            ├── NeonTheme.kt                  Neon dark-mode design system
            ├── Theme.kt                      base Material3 theme wrapper
            ├── NeonComponents.kt             shared Neon-themed components
            ├── NeonOutcomeChips.kt           session-outcome chip badges
            ├── NeonUsageCard.kt              usage stats card
            ├── NeonAccountUsageCard.kt       account-level usage card
            ├── NeonUsageSurfaces.kt          usage surface composites
            ├── NeonAppearanceControls.kt     appearance tweaker controls
            ├── AgentAccent.kt                per-agent accent color logic
            ├── AgentAvatar.kt                per-agent icon/color avatar
            ├── AnimatedBrandMark.kt          animated logo component
            ├── AnimatedSplash.kt             animated launch splash
            ├── Background.kt                 layered background composables
            ├── Glass.kt                      frosted-glass effect helpers
            ├── ConduitMark.kt                Conduit logo mark component
            ├── ConduitMarkdownBlocks.kt      Markdown block renderers
            ├── ConduitMarkdownHeadingScaler.kt  heading-size scaler
            ├── SyntaxHighlighting.kt         code-block highlight renderer
            ├── ServerPill.kt                 connection-status pill badge
            ├── ServerPillRow.kt              pill row for server list cells
            ├── ConnectionHealthViews.kt      connection state banners
            ├── ContextBar.kt                 in-session context bar
            ├── ContextChip.kt                context chip badge
            ├── ViewerCountBadge.kt           viewer-count overlay badge
            ├── SlashCommandRegistry.kt       /command definitions and dispatch
            ├── ChatAutoScrollModel.kt        scroll-to-bottom controller
            ├── ParsedMarkdownCache.kt        parsed Markdown result cache
            ├── ReplyHapticsModel.kt          haptic feedback on agent reply
            ├── TypingIndicatorModel.kt       typing indicator state
            ├── DebugMenuScreen.kt            developer debug panel
            ├── EmptyDetail.kt                placeholder for empty detail pane
            ├── LicensesScreen.kt             third-party licenses screen
            ├── QrImageDecoder.kt             QR image decode helper
            └── WebTerminal.kt                web terminal surface
```

## Build

**Android builds require the Android SDK, NDK, and generated UniFFI bindings —
none of which are available on the development box. All Android verification is
CI-only.**

CI runs `./gradlew :app:testDebugUnitTest` on `ubuntu-24.04`. A green CI build
means the code compiles and JVM unit tests pass — it does not mean the UI has
been verified on a device. Any UI/layout fix must be flagged as
"needs on-device verification".

The Rust core bindings are compiled by `build-rust.sh` for the four Android
ABIs before the Gradle build. UniFFI binding generation is handled by CI; if
you regenerate them locally, always use `make bindings` and sync all four
generated artifacts to avoid checksum mismatches at runtime.

## Further reading

- `docs/ARCHITECTURE.md` — system overview (broker, core, apps)
- `docs/WEBSOCKET-PROTOCOL.md` — broker WebSocket message wire format
- `docs/ROADMAP.md` — feature backlog and in-progress work
