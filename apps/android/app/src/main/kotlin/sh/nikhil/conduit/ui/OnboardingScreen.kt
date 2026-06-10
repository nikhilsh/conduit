package sh.nikhil.conduit.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import sh.nikhil.conduit.AppearanceStore
import sh.nikhil.conduit.FeatureFlags
import sh.nikhil.conduit.LocalAppearanceStore
import sh.nikhil.conduit.SessionStore
import sh.nikhil.conduit.Telemetry

// ---------------------------------------------------------------------------
// Onboarding funnel breadcrumb step name constants.
// Must mirror iOS OnboardingStep exactly so Sentry funnels line up.
// ---------------------------------------------------------------------------
object OnboardingStep {
    const val SCREEN_SHOWN          = "screen_shown"
    const val WELCOME_SHOWN         = "welcome_shown"
    const val INSTALL_SHOWN         = "install_shown"
    const val PAIR_SHOWN            = "pair_shown"
    const val PAIR_QR_STARTED       = "pair_qr_started"
    const val PAIR_SSH_STARTED      = "pair_ssh_started"
    const val PAIR_MANUAL_STARTED   = "pair_manual_started"
    const val PAIR_DISCOVER_STARTED = "pair_discover_started"
    const val PAIRING_SUCCEEDED     = "pairing_succeeded"
    const val CAPABILITIES_FETCHED  = "capabilities_fetched"
    const val AGENT_PICKER_OPENED   = "agent_picker_opened"
    const val FIRST_SESSION_CREATED = "first_session_created"
    const val FIRST_TURN_SENT       = "first_turn_sent"
    const val FIRST_REPLY_RECEIVED  = "first_reply_received"
    const val DONE_SHOWN            = "done_shown"
}

/**
 * First-run onboarding (handoff §5 / onb-flow.jsx): Welcome → Install → Pair.
 * **Accounts-free** — there is no sign-in; trust is the device↔broker pairing
 * handshake. Gated by [AppRoot]'s onboarding route (shown only when this
 * device holds no pairing key). Pairing reuses [AddServerSheet]; the moment a
 * broker is paired the route flips to None and this overlay disappears into
 * Home. `seenWelcome` + furthest-step persist for resume.
 */
@Composable
fun OnboardingScreen(store: SessionStore, onFinish: () -> Unit) {
    val neon = LocalNeonTheme.current
    val appearance = LocalAppearanceStore.current

    val seenWelcome by appearance.onboardingSeenWelcome.collectAsState()
    val furthest by appearance.onboardingFurthestStep.collectAsState()
    val guide by appearance.onboardingGuide.collectAsState()

    var step by remember {
        mutableStateOf(
            FeatureFlags.onboardingInitialStep(
                route = FeatureFlags.OnboardingRoute.Full,
                seenWelcome = seenWelcome,
                furthestStep = furthest,
            ).also { if (it == FeatureFlags.Step.WELCOME) appearance.setOnboardingSeenWelcome(true) },
        )
    }
    var showAddServer by remember { mutableStateOf(false) }

    // Funnel: screen shown on first composition.
    LaunchedEffect(Unit) {
        Telemetry.breadcrumb("onboarding", OnboardingStep.SCREEN_SHOWN,
            mapOf("step" to step.toString(), "route" to "full"))
    }

    fun go(target: Int) {
        step = target
        appearance.setOnboardingFurthestStep(maxOf(furthest, target))
        if (target == FeatureFlags.Step.WELCOME) appearance.setOnboardingSeenWelcome(true)
        // Funnel: step transition.
        val stepName = when (target) {
            FeatureFlags.Step.WELCOME -> OnboardingStep.WELCOME_SHOWN
            FeatureFlags.Step.INSTALL -> OnboardingStep.INSTALL_SHOWN
            FeatureFlags.Step.PAIR    -> OnboardingStep.PAIR_SHOWN
            FeatureFlags.Step.DONE    -> OnboardingStep.DONE_SHOWN
            else                      -> "step_$target"
        }
        Telemetry.breadcrumb("onboarding", stepName)
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(neon.appBg),
    ) {
        Column(modifier = Modifier.fillMaxSize()) {
            OnbTopBar(neon = neon, step = step, guide = guide,
                onBack = { if (step in 1..2) go(step - 1) },
                onGuide = { appearance.setOnboardingGuide(it) })
            if (step < FeatureFlags.Step.DONE) OnbProgress(neon, step)

            when (step) {
                FeatureFlags.Step.WELCOME -> OnbWelcome(neon, onPair = { go(FeatureFlags.Step.INSTALL) }, onCode = { go(FeatureFlags.Step.PAIR) })
                FeatureFlags.Step.INSTALL -> OnbInstall(neon, guide, onNext = { go(FeatureFlags.Step.PAIR) })
                else -> OnbPair(neon, guide, onPair = {
                    // Each specific transport method logs its own crumb
                    // inside AddServerSheet (QR/SSH/LAN/manual). No coarse
                    // crumb here to avoid a misleading label.
                    showAddServer = true
                })
            }
        }
    }

    if (showAddServer) {
        // Reuse the existing pairing entry points (QR / discover / SSH /
        // manual). On success the saved-servers list grows → AppRoot's route
        // flips to None and this overlay is removed.
        AddServerSheet(store = store, onDismiss = { showAddServer = false })
    }
}

