// screens.jsx — core screens: Home, Chat, Terminal, Browser.
// Each takes { t, platform } and fills a device content area.

const K = window; // kit exports live on window

function topPad(p) { return p === 'ios' ? 54 : 8; }
function botPad(p) { return p === 'ios' ? 28 : 12; }

function Screen({ t, children }) {
  return <div style={{ height: '100%', display: 'flex', flexDirection: 'column', background: t.appBg,
    color: t.text, fontFamily: t.font, position: 'relative', overflow: 'hidden' }}>{children}</div>;
}

// generic top app bar for non-chat screens
function AppBar({ t, platform, leading, center, trailing }) {
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 10, padding: `${topPad(platform)}px 14px 10px` }}>
      <div style={{ width: 40, display: 'flex', justifyContent: 'flex-start' }}>{leading}</div>
      <div style={{ flex: 1, display: 'flex', justifyContent: 'center' }}>{center}</div>
      <div style={{ width: 40, display: 'flex', justifyContent: 'flex-end' }}>{trailing}</div>
    </div>
  );
}

// ── HOME / SESSIONS ───────────────────────────────────────────
function SessionRow({ t, name, repo, branch, agent, preview, status, time }) {
  const c = K.agentColor(t, agent);
  const sc = status === 'live' ? t.green : status === 'paused' ? t.claude : t.textFaint;
  return (
    <div style={{ display: 'flex', gap: 12, padding: '12px 13px', alignItems: 'flex-start',
      background: t.surface, borderRadius: t.radius - 4, border: `1px solid ${t.border}`,
      boxShadow: t.glow ? K.glowBox(t, c, 0.18) : 'none' }}>
      <div style={{ width: 38, height: 38, borderRadius: 10, flexShrink: 0, display: 'flex', alignItems: 'center', justifyContent: 'center',
        background: `${c}1c`, border: `1px solid ${c}40`, boxShadow: t.glow ? `0 0 10px ${c}30` : 'none' }}>
        <K.ConduitMark t={t} size={22} color={c} />
      </div>
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 7 }}>
          <span style={{ fontFamily: t.font, fontSize: 14.5, fontWeight: 650, color: t.text, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis', flex: 1 }}>{name}</span>
          <K.Dot color={sc} glow={t.glow} size={7} />
          <span style={{ fontFamily: t.mono, fontSize: 10.5, color: t.textFaint }}>{time}</span>
        </div>
        <div style={{ display: 'flex', alignItems: 'center', gap: 7, marginTop: 3 }}>
          <span style={{ fontFamily: t.mono, fontSize: 10.5, color: c }}>{agent}</span>
          <span style={{ display: 'inline-flex', alignItems: 'center', gap: 3, fontFamily: t.mono, fontSize: 10.5, color: t.textFaint }}>{K.I.branch(t.textFaint, 10)}{repo}:{branch}</span>
        </div>
        <div style={{ fontFamily: t.font, fontSize: 12.5, color: t.textDim, marginTop: 5, lineHeight: 1.4,
          overflow: 'hidden', textOverflow: 'ellipsis', display: '-webkit-box', WebkitLineClamp: 2, WebkitBoxOrient: 'vertical' }}>{preview}</div>
      </div>
    </div>
  );
}

