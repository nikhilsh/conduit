// kit.jsx — shared primitives for the Conduit mockups.
// Everything consumes a theme `t` (from themes.jsx) and, where it matters,
// a `platform` ('ios' | 'android'). Mono is reserved for code/paths/diffs;
// assistant prose is set in the theme's readable sans.

const { glowText, glowBox } = window;

// ── Icons ─────────────────────────────────────────────────────
// stroke icons, color via `c`, size via `s`
const I = {
  gear: (c, s = 20) => <svg width={s} height={s} viewBox="0 0 24 24" fill="none"><circle cx="12" cy="12" r="3.2" stroke={c} strokeWidth="1.7"/><path d="M12 2.5v2.6M12 18.9v2.6M21.5 12h-2.6M5.1 12H2.5M18.7 5.3l-1.8 1.8M7.1 16.9l-1.8 1.8M18.7 18.7l-1.8-1.8M7.1 7.1L5.3 5.3" stroke={c} strokeWidth="1.7" strokeLinecap="round"/></svg>,
  paw: (c, s = 20) => <svg width={s} height={s} viewBox="0 0 24 24" fill={c}><circle cx="7" cy="9" r="2"/><circle cx="12" cy="7" r="2"/><circle cx="17" cy="9" r="2"/><path d="M12 11c3 0 5 2.4 5 4.6 0 1.7-1.4 2.4-3 2.4-1 0-1.4-.4-2-.4s-1 .4-2 .4c-1.6 0-3-.7-3-2.4C7 13.4 9 11 12 11z"/></svg>,
  plus: (c, s = 20) => <svg width={s} height={s} viewBox="0 0 24 24" fill="none"><path d="M12 5v14M5 12h14" stroke={c} strokeWidth="2" strokeLinecap="round"/></svg>,
  chevR: (c, s = 16) => <svg width={s} height={s} viewBox="0 0 16 16" fill="none"><path d="M5.5 3l5 5-5 5" stroke={c} strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"/></svg>,
  chevD: (c, s = 16) => <svg width={s} height={s} viewBox="0 0 16 16" fill="none"><path d="M3 5.5l5 5 5-5" stroke={c} strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"/></svg>,
  back: (c, s = 18) => <svg width={s} height={s} viewBox="0 0 18 18" fill="none"><path d="M11.5 3l-6 6 6 6" stroke={c} strokeWidth="2.1" strokeLinecap="round" strokeLinejoin="round"/></svg>,
  reload: (c, s = 18) => <svg width={s} height={s} viewBox="0 0 20 20" fill="none"><path d="M16.5 5.5A8 8 0 103 12" stroke={c} strokeWidth="1.9" strokeLinecap="round"/><path d="M16.8 2.5v3.4h-3.4" stroke={c} strokeWidth="1.9" strokeLinecap="round" strokeLinejoin="round"/></svg>,
  info: (c, s = 18) => <svg width={s} height={s} viewBox="0 0 20 20" fill="none"><circle cx="10" cy="10" r="8" stroke={c} strokeWidth="1.7"/><path d="M10 9v5" stroke={c} strokeWidth="1.9" strokeLinecap="round"/><circle cx="10" cy="6.2" r="1.1" fill={c}/></svg>,
  send: (c, s = 20) => <svg width={s} height={s} viewBox="0 0 24 24" fill="none"><path d="M12 19V6M6 11l6-6 6 6" stroke={c} strokeWidth="2.1" strokeLinecap="round" strokeLinejoin="round"/></svg>,
  attach: (c, s = 22) => <svg width={s} height={s} viewBox="0 0 24 24" fill="none"><path d="M19 11.5l-7.2 7.2a4.5 4.5 0 01-6.4-6.4l7.6-7.6a3 3 0 014.3 4.3l-7.6 7.6a1.5 1.5 0 01-2.2-2.2l6.9-6.9" stroke={c} strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round"/></svg>,
  mic: (c, s = 22) => <svg width={s} height={s} viewBox="0 0 24 24" fill="none"><rect x="9" y="3" width="6" height="11" rx="3" stroke={c} strokeWidth="1.7"/><path d="M5.5 11a6.5 6.5 0 0013 0M12 17.5V21" stroke={c} strokeWidth="1.7" strokeLinecap="round"/></svg>,
  chat: (c, s = 22) => <svg width={s} height={s} viewBox="0 0 24 24" fill="none"><path d="M4 5.5A1.5 1.5 0 015.5 4h13A1.5 1.5 0 0120 5.5v9a1.5 1.5 0 01-1.5 1.5H9l-4 3.5V16H5.5A1.5 1.5 0 014 14.5v-9z" stroke={c} strokeWidth="1.7" strokeLinejoin="round"/></svg>,
  term: (c, s = 22) => <svg width={s} height={s} viewBox="0 0 24 24" fill="none"><rect x="3" y="4.5" width="18" height="15" rx="2.2" stroke={c} strokeWidth="1.7"/><path d="M7 9.5l3 2.5-3 2.5M12.5 15h4.5" stroke={c} strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round"/></svg>,
  browser: (c, s = 22) => <svg width={s} height={s} viewBox="0 0 24 24" fill="none"><circle cx="12" cy="12" r="8.5" stroke={c} strokeWidth="1.7"/><path d="M3.5 12h17M12 3.5c2.5 2.4 2.5 14.6 0 17M12 3.5c-2.5 2.4-2.5 14.6 0 17" stroke={c} strokeWidth="1.5"/></svg>,
  search: (c, s = 18) => <svg width={s} height={s} viewBox="0 0 20 20" fill="none"><circle cx="8.5" cy="8.5" r="5.5" stroke={c} strokeWidth="1.8"/><path d="M12.7 12.7L17 17" stroke={c} strokeWidth="1.8" strokeLinecap="round"/></svg>,
  edit: (c, s = 16) => <svg width={s} height={s} viewBox="0 0 18 18" fill="none"><path d="M11.5 3.5l3 3M3 15l1-3.3L12 3.7a1.4 1.4 0 012 0l.3.3a1.4 1.4 0 010 2L6.3 14 3 15z" stroke={c} strokeWidth="1.6" strokeLinejoin="round"/></svg>,
  file: (c, s = 16) => <svg width={s} height={s} viewBox="0 0 18 18" fill="none"><path d="M4 2.5h6L14.5 7v8.5a1 1 0 01-1 1h-9a1 1 0 01-1-1v-12a1 1 0 011-1z" stroke={c} strokeWidth="1.5" strokeLinejoin="round"/><path d="M10 2.5V7h4.5" stroke={c} strokeWidth="1.5" strokeLinejoin="round"/></svg>,
  bash: (c, s = 16) => <svg width={s} height={s} viewBox="0 0 18 18" fill="none"><path d="M4 5l3.2 4L4 13M9.5 13H14" stroke={c} strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round"/></svg>,
  check: (c, s = 16) => <svg width={s} height={s} viewBox="0 0 18 18" fill="none"><path d="M3.5 9.5l3.5 3.5 7.5-8" stroke={c} strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"/></svg>,
  fork: (c, s = 16) => <svg width={s} height={s} viewBox="0 0 18 18" fill="none"><circle cx="5" cy="4" r="2" stroke={c} strokeWidth="1.6"/><circle cx="13" cy="4" r="2" stroke={c} strokeWidth="1.6"/><circle cx="9" cy="14" r="2" stroke={c} strokeWidth="1.6"/><path d="M5 6v2c0 2 2 2.5 4 3 2-.5 4-1 4-3V6" stroke={c} strokeWidth="1.6"/></svg>,
  archive: (c, s = 18) => <svg width={s} height={s} viewBox="0 0 20 20" fill="none"><rect x="3" y="4" width="14" height="3.5" rx="1" stroke={c} strokeWidth="1.6"/><path d="M4.5 7.5v7a1 1 0 001 1h9a1 1 0 001-1v-7M8 11h4" stroke={c} strokeWidth="1.6" strokeLinecap="round"/></svg>,
  trash: (c, s = 18) => <svg width={s} height={s} viewBox="0 0 20 20" fill="none"><path d="M4 5.5h12M8 5.5V4a1 1 0 011-1h2a1 1 0 011 1v1.5M6 5.5l.7 9a1 1 0 001 .9h4.6a1 1 0 001-.9l.7-9" stroke={c} strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round"/></svg>,
  wifi: (c, s = 18) => <svg width={s} height={s} viewBox="0 0 20 20" fill="none"><path d="M2.5 7.5a11 11 0 0115 0M5 10.3a7 7 0 0110 0M7.5 13a3.4 3.4 0 015 0" stroke={c} strokeWidth="1.6" strokeLinecap="round"/><circle cx="10" cy="15.8" r="1.1" fill={c}/></svg>,
  server: (c, s = 18) => <svg width={s} height={s} viewBox="0 0 20 20" fill="none"><rect x="3" y="3.5" width="14" height="5.5" rx="1.4" stroke={c} strokeWidth="1.6"/><rect x="3" y="11" width="14" height="5.5" rx="1.4" stroke={c} strokeWidth="1.6"/><circle cx="6" cy="6.25" r="0.9" fill={c}/><circle cx="6" cy="13.75" r="0.9" fill={c}/></svg>,
  folder: (c, s = 18) => <svg width={s} height={s} viewBox="0 0 20 20" fill="none"><path d="M3 5.5a1 1 0 011-1h3.6l1.4 1.6H16a1 1 0 011 1v7.4a1 1 0 01-1 1H4a1 1 0 01-1-1v-9z" stroke={c} strokeWidth="1.6" strokeLinejoin="round"/></svg>,
  ssh: (c, s = 18) => <svg width={s} height={s} viewBox="0 0 20 20" fill="none"><rect x="2.5" y="4" width="15" height="12" rx="2" stroke={c} strokeWidth="1.6"/><path d="M5.5 8l2.5 2-2.5 2M9.5 12h4" stroke={c} strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round"/></svg>,
  qr: (c, s = 18) => <svg width={s} height={s} viewBox="0 0 20 20" fill="none"><rect x="3" y="3" width="5" height="5" rx="1" stroke={c} strokeWidth="1.6"/><rect x="12" y="3" width="5" height="5" rx="1" stroke={c} strokeWidth="1.6"/><rect x="3" y="12" width="5" height="5" rx="1" stroke={c} strokeWidth="1.6"/><path d="M12 12h2v2M16 12v5M12 16h2" stroke={c} strokeWidth="1.6" strokeLinecap="round"/></svg>,
  branch: (c, s = 15) => <svg width={s} height={s} viewBox="0 0 16 16" fill="none"><circle cx="4" cy="4" r="1.8" stroke={c} strokeWidth="1.5"/><circle cx="4" cy="12" r="1.8" stroke={c} strokeWidth="1.5"/><circle cx="12" cy="5.5" r="1.8" stroke={c} strokeWidth="1.5"/><path d="M4 5.8v4.4M5.8 4h2.7c1.4 0 1.7 1 1.7 2.2v0" stroke={c} strokeWidth="1.5"/></svg>,
  swap: (c, s = 16) => <svg width={s} height={s} viewBox="0 0 18 18" fill="none"><path d="M4 6h9l-2.2-2.2M14 12H5l2.2 2.2" stroke={c} strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round"/></svg>,
  lock: (c, s = 14) => <svg width={s} height={s} viewBox="0 0 16 16" fill="none"><rect x="3.5" y="7" width="9" height="6.5" rx="1.3" stroke={c} strokeWidth="1.5"/><path d="M5.5 7V5.3a2.5 2.5 0 015 0V7" stroke={c} strokeWidth="1.5"/></svg>,
};

