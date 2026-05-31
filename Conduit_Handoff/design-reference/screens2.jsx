// screens2.jsx — History, Connect/Pairing, New Session (sheet), Settings.
const K2 = window;
const { Screen: _Screen, AppBar: _AppBar, topPad: _topPad, botPad: _botPad } = window;

// ── HISTORY ───────────────────────────────────────────────────
function HistoryRow({ t, name, repo, agent, time, archived }) {
  const c = K2.agentColor(t, agent);
  return (
    <div style={{ display: 'flex', gap: 12, padding: '12px 13px', alignItems: 'center', position: 'relative',
      background: t.surface, borderRadius: t.radius - 4, border: `1px solid ${t.border}`, opacity: archived ? 0.62 : 1 }}>
      <div style={{ width: 34, height: 34, borderRadius: 9, flexShrink: 0, display: 'flex', alignItems: 'center', justifyContent: 'center',
        background: `${c}16`, border: `1px solid ${c}33` }}>
        <K2.ConduitMark t={t} size={20} color={c} />
      </div>
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 7 }}>
          <span style={{ fontFamily: t.font, fontSize: 14, fontWeight: 600, color: t.text, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis', flex: 1 }}>{name}</span>
          <span style={{ display: 'inline-flex', alignItems: 'center', gap: 4, fontFamily: t.mono, fontSize: 9.5, color: t.textFaint, padding: '2px 7px', borderRadius: 99, border: `1px solid ${t.border}` }}>
            {K2.I.lock(t.textFaint, 10)}read-only
          </span>
        </div>
        <div style={{ fontFamily: t.mono, fontSize: 10.5, color: t.textFaint, marginTop: 3 }}>{repo} · {agent} · {time}</div>
      </div>
    </div>
  );
}

function HistoryScreen({ t, platform }) {
  return (
    <_Screen t={t}>
      <_AppBar t={t} platform={platform}
        leading={<K2.NavBtn t={t} platform={platform}>{K2.I.back(t.textDim)}</K2.NavBtn>}
        center={<span style={{ fontFamily: t.font, fontSize: 17, fontWeight: 700, color: t.text }}>History</span>}
        trailing={<K2.NavBtn t={t} platform={platform}>{K2.I.search(t.textDim)}</K2.NavBtn>} />
      <div style={{ flex: 1, overflow: 'auto', padding: '0 14px' }}>
        {/* swipe-to-archive affordance demo */}
        <div style={{ position: 'relative', marginBottom: 9, borderRadius: t.radius - 4, overflow: 'hidden' }}>
          <div style={{ position: 'absolute', inset: 0, display: 'flex', justifyContent: 'flex-end', alignItems: 'stretch' }}>
            <div style={{ width: 78, background: t.claude, display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', gap: 3 }}>
              {K2.I.archive('#1a0e02', 18)}<span style={{ fontFamily: t.font, fontSize: 10.5, fontWeight: 700, color: '#1a0e02' }}>Archive</span>
            </div>
          </div>
          <div style={{ transform: 'translateX(-78px)' }}>
            <HistoryRow t={t} name="Add rate limiting" repo="envoy-api" agent="claude" time="yesterday" />
          </div>
        </div>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 9, marginBottom: 16 }}>
          <HistoryRow t={t} name="Migrate to pnpm" repo="conduit" agent="codex" time="2d ago" />
          <HistoryRow t={t} name="Debug flaky CI" repo="envoy-api" agent="claude" time="3d ago" />
        </div>
        <K2.SectionLabel t={t}>Archived</K2.SectionLabel>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 9 }}>
          <HistoryRow t={t} name="Spike: voice rail" repo="conduit" agent="codex" time="1w ago" archived />
          <HistoryRow t={t} name="Old onboarding copy" repo="marketing" agent="claude" time="2w ago" archived />
        </div>
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 7, marginTop: 14, padding: '11px', borderRadius: 11, border: `1px dashed ${t.red}55`, color: t.red, fontFamily: t.font, fontSize: 13, fontWeight: 600 }}>
          {K2.I.trash(t.red, 16)}Delete archived permanently
        </div>
      </div>
      <div style={{ height: _botPad(platform) }} />
    </_Screen>
  );
}

