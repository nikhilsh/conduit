// kit2.jsx — chat message + composer + terminal components.
// Depends on kit.jsx (I, Dot, NavBtn, agentColor) + themes.jsx (glowText, glowBox).

const { I: _I, Dot: _Dot, agentColor: _agentColor } = window;
const { glowText: _gt, glowBox: _gb } = window;

// ── User message bubble ───────────────────────────────────────
function UserBubble({ t, children }) {
  return (
    <div style={{ display: 'flex', justifyContent: 'flex-end', marginBottom: 4 }}>
      <div style={{ maxWidth: '82%', padding: '9px 13px', borderRadius: '16px 16px 5px 16px',
        background: t.glow ? `linear-gradient(135deg, ${t.accent2}, ${t.accent2}cc)` : (t.dark ? t.accent2 : t.accent),
        color: t.glow ? '#06121f' : (t.dark ? '#0a1226' : t.accentText),
        fontFamily: t.font, fontSize: 14.5, lineHeight: 1.45, fontWeight: 500,
        boxShadow: t.glow ? _gb(t, t.accent2, 0.7) : 'none' }}>
        {children}
      </div>
    </div>
  );
}

// ── Assistant prose — set in readable SANS (the key readability fix) ─
function Assistant({ t, children, partial }) {
  return (
    <div style={{ fontFamily: t.font, fontSize: 14.5, lineHeight: 1.55, color: t.text, margin: '2px 2px 6px', maxWidth: '94%' }}>
      {children}
      {partial && <span style={{ display: 'inline-block', width: 7, height: 15, background: t.accent, marginLeft: 3, borderRadius: 1, verticalAlign: -2, boxShadow: _gt(t, t.accent, 0.8) }} />}
    </div>
  );
}
// inline code/path token inside prose
function Code({ t, children }) {
  return <span style={{ fontFamily: t.mono, fontSize: 12.8, padding: '1px 5px', borderRadius: 5,
    background: t.dark ? 'rgba(255,255,255,0.08)' : 'rgba(40,33,22,0.07)', color: t.glow ? t.accent : t.text }}>{children}</span>;
}

