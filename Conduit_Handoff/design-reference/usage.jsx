// usage.jsx — Session Info panel + two usage-card variations.
// Opened from the top-right of a session (a glanceable context chip).
// Shows: context-window fill for the session, tokens (in / out / cache),
// and plan limits (Claude weekly · Codex quota) with a resets countdown.
const NU = window;
const { gT: _gtU, gB: _gbU } = window;        // neon glow helpers from neon-cards
const _ngU = window.neonGlowColor;

// ── data the cards + chip all read from (one source of truth) ──
const SESSION_USAGE = {
  contextUsed: 68200, contextMax: 200000,        // active agent's window
  activeAgent: 'claude', model: 'sonnet-4.5',
  tokens: { in: 184000, out: 42600, cache: 1240000 },
  cost: 2.41, turns: 18, duration: '41m', burn: '3.8k/turn',
  plans: {
    claude: { label: 'Max 20×',  used: 0.62, resets: '2d 4h' },
    codex:  { label: 'Pro',      used: 0.28, resets: '5h 12m' },
  },
};

function fmtK(n) {
  if (n >= 1e6) return (n / 1e6).toFixed(n >= 1e7 ? 0 : 1) + 'M';
  if (n >= 1e3) return Math.round(n / 1e3) + 'k';
  return '' + n;
}
const pct = (u, m) => Math.round((u / m) * 100);

// ── glanceable context ring chip (sits in the session header) ──
function UsageChip({ t, onTap }) {
  const u = SESSION_USAGE;
  const p = pct(u.contextUsed, u.contextMax);
  const c = _ngU(t);
  const R = 8, C = 2 * Math.PI * R, dash = (p / 100) * C;
  return (
    <button onClick={onTap} style={{ appearance: 'none', cursor: 'pointer', display: 'inline-flex', alignItems: 'center', gap: 7,
      padding: '5px 9px 5px 6px', borderRadius: 99, background: t.dark ? 'rgba(255,255,255,0.06)' : 'rgba(0,0,0,0.04)',
      border: `1px solid ${t.glow ? c + '44' : t.border}`, boxShadow: t.glow ? _gbU(t, c, 0.3) : 'none', flexShrink: 0 }}>
      <svg width="22" height="22" viewBox="0 0 22 22" style={{ transform: 'rotate(-90deg)' }}>
        <circle cx="11" cy="11" r={R} fill="none" stroke={t.border} strokeWidth="2.4" />
        <circle cx="11" cy="11" r={R} fill="none" stroke={c} strokeWidth="2.4" strokeLinecap="round"
          strokeDasharray={`${dash} ${C}`} style={{ filter: t.glow ? `drop-shadow(0 0 3px ${c})` : 'none' }} />
      </svg>
      <span style={{ fontFamily: t.mono, fontSize: 11.5, fontWeight: 700, color: t.glow ? c : t.text, textShadow: _gtU(t, c, 0.4) }}>{p}%</span>
    </button>
  );
}

// ── small primitives ──────────────────────────────────────────
function MeterBar({ t, value, color, h = 6, track }) {
  const c = color || _ngU(t);
  return (
    <div style={{ height: h, borderRadius: 99, background: track || t.border, overflow: 'hidden' }}>
      <div style={{ width: `${Math.min(100, value * 100)}%`, height: '100%', borderRadius: 99,
        background: c, boxShadow: t.glow ? `0 0 8px ${_ngU(t, c)}` : 'none' }} />
    </div>
  );
}

function ResetChip({ t, when }) {
  return (
    <span style={{ display: 'inline-flex', alignItems: 'center', gap: 4, fontFamily: t.mono, fontSize: 10, color: t.textFaint,
      padding: '2px 7px', borderRadius: 99, border: `1px solid ${t.border}` }}>
      <svg width="10" height="10" viewBox="0 0 12 12" fill="none"><circle cx="6" cy="6.5" r="4.4" stroke={t.textFaint} strokeWidth="1.2" /><path d="M6 4v2.6l1.6 1" stroke={t.textFaint} strokeWidth="1.2" strokeLinecap="round" /></svg>
      resets {when}
    </span>
  );
}

