// tablet.jsx — landscape iPad "IDE" layout for a session:
//   left rail (sessions + search)  |  center (chat thread)  |  right pane (terminal / browser / usage)
// Reuses every phone component; the tablet's win is showing them all at once.
const TB = window;
const _ngT = window.neonGlowColor;
const { gT: _gtT, gB: _gbT } = window;

// ── scale a fixed-size design to fit the available width ──
function ScaleToFit({ designW, designH, maxScale = 1, children }) {
  const wrapRef = React.useRef(null);
  const [scale, setScale] = React.useState(0.5);
  React.useLayoutEffect(() => {
    const el = wrapRef.current; if (!el) return;
    const measure = () => {
      const avail = el.clientWidth;
      setScale(Math.min(maxScale, Math.max(0.2, avail / designW)));
    };
    measure();
    const ro = new ResizeObserver(measure);
    ro.observe(el);
    return () => ro.disconnect();
  }, [designW, maxScale]);
  return (
    <div ref={wrapRef} style={{ width: '100%', height: designH * scale, position: 'relative' }}>
      <div style={{ position: 'absolute', top: 0, left: '50%', width: designW, height: designH,
        transform: `translateX(-50%) scale(${scale})`, transformOrigin: 'top center' }}>
        {children}
      </div>
    </div>
  );
}

// ── iPad bezel ──
function TabletFrame({ t, children }) {
  const ig = _ngT(t);
  return (
    <div style={{ width: 1194, height: 834, borderRadius: 38, padding: 14, boxSizing: 'border-box', position: 'relative',
      background: t.dark ? 'linear-gradient(150deg,#11161f,#04060c)' : 'linear-gradient(150deg,#cfd8e8,#aab6cc)',
      boxShadow: t.glow ? `0 0 0 1px ${ig}40, 0 0 60px ${ig}2e, 0 40px 110px rgba(0,0,0,${t.dark ? 0.6 : 0.3})`
        : `0 0 0 1px ${t.borderStrong}, 0 40px 110px rgba(0,0,0,${t.dark ? 0.6 : 0.25})` }}>
      {/* front camera */}
      <div style={{ position: 'absolute', top: 24, left: '50%', transform: 'translateX(-50%)', width: 7, height: 7, borderRadius: 99, background: '#05070d', border: `1px solid ${t.dark ? '#1b2536' : '#8693a8'}`, zIndex: 50 }} />
      <div style={{ width: '100%', height: '100%', borderRadius: 26, overflow: 'hidden', position: 'relative',
        background: t.appBg, border: `1px solid ${t.dark ? 'rgba(0,0,0,0.6)' : 'rgba(255,255,255,0.5)'}` }}>
        {children}
      </div>
    </div>
  );
}

