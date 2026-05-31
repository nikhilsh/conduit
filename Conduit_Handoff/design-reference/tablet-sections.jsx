// tablet-sections.jsx — tablet feature parity: activity bar + Home / History / Pair / Settings
// sections, wrapped in a shell that owns the iPad chrome + palette / session-info overlays.
const TS = window;
const _ngTS = window.neonGlowColor;
const { gT: _gtTS, gB: _gbTS } = window;

// extra nav icons not in the shared kit
const NAV_IC = {
  home: (c, s = 22) => <svg width={s} height={s} viewBox="0 0 24 24" fill="none"><path d="M4 11l8-7 8 7" stroke={c} strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"/><path d="M6 10v9h12v-9" stroke={c} strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"/><path d="M10 19v-5h4v5" stroke={c} strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"/></svg>,
  history: (c, s = 22) => <svg width={s} height={s} viewBox="0 0 24 24" fill="none"><path d="M3.5 12a8.5 8.5 0 102.5-6" stroke={c} strokeWidth="1.8" strokeLinecap="round"/><path d="M6 3v3.5h3.5" stroke={c} strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"/><path d="M12 8v4.2l3 1.8" stroke={c} strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"/></svg>,
  sessions: (c, s = 22) => TS.I.chat(c, s),
  pair: (c, s = 22) => TS.I.server(c, s),
  settings: (c, s = 22) => TS.I.gear(c, s),
};

// ── activity bar (far-left) ──
function TabletActivityBar({ t, section, onPick }) {
  const c = _ngTS(t);
  const items = [['home', 'Home'], ['sessions', 'Sessions'], ['history', 'History'], ['pair', 'Boxes'], ['settings', 'Settings']];
  return (
    <div style={{ width: 84, flexShrink: 0, display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 7, padding: '16px 0',
      borderRight: `1px solid ${t.border}`, background: t.dark ? 'rgba(4,7,14,0.7)' : 'rgba(255,255,255,0.72)' }}>
      <div style={{ marginBottom: 12 }}><TS.ConduitMark t={t} size={28} /></div>
      {items.map(([id, label]) => {
        const on = id === section;
        const col = on ? (t.glow ? c : t.accent) : t.textDim;
        return (
          <button key={id} onClick={() => onPick(id)} title={label} style={{ appearance: 'none', cursor: 'pointer', width: 66, display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 5, padding: '11px 0', borderRadius: 14,
            background: on ? (t.dark ? `${c}1e` : `${t.accent}14`) : 'transparent', border: `1px solid ${on ? (t.glow ? c + '66' : t.accent + '44') : 'transparent'}`,
            boxShadow: on && t.glow ? _gbTS(t, c, 0.45) : 'none', transition: 'all .12s' }}>
            {(NAV_IC[id])(col, 23)}
            <span style={{ fontFamily: t.font, fontSize: 10.5, fontWeight: on ? 700 : 600, color: col, letterSpacing: 0.2 }}>{label}</span>
          </button>
        );
      })}
      <div style={{ marginTop: 'auto', width: 36, height: 36, borderRadius: 99, background: `${TS.agentColor(t, 'claude')}22`, border: `1px solid ${TS.agentColor(t, 'claude')}44`, display: 'flex', alignItems: 'center', justifyContent: 'center', fontFamily: t.mono, fontSize: 12.5, fontWeight: 700, color: TS.agentColor(t, 'claude') }}>NS</div>
    </div>
  );
}

// shared content-area header
function SectionHead({ t, title, sub, actions }) {
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 14, padding: '20px 24px 14px' }}>
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ fontFamily: t.font, fontSize: 22, fontWeight: 750, color: t.text, letterSpacing: 0.2 }}>{title}</div>
        {sub && <div style={{ fontFamily: t.mono, fontSize: 11.5, color: t.textFaint, marginTop: 3 }}>{sub}</div>}
      </div>
      {actions}
    </div>
  );
}