// ── Conduit mark (rounded-square daemon: >< squint eyes + smile) ──
let _cmId = 0;
function ConduitMark({ t, size = 28, color }) {
  const solid = color || (t.glow ? t.accent : t.text);
  const gid = React.useMemo(() => 'cm' + (++_cmId), []);
  const useGrad = !color; // use cyan→green gradient unless a flat color is forced
  const stroke = useGrad ? `url(#${gid})` : solid;
  const eye = t.glow ? '#eafcff' : t.text;
  return (
    <div style={{ position: 'relative', width: size, height: size, display: 'inline-flex' }}>
      <svg width={size} height={size} viewBox="0 0 32 32" fill="none" style={{ filter: t.glow ? `drop-shadow(0 0 3px ${(t.accent2 || t.accent)}88)` : 'none' }}>
        <defs>
          <linearGradient id={gid} x1="4" y1="4" x2="28" y2="28" gradientUnits="userSpaceOnUse">
            <stop offset="0" stopColor={t.accent || '#22d3ee'}/>
            <stop offset="1" stopColor={t.accent2 || t.claudeAlt || '#3ef0a0'}/>
          </linearGradient>
        </defs>
        {/* body */}
        <rect x="5.4" y="5.4" width="21.2" height="21.2" rx="6.4" stroke={stroke} strokeWidth="2"/>
        {/* connector pills */}
        <rect x="14.4" y="4.4" width="3.2" height="2" rx="1" fill={t.accent || '#22d3ee'}/>
        <rect x="14.4" y="25.6" width="3.2" height="2" rx="1" fill={t.accent2 || t.claudeAlt || '#3ef0a0'}/>
        {/* >< squint eyes */}
        <g stroke={eye} strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round" fill="none">
          <path d="M11 13.4 L13.6 15.4 L11 17.4"/>
          <path d="M21 13.4 L18.4 15.4 L21 17.4"/>
          {/* smile */}
          <path d="M13 20 Q16 22.4 19 20"/>
        </g>
      </svg>
    </div>
  );
}