// ── CONNECT / PAIRING ─────────────────────────────────────────
function ConnectScreen({ t, platform }) {
  return (
    <_Screen t={t}>
      <_AppBar t={t} platform={platform}
        leading={<K2.NavBtn t={t} platform={platform}>{K2.I.back(t.textDim)}</K2.NavBtn>}
        center={<span style={{ fontFamily: t.font, fontSize: 17, fontWeight: 700, color: t.text }}>Pair a box</span>}
        trailing={<span />} />
      <div style={{ flex: 1, overflow: 'auto', padding: '4px 14px' }}>
        {/* discovery */}
        <K2.SectionLabel t={t} action={<span style={{ display: 'inline-flex', alignItems: 'center', gap: 5, fontFamily: t.mono, fontSize: 11, color: t.glow ? t.accent : t.textDim }}><K2.Dot color={t.glow ? t.accent : t.textDim} glow={t.glow} size={6} />scanning</span>}>On your network</K2.SectionLabel>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 9, marginBottom: 18 }}>
          {[['mac-studio', '192.168.1.20 · :1977', true], ['nikhil-mbp', '192.168.1.41 · :1977', false]].map(([n, s, ready], i) => (
            <div key={i} style={{ display: 'flex', alignItems: 'center', gap: 12, padding: '13px', borderRadius: t.radius - 4,
              background: t.surface, border: `1px solid ${ready ? (t.glow ? t.green + '55' : t.borderStrong) : t.border}`,
              boxShadow: ready && t.glow ? K2.glowBox(t, t.green, 0.3) : 'none' }}>
              <div style={{ width: 38, height: 38, borderRadius: 10, display: 'flex', alignItems: 'center', justifyContent: 'center', background: `${t.green}16`, border: `1px solid ${t.green}33` }}>{K2.I.server(ready ? t.green : t.textDim, 18)}</div>
              <div style={{ flex: 1 }}>
                <div style={{ fontFamily: t.font, fontSize: 14.5, fontWeight: 600, color: t.text }}>{n}</div>
                <div style={{ fontFamily: t.mono, fontSize: 10.5, color: t.textFaint }}>{s}</div>
              </div>
              <span style={{ padding: '7px 14px', borderRadius: 99, fontFamily: t.font, fontSize: 12.5, fontWeight: 700,
                background: ready ? (t.glow ? t.green : t.accent) : 'transparent', color: ready ? (t.glow ? '#04140d' : t.accentText) : t.textDim,
                border: ready ? 'none' : `1px solid ${t.border}`, boxShadow: ready && t.glow ? K2.glowBox(t, t.green, 0.6) : 'none' }}>{ready ? 'Pair' : 'Wake'}</span>
            </div>
          ))}
        </div>

        {/* other methods */}
        <K2.SectionLabel t={t}>Connect another way</K2.SectionLabel>
        <div style={{ display: 'flex', gap: 10, marginBottom: 16 }}>
          {[[K2.I.ssh, 'SSH bootstrap', 'pair over ssh'], [K2.I.qr, 'Scan QR', 'from the broker']].map(([ic, ti, su], i) => (
            <div key={i} style={{ flex: 1, padding: '15px 13px', borderRadius: t.radius - 4, background: t.surface, border: `1px solid ${t.border}`,
              display: 'flex', flexDirection: 'column', gap: 8 }}>
              <div style={{ width: 36, height: 36, borderRadius: 10, display: 'flex', alignItems: 'center', justifyContent: 'center', background: t.glow ? `${t.accent}1a` : (t.dark ? 'rgba(255,255,255,0.05)' : 'rgba(0,0,0,0.04)'), border: `1px solid ${t.border}` }}>{ic(t.glow ? t.accent : t.text, 18)}</div>
              <div style={{ fontFamily: t.font, fontSize: 13.5, fontWeight: 650, color: t.text }}>{ti}</div>
              <div style={{ fontFamily: t.mono, fontSize: 10.5, color: t.textFaint }}>{su}</div>
            </div>
          ))}
        </div>

        {/* agent accounts */}
        <K2.SectionLabel t={t}>Agent sign-in</K2.SectionLabel>
        <div style={{ borderRadius: t.radius - 4, overflow: 'hidden', border: `1px solid ${t.border}`, background: t.surface }}>
          <K2.Row t={t} leading={<div style={{ width: 28, height: 28, borderRadius: 8, background: `${t.claude}1c`, display: 'flex', alignItems: 'center', justifyContent: 'center' }}><K2.Dot color={t.claude} glow={t.glow} size={9} /></div>}
            title="Anthropic" sub="claude · OAuth" badge={<span style={{ fontFamily: t.mono, fontSize: 10, color: t.green, padding: '2px 7px', borderRadius: 99, background: `${t.green}1a` }}>linked</span>} trailing={null} />
          <div style={{ height: 1, background: t.border }} />
          <K2.Row t={t} leading={<div style={{ width: 28, height: 28, borderRadius: 8, background: `${t.codex}1c`, display: 'flex', alignItems: 'center', justifyContent: 'center' }}><K2.Dot color={t.codex} glow={t.glow} size={9} /></div>}
            title="OpenAI" sub="codex · OAuth" trailing={<span style={{ fontFamily: t.font, fontSize: 12.5, fontWeight: 600, color: t.glow ? t.accent : t.accent2 }}>Sign in</span>} />
        </div>
      </div>
      <div style={{ height: _botPad(platform) }} />
    </_Screen>
  );
}