function ConnChip({ t }) {
  return (
    <span style={{ display: 'inline-flex', alignItems: 'center', gap: 7, padding: '8px 13px', borderRadius: 99,
      background: t.glow ? 'rgba(70,224,168,0.08)' : t.surface, border: `1px solid ${t.glow ? t.green + '44' : t.border}`,
      fontFamily: t.mono, fontSize: 11.5, color: t.green, boxShadow: t.glow ? _gbTS(t, t.green, 0.25) : 'none' }}>
      <TS.Dot color={t.green} glow={t.glow} size={6} />mac-studio · 8ms
    </span>
  );
}
function NewBtn({ t }) {
  const c = _ngTS(t);
  return (
    <span style={{ display: 'inline-flex', alignItems: 'center', gap: 8, padding: '9px 16px', borderRadius: 12,
      background: t.glow ? c : t.accent, color: t.accentText, fontFamily: t.font, fontSize: 13.5, fontWeight: 700,
      boxShadow: t.glow ? _gbTS(t, c, 0.7) : 'none' }}>{TS.I.plus(t.accentText, 16)}New session</span>
  );
}

// ── HOME / dashboard ──
function SessionCard({ t, s }) {
  const c = TS.agentColor(t, s.agent);
  const sc = s.status === 'live' ? t.green : s.status === 'paused' ? t.claude : t.textFaint;
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 10, padding: 16, borderRadius: t.radius - 2,
      background: t.surface, border: `1px solid ${t.border}`, boxShadow: t.glow ? _gbTS(t, c, 0.18) : 'none' }}>
      <div style={{ display: 'flex', alignItems: 'flex-start', gap: 11 }}>
        <div style={{ width: 36, height: 36, borderRadius: 10, flexShrink: 0, display: 'flex', alignItems: 'center', justifyContent: 'center', background: `${c}18`, border: `1px solid ${c}38` }}><TS.ConduitMark t={t} size={21} color={c} /></div>
        <div style={{ flex: 1, minWidth: 0 }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 7 }}>
            <span style={{ flex: 1, fontFamily: t.font, fontSize: 15, fontWeight: 650, color: t.text, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{s.name}</span>
            <TS.Dot color={sc} glow={t.glow} size={7} /><span style={{ fontFamily: t.mono, fontSize: 10, color: t.textFaint }}>{s.when}</span>
          </div>
          <div style={{ fontFamily: t.mono, fontSize: 10.5, color: t.textFaint, marginTop: 3 }}><span style={{ color: c }}>{s.agent}</span> · {s.repo}:{s.branch}</div>
        </div>
      </div>
      <div style={{ fontFamily: t.font, fontSize: 12.5, color: t.textDim, lineHeight: 1.45, overflow: 'hidden', textOverflow: 'ellipsis', display: '-webkit-box', WebkitLineClamp: 2, WebkitBoxOrient: 'vertical', minHeight: 36 }}>{s.preview}</div>
      <OutcomeChipsWrap t={t} o={s.outcomes} />
    </div>
  );
}
function OutcomeChipsWrap({ t, o }) { return <TS.OutcomeChips t={t} o={o} />; }