// agent plan row (shared between both variants)
function PlanRow({ t, agent, mono }) {
  const c = NU.agentColor(t, agent);
  const pl = SESSION_USAGE.plans[agent];
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
        <NU.Dot color={c} glow={t.glow} size={8} />
        <span style={{ fontFamily: t.mono, fontSize: 12.5, fontWeight: 700, color: c, textShadow: _gtU(t, c, 0.4) }}>{agent}</span>
        <span style={{ fontFamily: t.mono, fontSize: 10.5, color: t.textFaint }}>{pl.label}</span>
        <span style={{ marginLeft: 'auto', fontFamily: t.mono, fontSize: 11.5, fontWeight: 700, color: t.text }}>{Math.round(pl.used * 100)}%</span>
      </div>
      <MeterBar t={t} value={pl.used} color={c} h={mono ? 7 : 6} />
      <div style={{ display: 'flex', justifyContent: 'flex-end' }}><ResetChip t={t} when={pl.resets} /></div>
    </div>
  );
}

// ═══ VARIATION A — "Dashboard": big context ring + stat tiles ══
function UsageCardA({ t }) {
  const u = SESSION_USAGE;
  const c = _ngU(t);
  const p = pct(u.contextUsed, u.contextMax);
  const R = 52, SW = 11, C = 2 * Math.PI * R, dash = (p / 100) * C;
  const tok = [['in', u.tokens.in, t.blue], ['out', u.tokens.out, t.green], ['cache', u.tokens.cache, t.purple]];
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>
      {/* context ring */}
      <div style={{ display: 'flex', alignItems: 'center', gap: 18, padding: '16px 16px', borderRadius: t.radius - 4,
        background: t.surface, border: `1px solid ${t.border}`, boxShadow: t.glow ? _gbU(t, c, 0.3) : 'none' }}>
        <div style={{ position: 'relative', width: 128, height: 128, flexShrink: 0 }}>
          <svg width="128" height="128" viewBox="0 0 128 128" style={{ transform: 'rotate(-90deg)' }}>
            <circle cx="64" cy="64" r={R} fill="none" stroke={t.border} strokeWidth={SW} />
            <circle cx="64" cy="64" r={R} fill="none" stroke={c} strokeWidth={SW} strokeLinecap="round"
              strokeDasharray={`${dash} ${C}`} style={{ filter: t.glow ? `drop-shadow(0 0 6px ${c})` : 'none' }} />
          </svg>
          <div style={{ position: 'absolute', inset: 0, display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', gap: 1 }}>
            <span style={{ fontFamily: t.mono, fontSize: 30, fontWeight: 700, color: t.text, lineHeight: 1, textShadow: _gtU(t, c, 0.4) }}>{p}<span style={{ fontSize: 15, color: t.textDim }}>%</span></span>
            <span style={{ fontFamily: t.mono, fontSize: 10, color: t.textFaint, letterSpacing: 0.5 }}>context</span>
          </div>
        </div>
        <div style={{ flex: 1 }}>
          <div style={{ fontFamily: t.mono, fontSize: 11, letterSpacing: 1.2, textTransform: 'uppercase', color: t.textFaint, marginBottom: 6 }}>window</div>
          <div style={{ fontFamily: t.mono, fontSize: 20, fontWeight: 700, color: t.text }}>{fmtK(u.contextUsed)} <span style={{ color: t.textFaint, fontWeight: 500 }}>/ {fmtK(u.contextMax)}</span></div>
          <div style={{ fontFamily: t.mono, fontSize: 11.5, color: t.textDim, marginTop: 6 }}>{fmtK(u.contextMax - u.contextUsed)} left · {u.model}</div>
          <div style={{ display: 'inline-flex', alignItems: 'center', gap: 6, marginTop: 11, padding: '4px 10px', borderRadius: 99, background: `${NU.agentColor(t, u.activeAgent)}1c`, border: `1px solid ${NU.agentColor(t, u.activeAgent)}44` }}>
            <NU.Dot color={NU.agentColor(t, u.activeAgent)} glow={t.glow} size={6} />
            <span style={{ fontFamily: t.mono, fontSize: 10.5, color: NU.agentColor(t, u.activeAgent) }}>active</span>
          </div>
        </div>
      </div>

      {/* token tiles */}
      <div>
        <div style={{ display: 'flex', alignItems: 'baseline', justifyContent: 'space-between', marginBottom: 8, padding: '0 2px' }}>
          <span style={{ fontFamily: t.mono, fontSize: 11, letterSpacing: 1.2, textTransform: 'uppercase', color: t.textFaint }}>tokens · session</span>
          <span style={{ fontFamily: t.mono, fontSize: 11, color: t.textDim }}>${u.cost.toFixed(2)} · {u.burn}</span>
        </div>
        <div style={{ display: 'flex', gap: 9 }}>
          {tok.map(([label, n, col]) => (
            <div key={label} style={{ flex: 1, padding: '11px 12px', borderRadius: 13, background: t.surface, border: `1px solid ${t.border}` }}>
              <div style={{ display: 'flex', alignItems: 'center', gap: 6, marginBottom: 7 }}>
                <NU.Dot color={col} glow={t.glow} size={6} />
                <span style={{ fontFamily: t.mono, fontSize: 10.5, color: t.textFaint }}>{label}</span>
              </div>
              <div style={{ fontFamily: t.mono, fontSize: 18, fontWeight: 700, color: t.text }}>{fmtK(n)}</div>
            </div>
          ))}
        </div>
      </div>

      {/* plan limits */}
      <div>
        <div style={{ fontFamily: t.mono, fontSize: 11, letterSpacing: 1.2, textTransform: 'uppercase', color: t.textFaint, marginBottom: 11, padding: '0 2px' }}>plan limits</div>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 15, padding: '15px 15px', borderRadius: t.radius - 4, background: t.surface, border: `1px solid ${t.border}` }}>
          <PlanRow t={t} agent="claude" />
          <div style={{ height: 1, background: t.border }} />
          <PlanRow t={t} agent="codex" />
        </div>
      </div>
    </div>
  );
}