// ── Typed tool card (icon + human label + duration + expand) ──
function ToolCard({ t, kind = 'bash', label, meta, ms, open, children, ok = true }) {
  const map = { bash: [_I.bash, t.green], read: [_I.file, t.blue], edit: [_I.edit, t.claude], search: [_I.search, t.purple] };
  const [icon, c] = map[kind] || map.bash;
  return (
    <div style={{ margin: '6px 2px', borderRadius: 13, overflow: 'hidden',
      background: t.surface, border: `1px solid ${t.border}`,
      boxShadow: t.glow ? _gb(t, c, 0.32) : 'none' }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 9, padding: '9px 12px' }}>
        <div style={{ width: 22, height: 22, borderRadius: 6, display: 'flex', alignItems: 'center', justifyContent: 'center',
          background: `${c}1f`, border: `1px solid ${c}3a`, flexShrink: 0 }}>{icon(c, 14)}</div>
        <div style={{ flex: 1, minWidth: 0 }}>
          <div style={{ fontFamily: t.font, fontSize: 13, fontWeight: 600, color: t.text, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{label}</div>
          {meta && <div style={{ fontFamily: t.mono, fontSize: 11, color: t.textFaint, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{meta}</div>}
        </div>
        {ms != null && <span style={{ fontFamily: t.mono, fontSize: 11, color: ok ? t.green : t.red }}>{ms}</span>}
        <span style={{ transform: open ? 'rotate(0deg)' : 'rotate(-90deg)', transition: 'transform .15s' }}>{_I.chevD(t.textFaint, 14)}</span>
      </div>
      {open && children && (
        <div style={{ borderTop: `1px solid ${t.border}`, background: t.dark ? 'rgba(0,0,0,0.25)' : 'rgba(40,33,22,0.03)', padding: '9px 12px',
          fontFamily: t.mono, fontSize: 11.5, lineHeight: 1.55, color: t.textDim, whiteSpace: 'pre-wrap' }}>
          {children}
        </div>
      )}
    </div>
  );
}

// ── Diff card (real per-file diff, not raw M/m) ───────────────
function DiffCard({ t, file, added, removed, lines }) {
  return (
    <div style={{ margin: '6px 2px', borderRadius: 13, overflow: 'hidden', background: t.surface, border: `1px solid ${t.border}`,
      boxShadow: t.glow ? _gb(t, t.claude, 0.3) : 'none' }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '9px 12px', borderBottom: `1px solid ${t.border}` }}>
        {_I.edit(t.claude, 14)}
        <span style={{ flex: 1, fontFamily: t.mono, fontSize: 12, color: t.text, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{file}</span>
        <span style={{ fontFamily: t.mono, fontSize: 11.5, color: t.green }}>+{added}</span>
        <span style={{ fontFamily: t.mono, fontSize: 11.5, color: t.red }}>−{removed}</span>
      </div>
      <div style={{ padding: '6px 0', fontFamily: t.mono, fontSize: 11.3, lineHeight: 1.62 }}>
        {lines.map((l, i) => {
          const sign = l[0];
          const bg = sign === '+' ? (t.glow ? 'rgba(70,224,168,0.10)' : (t.dark ? 'rgba(105,192,138,0.10)' : 'rgba(44,138,85,0.08)'))
            : sign === '-' ? (t.glow ? 'rgba(255,107,129,0.10)' : (t.dark ? 'rgba(224,108,117,0.10)' : 'rgba(192,65,63,0.07)')) : 'transparent';
          const col = sign === '+' ? t.green : sign === '-' ? t.red : t.textDim;
          return <div key={i} style={{ display: 'flex', gap: 8, padding: '0 12px', background: bg }}>
            <span style={{ width: 10, color: col, flexShrink: 0 }}>{sign === ' ' ? '' : sign}</span>
            <span style={{ color: sign === ' ' ? t.textDim : col, whiteSpace: 'pre' }}>{l.slice(1)}</span>
          </div>;
        })}
      </div>
    </div>
  );
}

// ── Pending-input / approval card (first-class, tappable) ─────
function PendingCard({ t, prompt, options }) {
  return (
    <div style={{ margin: '8px 2px', borderRadius: 14, overflow: 'hidden',
      background: t.glow ? 'rgba(255,174,87,0.07)' : (t.dark ? 'rgba(224,151,90,0.07)' : 'rgba(200,99,43,0.05)'),
      border: `1.5px solid ${t.claude}${t.glow ? '66' : '44'}`, boxShadow: t.glow ? _gb(t, t.claude, 0.6) : 'none' }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '10px 13px 8px' }}>
        <_Dot color={t.claude} glow={t.glow} size={8} />
        <span style={{ fontFamily: t.mono, fontSize: 11, fontWeight: 700, letterSpacing: 1.2, textTransform: 'uppercase', color: t.claude, textShadow: _gt(t, t.claude, 0.5) }}>Needs your input</span>
      </div>
      <div style={{ padding: '0 13px 11px', fontFamily: t.font, fontSize: 14, lineHeight: 1.5, color: t.text }}>{prompt}</div>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 7, padding: '0 11px 12px' }}>
        {options.map((o, i) => (
          <div key={i} style={{ display: 'flex', alignItems: 'center', gap: 9, padding: '10px 13px', borderRadius: 11,
            background: i === 0 ? (t.glow ? t.claude : (t.dark ? t.claude : t.accent)) : (t.dark ? 'rgba(255,255,255,0.05)' : 'rgba(0,0,0,0.04)'),
            border: i === 0 ? 'none' : `1px solid ${t.border}`,
            color: i === 0 ? (t.glow ? '#1a0e02' : t.accentText) : t.text, fontFamily: t.font, fontSize: 13.5, fontWeight: 600,
            boxShadow: i === 0 && t.glow ? _gb(t, t.claude, 0.7) : 'none' }}>
            {i === 0 && _I.check(t.glow ? '#1a0e02' : t.accentText, 15)}
            <span style={{ flex: 1 }}>{o}</span>
            {i !== 0 && <span style={{ fontFamily: t.mono, fontSize: 11, color: t.textFaint }}>{i + 1}</span>}
          </div>
        ))}
      </div>
    </div>
  );
}

// ── Subagent / handoff card ───────────────────────────────────
function SubagentCard({ t, title, detail, agent }) {
  const c = _agentColor(t, agent);
  return (
    <div style={{ margin: '6px 2px', padding: '10px 12px', borderRadius: 13, display: 'flex', gap: 10, alignItems: 'flex-start',
      background: t.surface, border: `1px dashed ${c}${t.glow ? '66' : '44'}`, boxShadow: t.glow ? _gb(t, c, 0.3) : 'none' }}>
      <div style={{ marginTop: 1 }}>{_I.fork(c, 16)}</div>
      <div style={{ flex: 1 }}>
        <div style={{ fontFamily: t.font, fontSize: 13, fontWeight: 650, color: t.text }}>{title}</div>
        <div style={{ fontFamily: t.mono, fontSize: 11.5, color: t.textDim, marginTop: 2 }}>{detail}</div>
      </div>
    </div>
  );
}

// ── AI quick replies (server-minted) ──────────────────────────
function QuickReplies({ t, items }) {
  return (
    <div style={{ display: 'flex', gap: 7, padding: '4px 12px 8px', overflow: 'hidden' }}>
      {items.map((q, i) => (
        <span key={i} style={{ whiteSpace: 'nowrap', padding: '7px 12px', borderRadius: 99, flexShrink: 0,
          background: t.dark ? 'rgba(255,255,255,0.06)' : 'rgba(0,0,0,0.04)', border: `1px solid ${t.glow ? t.accent + '44' : t.border}`,
          fontFamily: t.font, fontSize: 12.5, fontWeight: 500, color: t.glow ? t.accent : t.textDim,
          boxShadow: t.glow ? _gb(t, t.accent, 0.3) : 'none' }}>
          <span style={{ opacity: 0.6, marginRight: 5 }}>✦</span>{q}
        </span>
      ))}
    </div>
  );
}

// ── Composer ──────────────────────────────────────────────────
function Composer({ t, platform, placeholder = 'Message the agent…', value }) {
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 9, padding: '8px 12px 10px' }}>
      <div style={{ width: 38, height: 38, borderRadius: 99, display: 'flex', alignItems: 'center', justifyContent: 'center',
        background: t.dark ? 'rgba(255,255,255,0.06)' : 'rgba(0,0,0,0.04)', border: `1px solid ${t.border}`, flexShrink: 0 }}>
        {_I.attach(t.textDim)}
      </div>
      <div style={{ flex: 1, display: 'flex', alignItems: 'center', minHeight: 40, padding: '0 14px', borderRadius: 21,
        background: t.dark ? 'rgba(255,255,255,0.06)' : '#fff', border: `1px solid ${value ? (t.glow ? t.accent + '66' : t.borderStrong) : t.border}`,
        fontFamily: t.font, fontSize: 14.5, color: value ? t.text : t.textFaint,
        boxShadow: value && t.glow ? _gb(t, t.accent, 0.4) : 'none' }}>
        {value || placeholder}
      </div>
      <div style={{ width: 40, height: 40, borderRadius: 99, display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0,
        background: value ? (t.glow ? t.accent : (t.dark ? t.accent : t.accent)) : (t.dark ? 'rgba(255,255,255,0.06)' : 'rgba(0,0,0,0.05)'),
        boxShadow: value && t.glow ? _gb(t, t.accent, 0.8) : 'none' }}>
        {value ? _I.send(t.glow ? '#03121a' : t.accentText) : _I.mic(t.textDim)}
      </div>
    </div>
  );
}