function TabletHome({ t, onOpen }) {
  const active = TS.SESSIONS.filter(s => ['live', 'paused', 'idle'].includes(s.status));
  return (
    <div style={{ flex: 1, display: 'flex', flexDirection: 'column', minWidth: 0 }}>
      <SectionHead t={t} title="Home" sub="3 boxes paired · 2 agents linked" actions={<><ConnChip t={t} /><NewBtn t={t} /></>} />
      <div style={{ flex: 1, overflow: 'auto', padding: '0 24px 24px' }}>
        <TS.SectionLabel t={t}>Active sessions</TS.SectionLabel>
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 14, marginBottom: 24 }}>
          {active.map(s => <SessionCard key={s.id} t={t} s={s} />)}
        </div>
        <TS.SectionLabel t={t}>Boxes</TS.SectionLabel>
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 14 }}>
          {[['mac-studio', '192.168.1.20 · :1977 · mDNS', t.green, 'online'], ['hetzner-box', 'ssh · 49.13.x.x', t.textFaint, 'tap to wake']].map(([n, s, col, st]) => (
            <div key={n} style={{ display: 'flex', alignItems: 'center', gap: 13, padding: '15px 16px', borderRadius: t.radius - 4, background: t.surface, border: `1px solid ${t.border}` }}>
              <div style={{ width: 40, height: 40, borderRadius: 11, display: 'flex', alignItems: 'center', justifyContent: 'center', background: `${col}1c`, border: `1px solid ${col}33` }}>{TS.I.server(col, 19)}</div>
              <div style={{ flex: 1 }}>
                <div style={{ fontFamily: t.font, fontSize: 14.5, fontWeight: 650, color: t.text }}>{n}</div>
                <div style={{ fontFamily: t.mono, fontSize: 10.5, color: t.textFaint }}>{s}</div>
              </div>
              <span style={{ fontFamily: t.mono, fontSize: 11, color: col }}>{st}</span>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}

// ── HISTORY (tablet) ──
function TabletHistory({ t, onSearch }) {
  const c = _ngTS(t);
  const order = ['Today', 'Yesterday', 'This week', 'Earlier'];
  const byGroup = order.map(g => [g, TS.SESSIONS.filter(s => s.group === g)]).filter(([, a]) => a.length);
  return (
    <div style={{ flex: 1, display: 'flex', flexDirection: 'column', minWidth: 0 }}>
      <SectionHead t={t} title="History" sub={`${TS.SESSIONS.length} sessions · grouped by recency`} actions={<NewBtn t={t} />} />
      <div style={{ padding: '0 24px 14px' }}>
        <button onClick={onSearch} style={{ appearance: 'none', cursor: 'pointer', width: '100%', display: 'flex', alignItems: 'center', gap: 11, padding: '12px 16px', borderRadius: 13, textAlign: 'left',
          background: t.dark ? 'rgba(255,255,255,0.05)' : '#fff', border: `1px solid ${t.glow ? c + '40' : t.border}`, boxShadow: t.glow ? _gbTS(t, c, 0.2) : 'none' }}>
          {TS.I.search(t.glow ? c : t.textDim, 18)}
          <span style={{ flex: 1, fontFamily: t.font, fontSize: 14.5, color: t.textFaint }}>Search sessions, repos, branches, messages…</span>
          <span style={{ fontFamily: t.mono, fontSize: 11, color: t.textFaint, padding: '3px 8px', borderRadius: 6, border: `1px solid ${t.border}` }}>⌘K</span>
        </button>
      </div>
      <div style={{ flex: 1, overflow: 'auto', padding: '0 24px 24px' }}>
        {byGroup.map(([g, items]) => (
          <div key={g} style={{ marginBottom: 18 }}>
            <TS.SectionLabel t={t}>{g}</TS.SectionLabel>
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 14 }}>
              {items.map(s => <SessionCard key={s.id} t={t} s={s} />)}
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}

// ── PAIR / BOXES (tablet) ──
function TabletPair({ t }) {
  const c = _ngTS(t);
  return (
    <div style={{ flex: 1, display: 'flex', flexDirection: 'column', minWidth: 0 }}>
      <SectionHead t={t} title="Boxes" sub="pair a machine to run agents on" actions={<span style={{ display: 'inline-flex', alignItems: 'center', gap: 6, fontFamily: t.mono, fontSize: 12, color: t.glow ? c : t.textDim }}><TS.Dot color={t.glow ? c : t.textDim} glow={t.glow} size={6} />scanning…</span>} />
      <div style={{ flex: 1, overflow: 'auto', padding: '0 24px 24px' }}>
        <TS.SectionLabel t={t}>On your network</TS.SectionLabel>
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 14, marginBottom: 24 }}>
          {[['mac-studio', '192.168.1.20 · :1977', true], ['nikhil-mbp', '192.168.1.41 · :1977', false]].map(([n, s, ready]) => (
            <div key={n} style={{ display: 'flex', alignItems: 'center', gap: 13, padding: '16px', borderRadius: t.radius - 4, background: t.surface,
              border: `1px solid ${ready ? (t.glow ? t.green + '55' : t.borderStrong) : t.border}`, boxShadow: ready && t.glow ? _gbTS(t, t.green, 0.3) : 'none' }}>
              <div style={{ width: 42, height: 42, borderRadius: 11, display: 'flex', alignItems: 'center', justifyContent: 'center', background: `${t.green}16`, border: `1px solid ${t.green}33` }}>{TS.I.server(ready ? t.green : t.textDim, 20)}</div>
              <div style={{ flex: 1 }}>
                <div style={{ fontFamily: t.font, fontSize: 15, fontWeight: 650, color: t.text }}>{n}</div>
                <div style={{ fontFamily: t.mono, fontSize: 10.5, color: t.textFaint }}>{s}</div>
              </div>
              <span style={{ padding: '8px 18px', borderRadius: 99, fontFamily: t.font, fontSize: 13, fontWeight: 700,
                background: ready ? (t.glow ? t.green : t.accent) : 'transparent', color: ready ? (t.glow ? '#04140d' : t.accentText) : t.textDim,
                border: ready ? 'none' : `1px solid ${t.border}`, boxShadow: ready && t.glow ? _gbTS(t, t.green, 0.6) : 'none' }}>{ready ? 'Pair' : 'Wake'}</span>
            </div>
          ))}
        </div>
        <TS.SectionLabel t={t}>Connect another way</TS.SectionLabel>
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 14, marginBottom: 24 }}>
          {[[TS.I.ssh, 'SSH bootstrap', 'pair an off-network box over ssh'], [TS.I.qr, 'Scan QR', 'from the broker dashboard']].map(([ic, ti, su], i) => (
            <div key={i} style={{ padding: '18px 16px', borderRadius: t.radius - 4, background: t.surface, border: `1px solid ${t.border}`, display: 'flex', flexDirection: 'column', gap: 9 }}>
              <div style={{ width: 38, height: 38, borderRadius: 10, display: 'flex', alignItems: 'center', justifyContent: 'center', background: t.glow ? `${c}1a` : (t.dark ? 'rgba(255,255,255,0.05)' : 'rgba(0,0,0,0.04)'), border: `1px solid ${t.border}` }}>{ic(t.glow ? c : t.text, 19)}</div>
              <div style={{ fontFamily: t.font, fontSize: 14.5, fontWeight: 700, color: t.text }}>{ti}</div>
              <div style={{ fontFamily: t.mono, fontSize: 11, color: t.textFaint }}>{su}</div>
            </div>
          ))}
        </div>
        <TS.SectionLabel t={t}>Agent sign-in</TS.SectionLabel>
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 14 }}>
          {[['Anthropic', 'claude · OAuth', t.claude, 'linked'], ['OpenAI', 'codex · OAuth', t.codex, 'linked']].map(([n, s, col, st]) => (
            <div key={n} style={{ display: 'flex', alignItems: 'center', gap: 13, padding: '15px 16px', borderRadius: t.radius - 4, background: t.surface, border: `1px solid ${t.border}` }}>
              <div style={{ width: 36, height: 36, borderRadius: 9, background: `${col}1c`, display: 'flex', alignItems: 'center', justifyContent: 'center' }}><TS.Dot color={col} glow={t.glow} size={10} /></div>
              <div style={{ flex: 1 }}>
                <div style={{ fontFamily: t.font, fontSize: 14.5, fontWeight: 650, color: t.text }}>{n}</div>
                <div style={{ fontFamily: t.mono, fontSize: 10.5, color: t.textFaint }}>{s}</div>
              </div>
              <span style={{ fontFamily: t.mono, fontSize: 11, color: t.green, padding: '3px 9px', borderRadius: 99, background: `${t.green}1a` }}>{st}</span>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}

// ── SETTINGS (tablet) — appearance controls drive the real theme ──
function TabletSettings({ t, tw, setTweak }) {
  const c = _ngTS(t);
  const PAL = TS.NEON_PALETTES;
  const Seg = ({ value, options, onPick }) => (
    <div style={{ display: 'flex', gap: 4, padding: 3, borderRadius: 11, background: t.dark ? 'rgba(0,0,0,0.3)' : 'rgba(13,26,48,0.06)', border: `1px solid ${t.border}` }}>
      {options.map(o => {
        const on = o === value;
        return <button key={o} onClick={() => onPick(o)} style={{ appearance: 'none', cursor: 'pointer', flex: 1, padding: '8px 14px', borderRadius: 8,
          background: on ? (t.dark ? `${c}22` : '#fff') : 'transparent', border: on ? `1px solid ${t.dark ? c + '66' : t.accent + '44'}` : '1px solid transparent',
          color: on ? (t.dark ? c : t.accent) : t.textDim, fontFamily: t.font, fontSize: 13, fontWeight: on ? 700 : 500, textTransform: 'capitalize',
          boxShadow: on && t.glow ? `0 0 12px ${c}33` : 'none', transition: 'all .12s' }}>{o}</button>;
      })}
    </div>
  );
  const Switch = ({ on, onToggle }) => (
    <button onClick={onToggle} style={{ appearance: 'none', cursor: 'pointer', width: 46, height: 28, borderRadius: 99, padding: 3, border: 'none', display: 'flex', alignItems: 'center', justifyContent: on ? 'flex-end' : 'flex-start',
      background: on ? (t.dark ? c : t.accent) : (t.dark ? 'rgba(255,255,255,0.14)' : 'rgba(13,26,48,0.16)'), boxShadow: on && t.glow ? `0 0 14px ${c}88` : 'none', transition: 'all .15s' }}>
      <span style={{ width: 22, height: 22, borderRadius: 99, background: '#fff', boxShadow: '0 1px 3px rgba(0,0,0,0.3)' }} />
    </button>
  );
  const card = { borderRadius: t.radius - 4, overflow: 'hidden', border: `1px solid ${t.border}`, background: t.surface };
  const rowPad = { padding: '14px 16px' };
  const accountRow = (n, s, col) => (
    <TS.Row t={t} leading={<TS.Dot color={col} glow={t.glow} size={10} />} title={n} sub={s} badge={<span style={{ fontFamily: t.mono, fontSize: 10, color: t.green }}>linked</span>} trailing={TS.I.chevR(t.textFaint, 14)} />
  );
  return (
    <div style={{ flex: 1, display: 'flex', flexDirection: 'column', minWidth: 0 }}>
      <SectionHead t={t} title="Settings" sub="v1.4.0 · broker :1977" actions={<span style={{ display: 'inline-flex', alignItems: 'center', gap: 6, fontFamily: t.mono, fontSize: 11.5, color: t.green }}><TS.Dot color={t.green} glow={t.glow} size={6} />synced</span>} />
      <div style={{ flex: 1, overflow: 'auto', padding: '0 24px 24px' }}>
        <div style={{ display: 'grid', gridTemplateColumns: '1.3fr 1fr', gap: 20, alignItems: 'start' }}>
          {/* left column: appearance */}
          <div>
            <TS.SectionLabel t={t}>Appearance</TS.SectionLabel>
            <div style={card}>
              <div style={rowPad}>
                <div style={{ fontFamily: t.font, fontSize: 14.5, fontWeight: 600, color: t.text, marginBottom: 10 }}>Mode</div>
                <Seg value={tw.mode} options={['dark', 'light']} onPick={v => setTweak('mode', v)} />
              </div>
              <div style={{ height: 1, background: t.border }} />
              <div style={rowPad}>
                <div style={{ display: 'flex', alignItems: 'baseline', justifyContent: 'space-between', marginBottom: 12 }}>
                  <span style={{ fontFamily: t.font, fontSize: 14.5, fontWeight: 600, color: t.text }}>Accent palette</span>
                  <span style={{ fontFamily: t.mono, fontSize: 11.5, color: t.accent }}>{PAL[tw.palette].label}</span>
                </div>
                <div style={{ display: 'flex', gap: 12 }}>
                  {Object.entries(PAL).map(([id, p]) => {
                    const on = id === tw.palette;
                    return (
                      <button key={id} onClick={() => setTweak('palette', id)} style={{ appearance: 'none', cursor: 'pointer', flex: 1, display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 7, padding: '4px 0', background: 'none', border: 'none' }}>
                        <span style={{ width: 44, height: 44, borderRadius: 13, background: `linear-gradient(135deg, ${p.accent}, ${p.accent2})`, border: on ? `2px solid ${t.text}` : `1px solid ${t.border}`, boxShadow: on ? `0 0 0 2px ${p.accent}, 0 0 16px ${p.accent}88` : 'none', transition: 'all .12s' }} />
                        <span style={{ fontFamily: t.mono, fontSize: 10, color: on ? t.text : t.textFaint, fontWeight: on ? 700 : 400 }}>{p.label}</span>
                      </button>
                    );
                  })}
                </div>
              </div>
              <div style={{ height: 1, background: t.border }} />
              <div style={{ ...rowPad, display: 'flex', alignItems: 'center', gap: 12 }}>
                <div style={{ flex: 1 }}>
                  <div style={{ fontFamily: t.font, fontSize: 14.5, fontWeight: 600, color: t.text }}>Glow &amp; scanlines</div>
                  <div style={{ fontFamily: t.mono, fontSize: 11, color: t.textFaint, marginTop: 2 }}>neon halos · {t.dark ? 'on dark' : 'dimmed in light'}</div>
                </div>
                <Switch on={tw.glow} onToggle={() => setTweak('glow', !tw.glow)} />
              </div>
            </div>
            {/* live preview chip */}
            <div style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '12px 14px', borderRadius: 12, marginTop: 16,
              background: t.codeBg, border: `1px solid ${t.borderStrong}`, boxShadow: t.glow ? _gbTS(t, c, 0.33) : 'none' }}>
              <span style={{ fontFamily: t.mono, fontSize: 13, color: c, textShadow: _gtTS(t, c, 0.6) }}>$</span>
              <span style={{ flex: 1, fontFamily: t.mono, fontSize: 12.5, color: t.codeText || t.text }}>conduit --theme {tw.palette} {tw.mode}</span>
              <span style={{ fontFamily: t.mono, fontSize: 11, color: t.green }}>preview</span>
            </div>
          </div>
          {/* right column: terminal + agents */}
          <div>
            <TS.SectionLabel t={t}>Terminal</TS.SectionLabel>
            <div style={{ ...card, marginBottom: 18 }}>
              <div style={{ ...rowPad, display: 'flex', alignItems: 'center', gap: 12 }}>
                <div style={{ flex: 1 }}><div style={{ fontFamily: t.font, fontSize: 14.5, fontWeight: 600, color: t.text }}>Native Ghostty</div><div style={{ fontFamily: t.mono, fontSize: 11, color: t.textFaint, marginTop: 2 }}>Metal renderer</div></div>
                <Switch on={false} onToggle={() => {}} />
              </div>
              <div style={{ height: 1, background: t.border }} />
              <div style={{ ...rowPad, display: 'flex', alignItems: 'center', gap: 12 }}>
                <div style={{ flex: 1 }}><div style={{ fontFamily: t.font, fontSize: 14.5, fontWeight: 600, color: t.text }}>Accessory key bar</div><div style={{ fontFamily: t.mono, fontSize: 11, color: t.textFaint, marginTop: 2 }}>esc · ctrl · arrows</div></div>
                <Switch on={true} onToggle={() => {}} />
              </div>
            </div>
            <TS.SectionLabel t={t}>Agents &amp; accounts</TS.SectionLabel>
            <div style={card}>
              {accountRow('Anthropic', 'claude', t.claude)}
              <div style={{ height: 1, background: t.border }} />
              {accountRow('OpenAI', 'codex', t.codex)}
              <div style={{ height: 1, background: t.border }} />
              <div style={{ ...rowPad, display: 'flex', alignItems: 'center', gap: 12 }}>
                <div style={{ flex: 1 }}><div style={{ fontFamily: t.font, fontSize: 14.5, fontWeight: 600, color: t.text }}>Push notifications</div><div style={{ fontFamily: t.mono, fontSize: 11, color: t.textFaint, marginTop: 2 }}>when an agent needs you</div></div>
                <Switch on={true} onToggle={() => {}} />
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}

// ── shell: chrome + section routing + overlays ──
function TabletShell({ t, tw, setTweak }) {
  const [section, setSection] = React.useState(() => localStorage.getItem('nk_tab_section') || 'sessions');
  const pick = (s) => { setSection(s); localStorage.setItem('nk_tab_section', s); };
  const [activeId, setActiveId] = React.useState('s1');
  const [pal, setPal] = React.useState(false);
  return (
    <div style={{ position: 'absolute', inset: 0, display: 'flex', flexDirection: 'column' }}>
      {/* iPad status bar */}
      <div style={{ height: 26, flexShrink: 0, display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '0 22px', fontFamily: t.mono, fontSize: 12, fontWeight: 600, color: t.text }}>
        <span>9:41</span>
        <span style={{ display: 'flex', gap: 7, alignItems: 'center', opacity: 0.85 }}>{TS.I.wifi(t.text, 15)}<span style={{ fontSize: 11 }}>100%</span></span>
      </div>
      <div style={{ flex: 1, display: 'flex', minHeight: 0 }}>
        <TabletActivityBar t={t} section={section} onPick={pick} />
        {section === 'home' && <TabletHome t={t} onOpen={() => pick('sessions')} />}
        {section === 'sessions' && <TS.TabletSessionView t={t} activeId={activeId} onPick={setActiveId} onSearch={() => setPal(true)} />}
        {section === 'history' && <TabletHistory t={t} onSearch={() => setPal(true)} />}
        {section === 'pair' && <TabletPair t={t} />}
        {section === 'settings' && <TabletSettings t={t} tw={tw} setTweak={setTweak} />}
      </div>
      {pal && <TS.CommandPalette t={t} platform="ios" onClose={() => setPal(false)} />}
    </div>
  );
}

function TabletApp({ t, tw, setTweak }) {
  return (
    <TS.ScaleToFit designW={1194} designH={834} maxScale={1}>
      <TS.TabletFrame t={t}><TabletShell t={t} tw={tw} setTweak={setTweak} /></TS.TabletFrame>
    </TS.ScaleToFit>
  );
}

Object.assign(window, { TabletActivityBar, TabletHome, TabletHistory, TabletPair, TabletSettings, TabletShell, TabletApp });