// ── NEW SESSION / FORK (bottom sheet over a dimmed home) ──────
function NewSessionScreen({ t, platform }) {
  const opt = (label, sub, on, c) => (
    <div style={{ flex: 1, padding: '12px 13px', borderRadius: 13, cursor: 'pointer',
      background: on ? (t.glow ? `${c}18` : (t.dark ? 'rgba(255,255,255,0.06)' : '#fff')) : 'transparent',
      border: `1.5px solid ${on ? (t.glow ? c + '88' : c) : t.border}`,
      boxShadow: on && t.glow ? K2.glowBox(t, c, 0.4) : 'none' }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 7 }}>
        <K2.Dot color={c} glow={t.glow && on} size={8} />
        <span style={{ fontFamily: t.font, fontSize: 14, fontWeight: 700, color: t.text }}>{label}</span>
        {on && <span style={{ marginLeft: 'auto' }}>{K2.I.check(c, 15)}</span>}
      </div>
      <div style={{ fontFamily: t.mono, fontSize: 10.5, color: t.textFaint, marginTop: 4 }}>{sub}</div>
    </div>
  );
  return (
    <_Screen t={t}>
      {/* dimmed backdrop */}
      <div style={{ flex: 1, background: t.dark ? 'rgba(0,0,0,0.45)' : 'rgba(20,16,8,0.28)' }} />
      {/* sheet */}
      <div style={{ borderRadius: '26px 26px 0 0', background: t.surfaceSolid, borderTop: `1px solid ${t.borderStrong}`,
        padding: `14px 16px ${_botPad(platform) + 10}px`, boxShadow: '0 -20px 50px rgba(0,0,0,0.4)' }}>
        <div style={{ width: 38, height: 5, borderRadius: 99, background: t.textFaint, opacity: 0.5, margin: '0 auto 14px' }} />
        <div style={{ fontFamily: t.font, fontSize: 20, fontWeight: 750, color: t.text, marginBottom: 14 }}>New session</div>

        <div style={{ fontFamily: t.mono, fontSize: 11, color: t.textDim, marginBottom: 7, letterSpacing: 0.5 }}>WORKING DIRECTORY</div>
        <div style={{ display: 'flex', alignItems: 'center', gap: 9, padding: '12px 13px', borderRadius: 12, background: t.dark ? 'rgba(255,255,255,0.05)' : t.surface2, border: `1px solid ${t.border}`, marginBottom: 16 }}>
          {K2.I.folder(t.glow ? t.accent : t.textDim, 18)}
          <span style={{ flex: 1, fontFamily: t.mono, fontSize: 12.5, color: t.text }}>~/dev/<span style={{ color: t.glow ? t.accent : t.text, fontWeight: 600 }}>envoy-api</span></span>
          {K2.I.chevR(t.textFaint, 14)}
        </div>

        <div style={{ fontFamily: t.mono, fontSize: 11, color: t.textDim, marginBottom: 7, letterSpacing: 0.5 }}>AGENT</div>
        <div style={{ display: 'flex', gap: 9, marginBottom: 16 }}>
          {opt('claude', 'sonnet · opus · haiku', true, t.claude)}
          {opt('codex', 'gpt-5-codex', false, t.codex)}
        </div>

        <div style={{ fontFamily: t.mono, fontSize: 11, color: t.textDim, marginBottom: 7, letterSpacing: 0.5 }}>MODEL · REASONING</div>
        <div style={{ display: 'flex', gap: 8, marginBottom: 20 }}>
          {['opus', 'sonnet', 'haiku'].map((m, i) => (
            <span key={m} style={{ flex: 1, textAlign: 'center', padding: '9px 0', borderRadius: 10, fontFamily: t.mono, fontSize: 12.5, fontWeight: 600,
              background: i === 1 ? (t.glow ? t.claude : t.accent) : (t.dark ? 'rgba(255,255,255,0.05)' : t.surface2),
              color: i === 1 ? (t.glow ? '#1a0e02' : t.accentText) : t.textDim, border: i === 1 ? 'none' : `1px solid ${t.border}`,
              boxShadow: i === 1 && t.glow ? K2.glowBox(t, t.claude, 0.5) : 'none' }}>{m}</span>
          ))}
        </div>

        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 8, padding: '15px', borderRadius: 14,
          background: t.glow ? t.accent : t.accent, color: t.accentText, fontFamily: t.font, fontSize: 15.5, fontWeight: 750,
          boxShadow: t.glow ? K2.glowBox(t, t.accent, 0.9) : 'none' }}>
          {K2.I.plus(t.accentText, 18)}Start session
        </div>
      </div>
    </_Screen>
  );
}