// ═══ VARIATION B — "Terminal readout": dense mono dashboard ════
function UsageCardB({ t }) {
  const u = SESSION_USAGE;
  const c = _ngU(t);
  const p = pct(u.contextUsed, u.contextMax);
  const codeText = t.codeText || t.text;
  const dim = t.dark ? 'rgba(170,194,235,0.55)' : 'rgba(120,150,200,0.85)';
  const SEG = 28, on = Math.round((p / 100) * SEG);
  const totalTok = u.tokens.in + u.tokens.out + u.tokens.cache;
  const tok = [['in', u.tokens.in, t.blue], ['out', u.tokens.out, t.green], ['cache', u.tokens.cache, t.purple]];

  const Line = ({ children, mb = 0 }) => <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: mb, fontFamily: t.mono, fontSize: 12, color: codeText }}>{children}</div>;

  return (
    <div style={{ borderRadius: t.radius - 4, overflow: 'hidden', background: t.codeBg, border: `1px solid ${t.borderStrong}`,
      boxShadow: t.glow ? _gbU(t, c, 0.45) : '0 6px 22px rgba(13,26,48,0.18)' }}>
      {/* title bar */}
      <div style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '10px 14px', borderBottom: `1px solid ${t.dark ? 'rgba(120,160,220,0.12)' : 'rgba(120,160,220,0.2)'}` }}>
        <span style={{ fontFamily: t.mono, fontSize: 12.5, color: c, textShadow: _gtU(t, c, 0.6) }}>$</span>
        <span style={{ flex: 1, fontFamily: t.mono, fontSize: 12, color: codeText }}>conduit usage --session</span>
        <span style={{ fontFamily: t.mono, fontSize: 10.5, color: t.green }}>{u.duration} · {u.turns} turns</span>
      </div>

      <div style={{ padding: '14px 14px 16px' }}>
        {/* context bar */}
        <Line mb={6}><span style={{ color: dim, width: 58 }}>context</span>
          <span style={{ flex: 1, letterSpacing: 1, color: c, textShadow: _gtU(t, c, 0.5), whiteSpace: 'nowrap', overflow: 'hidden' }}>
            {'█'.repeat(on)}<span style={{ color: t.dark ? 'rgba(120,160,220,0.28)' : 'rgba(120,150,200,0.4)' }}>{'░'.repeat(SEG - on)}</span>
          </span>
          <span style={{ fontWeight: 700, color: codeText }}>{p}%</span>
        </Line>
        <div style={{ display: 'flex', justifyContent: 'space-between', fontFamily: t.mono, fontSize: 10.5, color: dim, marginBottom: 16, paddingLeft: 66 }}>
          <span>{fmtK(u.contextUsed)} / {fmtK(u.contextMax)} · {u.model}</span>
          <span>{fmtK(u.contextMax - u.contextUsed)} free</span>
        </div>

        {/* token stacked bar */}
        <div style={{ fontFamily: t.mono, fontSize: 10.5, color: dim, marginBottom: 7 }}>tokens · {fmtK(totalTok)} total · ${u.cost.toFixed(2)}</div>
        <div style={{ display: 'flex', height: 12, borderRadius: 4, overflow: 'hidden', marginBottom: 9, border: `1px solid ${t.dark ? 'rgba(120,160,220,0.18)' : 'rgba(120,160,220,0.25)'}` }}>
          {tok.map(([label, n, col]) => (
            <div key={label} style={{ width: `${(n / totalTok) * 100}%`, background: col, boxShadow: t.glow ? `0 0 8px ${col}` : 'none' }} />
          ))}
        </div>
        <div style={{ display: 'flex', gap: 16, marginBottom: 18 }}>
          {tok.map(([label, n, col]) => (
            <span key={label} style={{ display: 'inline-flex', alignItems: 'center', gap: 6, fontFamily: t.mono, fontSize: 11, color: codeText }}>
              <span style={{ width: 9, height: 9, borderRadius: 2, background: col }} />{label} <span style={{ color: dim }}>{fmtK(n)}</span>
            </span>
          ))}
        </div>

        {/* plan limits */}
        <div style={{ fontFamily: t.mono, fontSize: 10.5, color: dim, marginBottom: 9 }}>plan limits</div>
        {['claude', 'codex'].map((agent, i) => {
          const col = NU.agentColor(t, agent); const pl = u.plans[agent];
          const segOn = Math.round(pl.used * 18);
          return (
            <div key={agent} style={{ display: 'flex', alignItems: 'center', gap: 9, marginBottom: i === 0 ? 9 : 0, fontFamily: t.mono, fontSize: 11.5 }}>
              <span style={{ width: 54, color: col, fontWeight: 700, textShadow: _gtU(t, col, 0.4) }}>{agent}</span>
              <span style={{ flex: 1, letterSpacing: 1, color: col }}>
                {'▓'.repeat(segOn)}<span style={{ color: t.dark ? 'rgba(120,160,220,0.28)' : 'rgba(120,150,200,0.4)' }}>{'░'.repeat(18 - segOn)}</span>
              </span>
              <span style={{ width: 32, textAlign: 'right', color: codeText, fontWeight: 700 }}>{Math.round(pl.used * 100)}%</span>
              <span style={{ width: 66, textAlign: 'right', color: dim, fontSize: 10 }}>↺ {pl.resets}</span>
            </div>
          );
        })}
      </div>
    </div>
  );
}