private val onbGrad: @Composable (NeonTheme) -> Brush = { neon ->
    Brush.horizontalGradient(listOf(neon.codex, neon.green))
}

@Composable
private fun OnbTopBar(neon: NeonTheme, step: Int, guide: Boolean, onBack: () -> Unit, onGuide: (Boolean) -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (step in 1..2) {
            Box(
                modifier = Modifier.size(34.dp).clip(CircleShape)
                    .background(neon.surface).border(1.dp, neon.border, CircleShape)
                    .clickable(onClick = onBack),
                contentAlignment = Alignment.Center,
            ) { Text("‹", color = neon.textDim, fontFamily = neon.mono, fontSize = 18.sp) }
        } else {
            Spacer(Modifier.size(34.dp))
        }
        Spacer(Modifier.weight(1f))
        if (step < FeatureFlags.Step.DONE) {
            Row(
                modifier = Modifier.clip(RoundedCornerShape(99.dp)).background(neon.surface)
                    .border(1.dp, neon.border, RoundedCornerShape(99.dp)).padding(4.dp),
                horizontalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                listOf(true to "Guide me", false to "I know my way").forEach { (isGuide, label) ->
                    val on = guide == isGuide
                    Text(
                        label,
                        fontFamily = neon.mono, fontSize = 11.5.sp, fontWeight = FontWeight.Bold,
                        color = if (on) neon.text else neon.textFaint,
                        modifier = Modifier.clip(RoundedCornerShape(99.dp))
                            .background(if (on) neon.surface2 else Color.Transparent)
                            .clickable { onGuide(isGuide) }
                            .padding(horizontal = 12.dp, vertical = 6.dp),
                    )
                }
            }
        }
        Spacer(Modifier.weight(1f))
        Spacer(Modifier.size(34.dp))
    }
}

@Composable
private fun OnbProgress(neon: NeonTheme, step: Int) {
    val labels = listOf("Welcome", "Install", "Pair")
    val current = minOf(step, FeatureFlags.Step.PAIR)
    Row(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 22.dp, vertical = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(7.dp),
    ) {
        labels.forEachIndexed { i, label ->
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Box(
                    modifier = Modifier.fillMaxWidth().height(3.dp).clip(RoundedCornerShape(99.dp))
                        .then(if (i <= current) Modifier.background(onbGrad(neon)) else Modifier.background(neon.border)),
                )
                Text(
                    "${i + 1} $label",
                    fontFamily = neon.mono, fontSize = 10.sp,
                    color = if (i == current) neon.codex else if (i < current) neon.textDim else neon.textFaint,
                )
            }
        }
    }
}