// ── left rail: sessions + search + new ──
function RailRow({ t, s, active, onClick }) {
  const c = TB.agentColor(t, s.agent);
  const sc = s.status === 'live' ? t.green : s.status === 'paused' ? t.claude : t.textFaint;
  return (
    <button onClick={onClick} style={{ appearance: 'none', cursor: 'pointer', textAlign: 'left', width: '100%', display: 'flex', gap: 10, padding: '10px 11px', borderRadius: 12,
      background: active ? (t.dark ? `${c}16` : `${c}10`) : 'transparent',
      border: `1px solid ${active ? c + (t.glow ? '55' : '3a') : 'transparent'}`,
      boxShadow: active && t.glow ? _gbT(t, c, 0.28) : 'none', transition: 'all .12s' }}>
      <div style={{ width: 30, height: 30, borderRadius: 8, flexShrink: 0, display: 'flex', alignItems: 'center', justifyContent: 'center',
        background: `${c}18`, border: `1px solid ${c}33` }}><TB.ConduitMark t={t} size={18} color={c} /></div>
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
          <span style={{ flex: 1, fontFamily: t.font, fontSize: 13, fontWeight: active ? 650 : 550, color: t.text, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{s.name}</span>
          <TB.Dot color={sc} glow={t.glow} size={6} />
        </div>
        <div style={{ fontFamily: t.mono, fontSize: 9.5, color: t.textFaint, marginTop: 2, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>
          <span style={{ color: c }}>{s.agent}</span> · {s.repo}:{s.branch}
        </div>
      </div>
    </button>
  );
}

function TabletRail({ t, activeId, onPick, onSearch }) {
  const c = _ngT(t);
  const active = TB.SESSIONS.filter(s => ['live', 'paused', 'idle'].includes(s.status));
  const recent = TB.SESSIONS.filter(s => ['done', 'archived'].includes(s.status));
  const Group = ({ label, items }) => (
    <div style={{ marginBottom: 6 }}>
      <div style={{ fontFamily: t.mono, fontSize: 9.5, letterSpacing: 1.4, textTransform: 'uppercase', color: t.textFaint, padding: '8px 11px 5px' }}>{label}</div>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 3 }}>
        {items.map(s => <RailRow key={s.id} t={t} s={s} active={s.id === activeId} onClick={() => onPick(s.id)} />)}
      </div>
    </div>
  );
  return (
    <div style={{ width: 272, flexShrink: 0, display: 'flex', flexDirection: 'column', borderRight: `1px solid ${t.border}`, background: t.dark ? 'rgba(6,10,20,0.4)' : 'rgba(255,255,255,0.5)' }}>
      {/* brand + box */}
      <div style={{ padding: '16px 14px 10px' }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 9, marginBottom: 12 }}>
          <TB.ConduitMark t={t} size={24} />
          <span style={{ fontFamily: t.mono, fontSize: 15, fontWeight: 700, letterSpacing: 1, color: t.text, textShadow: _gtT(t, c, 0.4) }}><span style={{ color: t.glow ? c : t.textDim }}>&gt;</span>conduit</span>
          <span style={{ marginLeft: 'auto', display: 'inline-flex', alignItems: 'center', gap: 5, fontFamily: t.mono, fontSize: 10, color: t.green }}><TB.Dot color={t.green} glow={t.glow} size={5} />mac-studio</span>
        </div>
        {/* search → palette */}
        <button onClick={onSearch} style={{ appearance: 'none', cursor: 'pointer', width: '100%', display: 'flex', alignItems: 'center', gap: 9, padding: '9px 11px', borderRadius: 11, textAlign: 'left',
          background: t.dark ? 'rgba(255,255,255,0.05)' : '#fff', border: `1px solid ${t.glow ? c + '3a' : t.border}` }}>
          {TB.I.search(t.glow ? c : t.textDim, 15)}
          <span style={{ flex: 1, fontFamily: t.font, fontSize: 12.5, color: t.textFaint }}>Search…</span>
          <span style={{ fontFamily: t.mono, fontSize: 9.5, color: t.textFaint, padding: '2px 6px', borderRadius: 5, border: `1px solid ${t.border}` }}>⌘K</span>
        </button>
      </div>
      {/* lists */}
      <div style={{ flex: 1, overflow: 'auto', padding: '0 8px' }}>
        <Group label="Active" items={active} />
        <Group label="Recent" items={recent} />
      </div>
      {/* new session */}
      <div style={{ padding: 12, borderTop: `1px solid ${t.border}` }}>
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 8, padding: '11px', borderRadius: 12,
          background: t.glow ? c : t.accent, color: t.accentText, fontFamily: t.font, fontSize: 13.5, fontWeight: 700,
          boxShadow: t.glow ? _gbT(t, c, 0.7) : 'none' }}>{TB.I.plus(t.accentText, 16)}New session</div>
      </div>
    </div>
  );
}