// ── SETTINGS ──────────────────────────────────────────────────
function Toggle({ t, on }) {
  const c = t.glow ? t.accent : t.accent2;
  return (
    <div style={{ width: 46, height: 28, borderRadius: 99, padding: 3, display: 'flex', alignItems: 'center',
      justifyContent: on ? 'flex-end' : 'flex-start',
      background: on ? (t.glow ? c : (t.dark ? c : t.accent)) : (t.dark ? 'rgba(255,255,255,0.14)' : 'rgba(0,0,0,0.14)'),
      boxShadow: on && t.glow ? K2.glowBox(t, c, 0.6) : 'none' }}>
      <div style={{ width: 22, height: 22, borderRadius: 99, background: '#fff', boxShadow: '0 1px 3px rgba(0,0,0,0.3)' }} />
    </div>
  );
}
function SettingsScreen({ t, platform }) {
  return (
    <_Screen t={t}>
      <_AppBar t={t} platform={platform}
        leading={<K2.NavBtn t={t} platform={platform}>{K2.I.back(t.textDim)}</K2.NavBtn>}
        center={<span style={{ fontFamily: t.font, fontSize: 17, fontWeight: 700, color: t.text }}>Settings</span>}
        trailing={<span />} />
      <div style={{ flex: 1, overflow: 'auto', padding: '4px 14px' }}>
        {/* identity card */}
        <div style={{ display: 'flex', alignItems: 'center', gap: 13, padding: '15px', borderRadius: t.radius - 2, marginBottom: 18,
          background: t.surface, border: `1px solid ${t.border}`, boxShadow: t.glow ? K2.glowBox(t, t.accent, 0.25) : 'none' }}>
          <K2.AppIcon size={50} />
          <div style={{ flex: 1 }}>
            <div style={{ fontFamily: t.mono, fontSize: 15, fontWeight: 700, color: t.text, letterSpacing: 0.5 }}>conduit</div>
            <div style={{ fontFamily: t.mono, fontSize: 11, color: t.textFaint, marginTop: 2 }}>v1.4.0 · broker :1977</div>
          </div>
          <span style={{ display: 'inline-flex', alignItems: 'center', gap: 5, fontFamily: t.mono, fontSize: 11, color: t.green }}><K2.Dot color={t.green} glow={t.glow} size={6} />synced</span>
        </div>

        <K2.SectionLabel t={t}>Appearance</K2.SectionLabel>
        <div style={{ borderRadius: t.radius - 4, overflow: 'hidden', border: `1px solid ${t.border}`, background: t.surface, marginBottom: 16 }}>
          <K2.Row t={t} title="Theme" sub="follows this mockup direction" trailing={<span style={{ fontFamily: t.mono, fontSize: 12, color: t.glow ? t.accent : t.textDim }}>{t.name}</span>} />
          <div style={{ height: 1, background: t.border }} />
          <K2.Row t={t} title="Glow & effects" sub="neon halos, glass blur" trailing={<Toggle t={t} on={t.glow} />} />
        </div>

        <K2.SectionLabel t={t}>Terminal</K2.SectionLabel>
        <div style={{ borderRadius: t.radius - 4, overflow: 'hidden', border: `1px solid ${t.border}`, background: t.surface, marginBottom: 16 }}>
          <K2.Row t={t} title="Native Ghostty terminal" sub="experimental · Metal renderer" trailing={<Toggle t={t} on={false} />} />
          <div style={{ height: 1, background: t.border }} />
          <K2.Row t={t} title="Accessory key bar" sub="esc · ctrl · arrows" trailing={<Toggle t={t} on={true} />} />
        </div>

        <K2.SectionLabel t={t}>Agents & accounts</K2.SectionLabel>
        <div style={{ borderRadius: t.radius - 4, overflow: 'hidden', border: `1px solid ${t.border}`, background: t.surface, marginBottom: 16 }}>
          <K2.Row t={t} leading={<K2.Dot color={t.claude} glow={t.glow} size={10} />} title="Anthropic" sub="claude" badge={<span style={{ fontFamily: t.mono, fontSize: 10, color: t.green }}>linked</span>} trailing={K2.I.chevR(t.textFaint, 14)} />
          <div style={{ height: 1, background: t.border }} />
          <K2.Row t={t} leading={<K2.Dot color={t.codex} glow={t.glow} size={10} />} title="OpenAI" sub="codex" badge={<span style={{ fontFamily: t.mono, fontSize: 10, color: t.green }}>linked</span>} trailing={K2.I.chevR(t.textFaint, 14)} />
          <div style={{ height: 1, background: t.border }} />
          <K2.Row t={t} title="Push notifications" sub="when an agent needs you" trailing={<Toggle t={t} on={true} />} />
        </div>

        <div style={{ display: 'flex', gap: 18, justifyContent: 'center', fontFamily: t.mono, fontSize: 11.5, color: t.textFaint, padding: '6px 0' }}>
          <span>Licenses</span><span>Self-host docs</span><span>Sign out</span>
        </div>
      </div>
      <div style={{ height: _botPad(platform) }} />
    </_Screen>
  );
}

Object.assign(window, { HistoryScreen, ConnectScreen, NewSessionScreen, SettingsScreen });