function HomeScreen({ t, platform }) {
  return (
    <Screen t={t}>
      <AppBar t={t} platform={platform}
        leading={<K.NavBtn t={t} platform={platform}>{K.I.gear(t.textDim)}</K.NavBtn>}
        center={<div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
          <K.ConduitMark t={t} size={24} />
          <span style={{ fontFamily: t.mono, fontSize: 15, fontWeight: 700, letterSpacing: 1, color: t.text, textShadow: K.glowText(t, t.accent, 0.4) }}><span style={{ color: t.glow ? t.accent : t.textDim }}>&gt;</span>conduit</span>
        </div>}
        trailing={<K.NavBtn t={t} platform={platform}>{K.I.archive(t.textDim)}</K.NavBtn>} />

      <div style={{ flex: 1, overflow: 'auto', padding: '0 14px' }}>
        {/* connection status */}
        <div style={{ display: 'flex', alignItems: 'center', gap: 9, padding: '10px 13px', borderRadius: 12, marginBottom: 16,
          background: t.glow ? 'rgba(70,224,168,0.07)' : t.surface, border: `1px solid ${t.glow ? t.green + '44' : t.border}`,
          boxShadow: t.glow ? K.glowBox(t, t.green, 0.3) : 'none' }}>
          {K.I.server(t.green, 17)}
          <div style={{ flex: 1 }}>
            <div style={{ fontFamily: t.font, fontSize: 13, fontWeight: 600, color: t.text }}>mac-studio</div>
            <div style={{ fontFamily: t.mono, fontSize: 10.5, color: t.textFaint }}>broker :1977 · LAN</div>
          </div>
          <span style={{ display: 'inline-flex', alignItems: 'center', gap: 5, fontFamily: t.mono, fontSize: 11, color: t.green }}>
            <K.Dot color={t.green} glow={t.glow} size={6} />connected · 8ms
          </span>
        </div>

        <K.SectionLabel t={t} action={
          <span style={{ display: 'inline-flex', alignItems: 'center', gap: 5, fontFamily: t.font, fontSize: 12.5, fontWeight: 600, color: t.glow ? t.accent : t.accent2 }}>
            {K.I.plus(t.glow ? t.accent : t.accent2, 14)}New session
          </span>}>Active sessions</K.SectionLabel>

        <div style={{ display: 'flex', flexDirection: 'column', gap: 9, marginBottom: 18 }}>
          <SessionRow t={t} name="Fix auth refresh loop" repo="envoy-api" branch="fix/auth" agent="claude" status="live" time="now"
            preview="Found it — the 401 handler re-enters refresh before the new token is stored. Patching session.ts…" />
          <SessionRow t={t} name="Port matrix to Compose" repo="conduit" branch="android-ui" agent="codex" status="paused" time="14m"
            preview="Mapped 6 screens. Waiting on your call: keep the bottom sheet or move to a full dialog?" />
          <SessionRow t={t} name="Tidy release notes" repo="conduit" branch="main" agent="claude" status="idle" time="2h"
            preview="Drafted v1.4 notes from the merged PRs. Ready when you are." />
        </div>

        <K.SectionLabel t={t} action={
          <span style={{ display: 'inline-flex', alignItems: 'center', gap: 5, fontFamily: t.font, fontSize: 12.5, fontWeight: 600, color: t.textDim }}>
            {K.I.wifi(t.textDim, 14)}Pair box
          </span>}>Boxes</K.SectionLabel>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 1, borderRadius: t.radius - 4, overflow: 'hidden', border: `1px solid ${t.border}`, background: t.surface }}>
          <K.Row t={t} leading={<div style={{ width: 30, height: 30, borderRadius: 8, background: `${t.green}1c`, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>{K.I.server(t.green, 16)}</div>}
            title="mac-studio" sub="192.168.1.20 · mDNS" trailing={<span style={{ fontFamily: t.mono, fontSize: 11, color: t.green }}>online</span>} />
          <div style={{ height: 1, background: t.border }} />
          <K.Row t={t} leading={<div style={{ width: 30, height: 30, borderRadius: 8, background: `${t.textFaint}22`, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>{K.I.ssh(t.textFaint, 16)}</div>}
            title="hetzner-box" sub="ssh · 49.13.x.x" trailing={<span style={{ fontFamily: t.mono, fontSize: 11, color: t.textFaint }}>tap to wake</span>} />
        </div>
      </div>
      <div style={{ height: botPad(platform) }} />
    </Screen>
  );
}

// ── CHAT (hero) ───────────────────────────────────────────────
function ChatScreen({ t, platform }) {
  return (
    <Screen t={t}>
      <K.SessionHeader t={t} platform={platform} title="Fix auth refresh loop" agent="claude" branch="fix/auth" status="live" />
      <K.TabBar t={t} platform={platform} active="chat" />
      <div style={{ flex: 1, overflow: 'auto', padding: '4px 12px' }}>
        <K.UserBubble t={t}>the token refresh loops on a 401 — can you find it?</K.UserBubble>
        <K.Assistant t={t}>Found it — in <K.Code t={t}>auth/session.ts</K.Code> the 401 handler calls <K.Code t={t}>refresh()</K.Code> again before the new token is saved, so each retry re-enters stale. Here's the fix:</K.Assistant>
        <K.ToolCard t={t} kind="search" label="Searched the codebase" meta={'rg "refreshToken" · 3 hits'} ms="120ms" />
        <K.DiffCard t={t} file="src/auth/session.ts" added={4} removed={2} lines={[
          ' async function refresh() {',
          '-  const t = await mint()',
          '+  if (inFlight) return inFlight',
          '+  inFlight = mint().then(save)',
          ' }',
        ]} />
        <K.PendingCard t={t} prompt="Run the test suite to confirm the fix?"
          options={['Yes, run npm test', 'Show the command first', 'Skip']} />
      </div>
      <K.QuickReplies t={t} items={['Run the tests', 'Explain the fix', 'Commit on fix/auth']} />
      <K.Composer t={t} platform={platform} />
      <div style={{ height: botPad(platform) }} />
    </Screen>
  );
}

// ── TERMINAL ──────────────────────────────────────────────────
function TerminalScreen({ t, platform }) {
  const prompt = <span style={{ color: t.green }}>nikhil@mac-studio</span>;
  return (
    <Screen t={t}>
      <K.SessionHeader t={t} platform={platform} title="Fix auth refresh loop" agent="claude" branch="fix/auth" status="live" />
      <K.TabBar t={t} platform={platform} active="terminal" />
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', margin: '2px 12px 0', borderRadius: 12, overflow: 'hidden', border: `1px solid ${t.border}` }}>
        <K.Term t={t}>
          <K.TLine c={t.textDim}>{prompt}<span style={{ color: t.textFaint }}>:~/envoy-api (fix/auth)$ </span><span style={{ color: t.text }}>npm test -- auth</span></K.TLine>
          <K.TLine c={t.textDim}>{' '}</K.TLine>
          <K.TLine c={t.textDim}>{'> envoy-api@1.4.0 test'}</K.TLine>
          <K.TLine c={t.textDim}>{'> vitest run auth'}</K.TLine>
          <K.TLine c={t.textDim}>{' '}</K.TLine>
          <K.TLine c={t.green}>{' ✓ auth/session.test.ts (7)'}</K.TLine>
          <K.TLine c={t.green}>{'   ✓ refreshes once on 401'}</K.TLine>
          <K.TLine c={t.green}>{'   ✓ does not loop on repeat 401'}</K.TLine>
          <K.TLine c={t.textDim}>{' '}</K.TLine>
          <K.TLine c={t.text}> Test Files  <span style={{ color: t.green }}>1 passed</span> (1)</K.TLine>
          <K.TLine c={t.text}>{'      Tests  '}<span style={{ color: t.green }}>7 passed</span> (7)</K.TLine>
          <K.TLine c={t.textDim}>{'   Duration  812ms'}</K.TLine>
          <K.TLine c={t.textDim}>{' '}</K.TLine>
          <K.TLine c={t.textDim}>{prompt}<span style={{ color: t.textFaint }}>:~/envoy-api (fix/auth)$ </span><span style={{ display: 'inline-block', width: 8, height: 15, background: t.glow ? t.accent : t.text, verticalAlign: -2, boxShadow: K.glowText(t, t.accent, 0.7) }} /></K.TLine>
        </K.Term>
      </div>
      <K.AccessoryBar t={t} />
      <div style={{ height: botPad(platform) }} />
    </Screen>
  );
}

// ── BROWSER (live preview tab) ────────────────────────────────
function BrowserScreen({ t, platform }) {
  return (
    <Screen t={t}>
      <K.SessionHeader t={t} platform={platform} title="Fix auth refresh loop" agent="claude" branch="fix/auth" status="live" />
      <K.TabBar t={t} platform={platform} active="browser" />
      {/* URL bar */}
      <div style={{ display: 'flex', alignItems: 'center', gap: 8, margin: '2px 12px 8px', padding: '7px 12px', borderRadius: 11,
        background: t.dark ? 'rgba(255,255,255,0.06)' : '#fff', border: `1px solid ${t.border}` }}>
        {K.I.lock(t.green, 13)}
        <span style={{ flex: 1, fontFamily: t.mono, fontSize: 12, color: t.textDim }}>localhost:5173<span style={{ color: t.textFaint }}>/login</span></span>
        {K.I.reload(t.textDim, 15)}
      </div>
      {/* rendered preview of the app being built */}
      <div style={{ flex: 1, margin: '0 12px', borderRadius: 14, overflow: 'hidden', border: `1px solid ${t.border}`,
        background: '#0e1117', position: 'relative', display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', gap: 18, padding: 24 }}>
        <div style={{ position: 'absolute', top: 0, left: 0, right: 0, height: 44, display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '0 16px', borderBottom: '1px solid rgba(255,255,255,0.06)' }}>
          <span style={{ fontFamily: t.mono, fontSize: 12, color: '#9fb4d8', fontWeight: 700 }}>envoy</span>
          <span style={{ fontFamily: t.mono, fontSize: 10.5, color: '#5b6b85' }}>docs · pricing</span>
        </div>
        <div style={{ width: 54, height: 54, borderRadius: 14, background: 'linear-gradient(135deg,#3dd9eb,#5b8cff)', boxShadow: '0 0 24px rgba(61,217,235,0.4)' }} />
        <div style={{ fontFamily: t.font, fontSize: 22, fontWeight: 700, color: '#eaf2ff', textAlign: 'center', lineHeight: 1.2 }}>Welcome back</div>
        <div style={{ fontFamily: t.font, fontSize: 13, color: '#9fb4d8', textAlign: 'center', marginTop: -10 }}>Sign in to your workspace</div>
        <div style={{ width: '100%', maxWidth: 220, height: 38, borderRadius: 9, background: 'rgba(255,255,255,0.06)', border: '1px solid rgba(255,255,255,0.1)', display: 'flex', alignItems: 'center', padding: '0 12px', fontFamily: t.mono, fontSize: 12, color: '#5b6b85' }}>you@company.com</div>
        <div style={{ width: '100%', maxWidth: 220, height: 40, borderRadius: 9, background: 'linear-gradient(135deg,#3dd9eb,#5b8cff)', display: 'flex', alignItems: 'center', justifyContent: 'center', fontFamily: t.font, fontSize: 14, fontWeight: 700, color: '#06121f' }}>Continue</div>
        <div style={{ position: 'absolute', bottom: 10, right: 12, display: 'inline-flex', alignItems: 'center', gap: 5, padding: '4px 9px', borderRadius: 99, background: 'rgba(70,224,168,0.12)', border: '1px solid rgba(70,224,168,0.4)' }}>
          <K.Dot color={t.green} glow size={6} /><span style={{ fontFamily: t.mono, fontSize: 9.5, color: t.green }}>hot reload</span>
        </div>
      </div>
      <div style={{ height: botPad(platform) + 4 }} />
    </Screen>
  );
}

Object.assign(window, { Screen, AppBar, topPad, botPad, HomeScreen, ChatScreen, TerminalScreen, BrowserScreen });