// ── center: chat thread ──
function ChatThread({ t }) {
  return (
    <div style={{ flex: 1, overflow: 'auto', padding: '14px 18px' }}>
      <TB.UserBubble t={t}>the token refresh loops on a 401 — find it, fix it, and make sure tests pass</TB.UserBubble>
      <TB.Assistant t={t}>On it. Here's my plan:</TB.Assistant>
      <TB.PlanCard t={t} steps={[
        { label: 'Locate the refresh path', state: 'done' },
        { label: 'Patch the re-entry bug', state: 'done' },
        { label: 'Run the auth test suite', state: 'done' },
        { label: 'Commit on fix/auth', state: 'active' },
      ]} />
      <TB.Assistant t={t}>Found it in <TB.Code t={t}>auth/session.ts</TB.Code> — the 401 handler re-enters <TB.Code t={t}>refresh()</TB.Code> before the new token is saved.</TB.Assistant>
      <TB.DiffCard t={t} file="src/auth/session.ts" added={4} removed={2} lines={[
        ' async function refresh() {',
        '-  const t = await mint()',
        '+  if (inFlight) return inFlight',
        '+  inFlight = mint().then(save)',
        ' }',
      ]} />
      <TB.Assistant t={t}>One edge case left — I'll hand the regression test to a subagent while I patch:</TB.Assistant>
      <TB.HandoffCard t={t} from="claude" to="codex" task="Write a regression test: inFlight must reset to null when mint() rejects."
        state="done" steps={3} tokens="12.4k"
        result="Added auth/session.test.ts › “retries after a failed refresh”. Green against the patched guard." />
      <TB.PendingCard t={t} prompt="All green — 7/7 tests pass. Commit on fix/auth?"
        options={['Commit “fix: guard token refresh re-entry”', 'Edit the message', 'Not yet']} />
    </div>
  );
}

// ── right pane: terminal / browser / usage ──
function RightPaneTabs({ t, active, onPick }) {
  const c = _ngT(t);
  const tabs = [['terminal', 'Terminal', 'term'], ['browser', 'Browser', 'browser'], ['info', 'Info', 'info']];
  return (
    <div style={{ display: 'flex', gap: 4, padding: 6, margin: 10, borderRadius: 11, background: t.dark ? 'rgba(255,255,255,0.05)' : 'rgba(0,0,0,0.04)', border: `1px solid ${t.border}` }}>
      {tabs.map(([id, label, icon]) => {
        const on = id === active;
        const col = on ? (t.glow ? c : t.accent) : t.textFaint;
        return (
          <button key={id} onClick={() => onPick(id)} style={{ appearance: 'none', cursor: 'pointer', flex: 1, display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 6, padding: '7px 0', borderRadius: 8,
            background: on ? (t.dark ? 'rgba(255,255,255,0.08)' : '#fff') : 'transparent', border: on ? `1px solid ${t.glow ? c + '55' : t.border}` : '1px solid transparent',
            color: col, fontFamily: t.font, fontSize: 12, fontWeight: on ? 700 : 500, boxShadow: on && t.glow ? _gbT(t, c, 0.4) : 'none' }}>
            {(TB.I[icon] || TB.I.term)(col, 15)}{label}
          </button>
        );
      })}
    </div>
  );
}

function TerminalPane({ t }) {
  const prompt = <span style={{ color: t.green }}>nikhil@mac-studio</span>;
  return (
    <div style={{ flex: 1, margin: '0 10px 10px', borderRadius: 12, overflow: 'hidden', border: `1px solid ${t.border}`, display: 'flex', flexDirection: 'column' }}>
      <TB.Term t={t}>
        <TB.TLine c={t.textDim}>{prompt}<span style={{ color: t.textFaint }}>:~/envoy-api (fix/auth)$ </span><span style={{ color: t.text }}>npm test -- auth</span></TB.TLine>
        <TB.TLine c={t.textDim}>{' '}</TB.TLine>
        <TB.TLine c={t.green}>{' ✓ auth/session.test.ts (7)'}</TB.TLine>
        <TB.TLine c={t.green}>{'   ✓ refreshes once on 401'}</TB.TLine>
        <TB.TLine c={t.green}>{'   ✓ does not loop on repeat 401'}</TB.TLine>
        <TB.TLine c={t.green}>{'   ✓ retries after a failed refresh'}</TB.TLine>
        <TB.TLine c={t.textDim}>{' '}</TB.TLine>
        <TB.TLine c={t.text}> Test Files  <span style={{ color: t.green }}>1 passed</span> (1)</TB.TLine>
        <TB.TLine c={t.text}>{'      Tests  '}<span style={{ color: t.green }}>7 passed</span> (7)</TB.TLine>
        <TB.TLine c={t.textDim}>{'   Duration  812ms'}</TB.TLine>
        <TB.TLine c={t.textDim}>{' '}</TB.TLine>
        <TB.TLine c={t.textDim}>{prompt}<span style={{ color: t.textFaint }}>:~/envoy-api (fix/auth)$ </span><span style={{ display: 'inline-block', width: 8, height: 15, background: t.glow ? t.accent : t.text, verticalAlign: -2, boxShadow: TB.glowText(t, t.accent, 0.7) }} /></TB.TLine>
      </TB.Term>
    </div>
  );
}