// app icon image (the real product icon)
function AppIcon({ size = 56, radius }) {
  return <img src="assets/conduit-512.png" alt="Conduit" width={size} height={size}
    style={{ borderRadius: radius != null ? radius : size * 0.225, display: 'block',
      boxShadow: '0 6px 20px rgba(0,0,0,0.4)' }} />;
}

// ── Small atoms ───────────────────────────────────────────────
function Dot({ color, glow, size = 8 }) {
  return <span style={{ width: size, height: size, borderRadius: 99, background: color, display: 'inline-block', flexShrink: 0, boxShadow: glow ? `0 0 7px ${color}` : 'none' }} />;
}

function agentColor(t, agent) {
  return agent === 'codex' ? t.codex : t.claude;
}
function AgentChip({ t, agent, small }) {
  const c = agentColor(t, agent);
  const fs = small ? 11 : 12.5;
  return (
    <span style={{ display: 'inline-flex', alignItems: 'center', gap: 5, padding: small ? '2px 7px' : '3px 9px',
      borderRadius: 99, background: t.glow ? `${c}1f` : `${c}22`, border: `1px solid ${c}${t.glow ? '55' : '3a'}`,
      fontFamily: t.mono, fontSize: fs, fontWeight: 600, color: c, letterSpacing: 0.2,
      textShadow: glowText(t, c, 0.5) }}>
      <Dot color={c} glow={t.glow} size={6} />{agent}
    </span>
  );
}