// ── Terminal line rendering ───────────────────────────────────
function Term({ t, children }) {
  return <div style={{ fontFamily: t.mono, fontSize: 12.2, lineHeight: 1.55, padding: '10px 14px', color: t.text, whiteSpace: 'pre-wrap',
    background: t.glow ? 'rgba(0,4,12,0.55)' : (t.dark ? '#0c0e12' : '#1b1d22'), flex: 1, overflow: 'hidden' }}>{children}</div>;
}
function TLine({ children, c }) { return <div style={{ color: c }}>{children}</div>; }

// ── Terminal accessory key bar (above keyboard) ───────────────
function AccessoryBar({ t }) {
  const keys = ['esc', 'tab', '/', '-', '|', '^C', '↑', '↓', '←', '→'];
  return (
    <div style={{ display: 'flex', gap: 6, padding: '8px 8px', overflow: 'hidden',
      background: t.dark ? 'rgba(20,22,28,0.96)' : '#e9e3d8', borderTop: `1px solid ${t.border}` }}>
      {keys.map(k => (
        <span key={k} style={{ minWidth: 34, height: 34, padding: '0 8px', borderRadius: 8, display: 'inline-flex', alignItems: 'center', justifyContent: 'center',
          background: t.dark ? 'rgba(255,255,255,0.09)' : '#fff', border: `1px solid ${t.border}`,
          fontFamily: t.mono, fontSize: 13, color: t.glow ? t.accent : t.text, flexShrink: 0 }}>{k}</span>
      ))}
    </div>
  );
}

// ── List row (sessions / history / settings) ──────────────────
function Row({ t, leading, title, sub, trailing, badge, onLast }) {
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 12, padding: '12px 14px', position: 'relative' }}>
      {leading}
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
          <span style={{ fontFamily: t.font, fontSize: 15, fontWeight: 600, color: t.text, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{title}</span>
          {badge}
        </div>
        {sub && <div style={{ fontFamily: t.mono, fontSize: 11.5, color: t.textFaint, marginTop: 2, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{sub}</div>}
      </div>
      {trailing}
    </div>
  );
}

Object.assign(window, { UserBubble, Assistant, Code, ToolCard, DiffCard, PendingCard, SubagentCard, QuickReplies, Composer, Term, TLine, AccessoryBar, Row });