function BrowserPane({ t }) {
  return (
    <div style={{ flex: 1, display: 'flex', flexDirection: 'column', margin: '0 10px 10px' }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 8, padding: '7px 12px', borderRadius: 10,
        background: t.dark ? 'rgba(255,255,255,0.06)' : '#fff', border: `1px solid ${t.border}` }}>
        {TB.I.lock(t.green, 12)}
        <span style={{ flex: 1, fontFamily: t.mono, fontSize: 11.5, color: t.textDim }}>localhost:5173<span style={{ color: t.textFaint }}>/login</span></span>
        {TB.I.reload(t.textDim, 14)}
      </div>
      <div style={{ flex: 1, borderRadius: 12, overflow: 'hidden', border: `1px solid ${t.border}`, background: '#0e1117', position: 'relative',
        display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', gap: 16, padding: 22 }}>
        <div style={{ position: 'absolute', top: 0, left: 0, right: 0, height: 40, display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '0 16px', borderBottom: '1px solid rgba(255,255,255,0.06)' }}>
          <span style={{ fontFamily: t.mono, fontSize: 11.5, color: '#9fb4d8', fontWeight: 700 }}>envoy</span>
          <span style={{ fontFamily: t.mono, fontSize: 10, color: '#5b6b85' }}>docs · pricing</span>
        </div>
        <div style={{ width: 50, height: 50, borderRadius: 13, background: 'linear-gradient(135deg,#3dd9eb,#5b8cff)', boxShadow: '0 0 24px rgba(61,217,235,0.4)' }} />
        <div style={{ fontFamily: t.font, fontSize: 20, fontWeight: 700, color: '#eaf2ff' }}>Welcome back</div>
        <div style={{ fontFamily: t.font, fontSize: 12.5, color: '#9fb4d8', marginTop: -8 }}>Sign in to your workspace</div>
        <div style={{ width: '100%', maxWidth: 240, height: 36, borderRadius: 9, background: 'rgba(255,255,255,0.06)', border: '1px solid rgba(255,255,255,0.1)', display: 'flex', alignItems: 'center', padding: '0 12px', fontFamily: t.mono, fontSize: 11.5, color: '#5b6b85' }}>you@company.com</div>
        <div style={{ width: '100%', maxWidth: 240, height: 38, borderRadius: 9, background: 'linear-gradient(135deg,#3dd9eb,#5b8cff)', display: 'flex', alignItems: 'center', justifyContent: 'center', fontFamily: t.font, fontSize: 13.5, fontWeight: 700, color: '#06121f' }}>Continue</div>
        <div style={{ position: 'absolute', bottom: 10, right: 12, display: 'inline-flex', alignItems: 'center', gap: 5, padding: '4px 9px', borderRadius: 99, background: 'rgba(70,224,168,0.12)', border: '1px solid rgba(70,224,168,0.4)' }}>
          <TB.Dot color={t.green} glow size={5} /><span style={{ fontFamily: t.mono, fontSize: 9, color: t.green }}>hot reload</span>
        </div>
      </div>
    </div>
  );
}

function InfoPane({ t }) {
  const [variant, setVariant] = React.useState(() => localStorage.getItem('nk_usage_variant') || 'A');
  const setV = (v) => { setVariant(v); localStorage.setItem('nk_usage_variant', v); };
  return (
    <div style={{ flex: 1, overflow: 'auto', padding: '0 14px 14px' }}>
      <TB.SessionInfoBody t={t} variant={variant} onVariant={setV} />
    </div>
  );
}

function TabletRightPane({ t, tab, onTab }) {
  return (
    <div style={{ width: 392, flexShrink: 0, display: 'flex', flexDirection: 'column', borderLeft: `1px solid ${t.border}`, background: t.dark ? 'rgba(6,10,20,0.4)' : 'rgba(255,255,255,0.45)' }}>
      <RightPaneTabs t={t} active={tab} onPick={onTab} />
      {tab === 'terminal' && <TerminalPane t={t} />}
      {tab === 'browser' && <BrowserPane t={t} />}
      {tab === 'info' && <InfoPane t={t} />}
    </div>
  );
}

// ── center column with its own header + composer ──
function TabletCenter({ t, onInfo, infoActive }) {
  const c = TB.agentColor(t, 'claude');
  const ig = _ngT(t);
  return (
    <div style={{ flex: 1, minWidth: 0, display: 'flex', flexDirection: 'column' }}>
      {/* session header strip */}
      <div style={{ display: 'flex', alignItems: 'center', gap: 12, padding: '13px 18px', borderBottom: `1px solid ${t.border}` }}>
        <div style={{ flex: 1, minWidth: 0 }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
            <TB.Dot color={t.green} glow={t.glow} size={7} />
            <span style={{ fontFamily: t.font, fontSize: 16, fontWeight: 700, color: t.text }}>Fix auth refresh loop</span>
          </div>
          <div style={{ display: 'flex', alignItems: 'center', gap: 8, fontFamily: t.mono, fontSize: 11, color: t.textFaint, marginTop: 3 }}>
            <span style={{ color: c }}>claude · sonnet-4.5</span>
            <span style={{ display: 'inline-flex', alignItems: 'center', gap: 3 }}>{TB.I.branch(t.textFaint, 11)}envoy-api:fix/auth</span>
          </div>
        </div>
        <div onClick={onInfo} style={{ borderRadius: 99, cursor: 'pointer', boxShadow: infoActive && t.glow ? `0 0 0 2px ${ig}66` : 'none', outline: infoActive ? `2px solid ${t.glow ? ig + '66' : t.accent + '55'}` : 'none', outlineOffset: 1 }}>
          <TB.UsageChip t={t} onTap={onInfo} />
        </div>
        <div style={{ width: 38, height: 38, borderRadius: 99, display: 'flex', alignItems: 'center', justifyContent: 'center', background: t.dark ? 'rgba(255,255,255,0.06)' : 'rgba(0,0,0,0.04)', border: `1px solid ${t.border}` }}>{TB.I.fork(t.textDim, 16)}</div>
      </div>
      <ChatThread t={t} />
      <TB.QuickReplies t={t} items={['Commit & push', 'Open a PR', 'Show the diff']} />
      <TB.Composer t={t} platform="ios" />
      <div style={{ height: 8 }} />
    </div>
  );
}

// ── the IDE session view (rail + chat + right pane); shell owns chrome ──
function TabletSessionView({ t, activeId, onPick, onSearch }) {
  const [rightTab, setRightTab] = React.useState('terminal');
  return (
    <div style={{ flex: 1, display: 'flex', minHeight: 0 }}>
      <TabletRail t={t} activeId={activeId} onPick={onPick} onSearch={onSearch} />
      <TabletCenter t={t} onInfo={() => setRightTab('info')} infoActive={rightTab === 'info'} />
      <TabletRightPane t={t} tab={rightTab} onTab={setRightTab} />
    </div>
  );
}

Object.assign(window, { ScaleToFit, TabletFrame, TabletSessionView, TabletRail, TabletRightPane, TabletCenter, ChatThread, OutcomeRow: null });