// glass / solid round nav button
function NavBtn({ t, platform, children, size = 38, active }) {
  const ios = platform === 'ios';
  const glassy = t.glow || ios;
  return (
    <div style={{ width: size, height: size, borderRadius: 99, display: 'flex', alignItems: 'center', justifyContent: 'center',
      background: glassy ? (t.dark ? 'rgba(255,255,255,0.08)' : 'rgba(0,0,0,0.05)') : t.surface2,
      border: `1px solid ${t.border}`,
      boxShadow: active && t.glow ? glowBox(t, t.accent, 0.7) : 'none', flexShrink: 0 }}>
      {children}
    </div>
  );
}

function Pill({ t, children, color, style }) {
  const c = color || t.text;
  return <span style={{ display: 'inline-flex', alignItems: 'center', gap: 6, padding: '5px 11px', borderRadius: 99,
    background: t.dark ? 'rgba(255,255,255,0.06)' : 'rgba(0,0,0,0.04)', border: `1px solid ${t.border}`,
    fontFamily: t.mono, fontSize: 12, color: c, ...style }}>{children}</span>;
}

function SectionLabel({ t, children, action }) {
  return (
    <div style={{ display: 'flex', alignItems: 'baseline', justifyContent: 'space-between', padding: '2px 4px 9px' }}>
      <span style={{ fontFamily: t.mono, fontSize: 12, fontWeight: 600, letterSpacing: 1.8, textTransform: 'uppercase',
        color: t.glow ? t.accent : t.textDim, textShadow: glowText(t, t.accent, 0.45) }}>{children}</span>
      {action}
    </div>
  );
}