@Composable
private fun OnbWelcome(neon: NeonTheme, onPair: () -> Unit, onCode: () -> Unit) {
    Column(
        modifier = Modifier.fillMaxSize().padding(horizontal = 28.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        ConduitMark(size = 62.dp)
        Spacer(Modifier.height(20.dp))
        Text(
            ">conduit",
            fontFamily = neon.mono, fontWeight = FontWeight.ExtraBold, fontSize = 30.sp, color = neon.text,
        )
        Spacer(Modifier.height(10.dp))
        Text("Your agents, in your pocket.", fontFamily = neon.sans, fontSize = 20.sp, color = neon.textDim)
        Spacer(Modifier.height(24.dp))
        Text(
            "Pair a machine, start a session, and drive Claude or Codex from anywhere.",
            fontFamily = neon.sans, fontSize = 16.sp, color = neon.textDim,
        )
        Spacer(Modifier.height(28.dp))
        OnbPrimary(neon, "Pair a machine", onPair)
        Spacer(Modifier.height(11.dp))
        Text(
            "Already running a broker?  Enter a code →",
            fontFamily = neon.mono, fontSize = 13.sp, color = neon.codex,
            modifier = Modifier.clickable(onClick = onCode).padding(6.dp),
        )
    }
}

@Composable
private fun OnbInstall(neon: NeonTheme, guide: Boolean, onNext: () -> Unit) {
    var platform by remember { mutableStateOf(0) }
    val clipboard = LocalClipboardManager.current
    val platforms = listOf(
        Triple("macOS", "your laptop", "curl -fsSL https://conduit.sh | sh"),
        Triple("Linux", "a dev box", "curl -fsSL https://conduit.sh | sh"),
        Triple("Cloud VPS", "rented server", "ssh root@your-vps \"curl -fsSL https://conduit.sh | sh\""),
    )
    val cmd = platforms[platform].third
    Column(
        modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 24.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        OnbEyebrow(neon, "STEP 2 · THE BROKER", neon.codex)
        Text("Run the broker on your machine", fontFamily = neon.sans, fontWeight = FontWeight.SemiBold, fontSize = 26.sp, color = neon.text)
        if (guide) {
            OnbHelper(neon, neon.codex, "The broker is a tiny program that runs on the computer your code lives on — your Mac, a dev box, or a cloud VPS. Conduit talks to it so your agents run on your hardware.")
        }
        Text("WHERE WILL IT RUN?", fontFamily = neon.mono, fontSize = 11.sp, color = neon.textFaint)
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            platforms.forEachIndexed { i, p ->
                val on = i == platform
                Column(
                    modifier = Modifier.weight(1f).clip(RoundedCornerShape(12.dp))
                        .background(if (on) neon.codex.copy(alpha = 0.10f) else neon.surface)
                        .border(1.dp, if (on) neon.codex.copy(alpha = 0.5f) else neon.border, RoundedCornerShape(12.dp))
                        .clickable { platform = i }.padding(horizontal = 10.dp, vertical = 11.dp),
                ) {
                    Text(p.first, fontFamily = neon.mono, fontWeight = FontWeight.Bold, fontSize = 13.5.sp, color = if (on) neon.codex else neon.text)
                    Text(p.second, fontFamily = neon.mono, fontSize = 10.5.sp, color = neon.textFaint)
                }
            }
        }
        Text("PASTE THIS INTO ITS TERMINAL", fontFamily = neon.mono, fontSize = 11.sp, color = neon.textFaint)
        Column(
            modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp))
                .background(neon.codeBg).border(1.dp, neon.border, RoundedCornerShape(12.dp)),
        ) {
            Row(modifier = Modifier.padding(14.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Text("$", fontFamily = neon.mono, fontSize = 12.7.sp, color = neon.green)
                Text(cmd, fontFamily = neon.mono, fontSize = 12.7.sp, color = neon.text)
            }
            Box(
                modifier = Modifier.fillMaxWidth().border(0.dp, Color.Transparent)
                    .clickable { clipboard.setText(AnnotatedString(cmd)) }
                    .padding(vertical = 10.dp),
                contentAlignment = Alignment.Center,
            ) { Text("Copy command", fontFamily = neon.mono, fontWeight = FontWeight.Bold, fontSize = 12.5.sp, color = neon.codex) }
        }
        if (guide) {
            Text("No machine yet?  Spin up a \$5 VPS →", fontFamily = neon.mono, fontSize = 12.5.sp, color = neon.textFaint)
        }
        OnbPrimary(neon, "I ran it — find my broker", onNext)
        Spacer(Modifier.height(8.dp))
    }
}

@Composable
private fun OnbPair(neon: NeonTheme, guide: Boolean, onPair: () -> Unit) {
    Column(
        modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 24.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        OnbEyebrow(neon, "STEP 3 · PAIR", neon.green)
        Text("Pair this phone", fontFamily = neon.sans, fontWeight = FontWeight.SemiBold, fontSize = 26.sp, color = neon.text)
        if (guide) {
            OnbHelper(neon, neon.green, "When the broker starts it prints a pairing QR and a ws:// URL + token. Scan the QR, or paste the URL — that proves the phone and the machine are yours. No account, no password.")
        }
        OnbPrimary(neon, "Scan or enter a pairing code", onPair)
    }
}

@Composable
private fun OnbPrimary(neon: NeonTheme, label: String, onClick: () -> Unit) {
    Box(
        modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp))
            .background(onbGrad(neon)).clickable(onClick = onClick).padding(vertical = 15.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(label, fontFamily = neon.mono, fontWeight = FontWeight.Bold, fontSize = 15.5.sp, color = neon.accentText)
    }
}

@Composable
private fun OnbEyebrow(neon: NeonTheme, text: String, tint: Color) {
    Text(text, fontFamily = neon.mono, fontWeight = FontWeight.Bold, fontSize = 12.sp, color = tint)
}

@Composable
private fun OnbHelper(neon: NeonTheme, tint: Color, text: String) {
    Box(
        modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp))
            .background(tint.copy(alpha = 0.06f)).border(1.dp, tint.copy(alpha = 0.18f), RoundedCornerShape(12.dp))
            .padding(horizontal = 14.dp, vertical = 12.dp),
    ) {
        Text(text, fontFamily = neon.sans, fontSize = 15.sp, color = neon.textDim)
    }
}