// ── Session Info body: identity + A/B switch + the usage card ──
function SessionInfoBody({ t, variant, onVariant, compact }) {
  const u = SESSION_USAGE;
  const c = _ngU(t);
  const Seg = () => (
    <div style={{ display: 'flex', gap: 4, padding: 3, borderRadius: 11, background: t.dark ? 'rgba(0,0,0,0.3)' : 'rgba(13,26,48,0.06)', border: `1px solid ${t.border}` }}>
      {[['A', 'Visual'], ['B', 'Terminal']].map(([v, label]) => {
        const sel = v === variant;
        return (
          <button key={v} onClick={() => onVariant(v)} style={{ appearance: 'none', cursor: 'pointer', flex: 1, padding: '6px 12px', borderRadius: 8,
            background: sel ? (t.dark ? `${c}22` : '#fff') : 'transparent', border: sel ? `1px solid ${t.dark ? c + '66' : c + '44'}` : '1px solid transparent',
            color: sel ? (t.dark ? c : t.accent) : t.textDim, fontFamily: t.font, fontSize: 12, fontWeight: sel ? 700 : 500,
            boxShadow: sel && t.glow ? `0 0 12px ${c}33` : 'none', transition: 'all .12s' }}>{label}</button>
        );
      })}
    </div>
  );
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>
      {/* session identity */}
      <div style={{ display: 'flex', alignItems: 'center', gap: 11, padding: '13px 14px', borderRadius: t.radius - 4, background: t.surface, border: `1px solid ${t.border}` }}>
        <NU.Avatar t={t} agent={u.activeAgent} size={36} glow />
        <div style={{ flex: 1, minWidth: 0 }}>
          <div style={{ fontFamily: t.font, fontSize: 15, fontWeight: 700, color: t.text, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>Fix auth refresh loop</div>
          <div style={{ display: 'flex', alignItems: 'center', gap: 7, fontFamily: t.mono, fontSize: 10.5, color: t.textFaint, marginTop: 3 }}>
            <span style={{ color: NU.agentColor(t, 'claude') }}>claude</span>
            <span style={{ display: 'inline-flex', alignItems: 'center', gap: 3 }}>{NU.I.branch(t.textFaint, 10)}envoy-api:fix/auth</span>
          </div>
        </div>
        <span style={{ display: 'inline-flex', alignItems: 'center', gap: 5, fontFamily: t.mono, fontSize: 10.5, color: t.green }}><NU.Dot color={t.green} glow={t.glow} size={6} />live</span>
      </div>

      {/* variant switch */}
      <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
        <span style={{ fontFamily: t.mono, fontSize: 11, letterSpacing: 1, textTransform: 'uppercase', color: t.textFaint }}>usage</span>
        <div style={{ flex: 1 }} />
        <div style={{ width: 168 }}><Seg /></div>
      </div>

      {variant === 'A' ? <UsageCardA t={t} /> : <UsageCardB t={t} />}

      {/* session detail rows */}
      <div style={{ borderRadius: t.radius - 4, overflow: 'hidden', border: `1px solid ${t.border}`, background: t.surface }}>
        <NU.Row t={t} leading={NU.I.folder(t.textDim, 16)} title="~/dev/envoy-api" sub="working directory" trailing={NU.I.chevR(t.textFaint, 14)} />
        <div style={{ height: 1, background: t.border }} />
        <NU.Row t={t} leading={NU.I.server(t.textDim, 16)} title="mac-studio" sub="broker :1977 · 8ms" trailing={<span style={{ fontFamily: t.mono, fontSize: 11, color: t.green }}>online</span>} />
      </div>

      {/* actions */}
      <div style={{ display: 'flex', gap: 9 }}>
        {[['Fork', NU.I.fork], ['Export log', NU.I.file]].map(([label, ic]) => (
          <div key={label} style={{ flex: 1, display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 7, padding: '11px', borderRadius: 12,
            background: t.surface, border: `1px solid ${t.border}`, fontFamily: t.font, fontSize: 13, fontWeight: 600, color: t.textDim }}>
            {ic(t.textDim, 15)}{label}
          </div>
        ))}
        <div style={{ flex: 1, display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 7, padding: '11px', borderRadius: 12,
          border: `1px solid ${t.red}55`, fontFamily: t.font, fontSize: 13, fontWeight: 600, color: t.red }}>
          {NU.I.trash(t.red, 15)}End
        </div>
      </div>
    </div>
  );
}

// ── Phone overlay sheet (slides up over the chat) ──────────────
function SessionInfoSheet({ t, platform, onClose }) {
  const [variant, setVariant] = React.useState(() => localStorage.getItem('nk_usage_variant') || 'A');
  const setV = (v) => { setVariant(v); localStorage.setItem('nk_usage_variant', v); };
  return (
    <div onClick={onClose} style={{ position: 'absolute', inset: 0, zIndex: 60, display: 'flex', flexDirection: 'column', justifyContent: 'flex-end',
      background: t.dark ? 'rgba(0,0,0,0.5)' : 'rgba(20,30,52,0.32)', backdropFilter: 'blur(2px)', WebkitBackdropFilter: 'blur(2px)' }}>
      <div onClick={(e) => e.stopPropagation()} style={{ maxHeight: '88%', display: 'flex', flexDirection: 'column', borderRadius: '26px 26px 0 0',
        background: t.surfaceSolid, borderTop: `1px solid ${t.borderStrong}`, boxShadow: '0 -20px 50px rgba(0,0,0,0.45)' }}>
        <div style={{ padding: '12px 16px 8px', flexShrink: 0 }}>
          <div style={{ width: 38, height: 5, borderRadius: 99, background: t.textFaint, opacity: 0.5, margin: '0 auto 12px' }} />
          <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
            <span style={{ fontFamily: t.font, fontSize: 18, fontWeight: 750, color: t.text }}>Session info</span>
            <button onClick={onClose} style={{ marginLeft: 'auto', appearance: 'none', cursor: 'pointer', width: 30, height: 30, borderRadius: 99, border: `1px solid ${t.border}`, background: 'transparent', color: t.textDim, fontFamily: t.mono, fontSize: 15, lineHeight: 1 }}>✕</button>
          </div>
        </div>
        <div style={{ flex: 1, overflow: 'auto', padding: `4px 16px ${NU.botPad(platform) + 14}px` }}>
          <SessionInfoBody t={t} variant={variant} onVariant={setV} />
        </div>
      </div>
    </div>
  );
}

Object.assign(window, { SESSION_USAGE, fmtK, UsageChip, UsageCardA, UsageCardB, SessionInfoBody, SessionInfoSheet, MeterBar });