// ── Chat: session header (improves a cramped pill) ─────
function SessionHeader({ t, platform, title, agent, branch, cwd, status = 'live', onInfo }) {
  const c = agentColor(t, agent);
  const statusColor = status === 'live' ? t.green : status === 'thinking' ? t.claude : t.textFaint;
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 9, padding: platform === 'ios' ? '52px 12px 10px' : '6px 10px 10px' }}>
      <NavBtn t={t} platform={platform} size={38}>{I.back(t.textDim)}</NavBtn>
      <div onClick={onInfo} style={{ flex: 1, minWidth: 0, display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 2,
        padding: '6px 12px', borderRadius: 16, cursor: onInfo ? 'pointer' : 'default', background: t.dark ? 'rgba(255,255,255,0.05)' : 'rgba(0,0,0,0.035)',
        border: `1px solid ${t.border}` }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 7, maxWidth: '100%' }}>
          <Dot color={statusColor} glow={t.glow} size={7} />
          <span style={{ fontFamily: t.font, fontSize: 14.5, fontWeight: 650, color: t.text, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{title}</span>
          {I.info(t.textFaint, 14)}
        </div>
        <div style={{ display: 'flex', alignItems: 'center', gap: 8, fontFamily: t.mono, fontSize: 10.5, color: t.textFaint }}>
          <span style={{ color: c }}>{agent}</span>
          <span style={{ display: 'inline-flex', alignItems: 'center', gap: 3 }}>{I.branch(t.textFaint, 11)}{branch}</span>
        </div>
      </div>
      {onInfo && window.UsageChip
        ? <window.UsageChip t={t} onTap={onInfo} />
        : <NavBtn t={t} platform={platform} size={38}>{I.reload(t.glow ? t.accent : t.textDim)}</NavBtn>}
    </div>
  );
}

// ── Chat: in-tab segmented bar (Chat · Terminal · Browser) ────
function TabBar({ t, platform, active = 'chat' }) {
  const tabs = [['chat', I.chat], ['terminal', I.term], ['browser', I.browser]];
  const ios = platform === 'ios';
  return (
    <div style={{ display: 'flex', gap: ios ? 6 : 0, padding: ios ? 6 : '0', margin: ios ? '0 12px 6px' : 0,
      borderRadius: ios ? 99 : 0, background: ios ? (t.dark ? 'rgba(255,255,255,0.06)' : 'rgba(0,0,0,0.04)') : t.surfaceSolid,
      border: ios ? `1px solid ${t.border}` : 'none', borderTop: `1px solid ${t.border}` }}>
      {tabs.map(([id, icon]) => {
        const on = id === active;
        const c = on ? (t.glow ? t.accent : (t.dark ? t.text : t.accent)) : t.textFaint;
        return (
          <div key={id} style={{ flex: 1, display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 3,
            padding: ios ? '7px 0' : '8px 0 7px', borderRadius: ios ? 99 : 0,
            background: on && ios ? (t.dark ? 'rgba(255,255,255,0.10)' : '#fff') : 'transparent',
            boxShadow: on && ios && t.glow ? glowBox(t, t.accent, 0.5) : (on && ios && !t.dark ? '0 1px 3px rgba(0,0,0,0.1)' : 'none'),
            borderBottom: !ios ? (on ? `2.5px solid ${c}` : '2.5px solid transparent') : 'none',
            position: 'relative' }}>
            {icon(c, 21)}
            <span style={{ fontFamily: t.font, fontSize: 10.5, fontWeight: on ? 650 : 500, color: c, textTransform: 'capitalize', textShadow: on ? glowText(t, t.accent, 0.4) : 'none' }}>{id}</span>
          </div>
        );
      })}
    </div>
  );
}

Object.assign(window, { I, ConduitMark, AppIcon, Dot, agentColor, AgentChip, NavBtn, Pill, SectionLabel, SessionHeader, TabBar });
