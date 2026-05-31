// neon-cards.jsx — the upgraded command + subagent/handoff components.
// These are the "hero" interaction patterns the user asked to improve.
// Depend on kit.jsx (I, Dot, agentColor), themes glow helpers, neon-theme (neonGlowColor).

const NC = window;
const _ng = window.neonGlowColor;

// glow that uses the bright accent in light mode
function gT(t, c, s = 1) {
  if (!t.glow || !t.dark) return 'none';
  const col = c || _ng(t);
  return `0 0 ${6 * s}px ${col}cc, 0 0 ${16 * s}px ${col}66`;
}
function gB(t, c, s = 1) {
  if (!t.glow) return 'none';
  const col = c || _ng(t);
  const k = t.dark ? s : s * 0.5;
  return `0 0 ${10 * k}px ${col}33, 0 0 ${26 * k}px ${col}1f`;
}

// ── COMMAND CARD ──────────────────────────────────────────────
// state: 'running' | 'ok' | 'fail'. Shows the command as a real
// prompt line, a status rail, streamed stdout/stderr, exit code,
// duration, and quick actions (copy / rerun / open in terminal).
function CommandCard({ t, cmd, cwd = '~/envoy-api', state = 'ok', exit = 0, ms = '0.8s', out = [], expanded = true }) {
  const railColor = state === 'running' ? t.accent2 : state === 'ok' ? t.green : t.red;
  const railGlow = _ng(t, railColor);
  const statusLabel = state === 'running' ? 'running' : state === 'ok' ? `exit ${exit}` : `exit ${exit}`;
  return (
    <div style={{ margin: '7px 2px', borderRadius: 14, overflow: 'hidden', position: 'relative',
      background: t.codeBg, border: `1px solid ${state === 'fail' ? railColor + '66' : t.borderStrong}`,
      boxShadow: t.glow ? gB(t, railColor, state === 'fail' ? 0.9 : 0.55) : (t.dark ? 'none' : '0 4px 16px rgba(13,26,48,0.12)') }}>
      {/* left status rail */}
      <div style={{ position: 'absolute', left: 0, top: 0, bottom: 0, width: 3, background: railColor,
        boxShadow: t.glow ? `0 0 8px ${railGlow}` : 'none' }} />
      {/* header: prompt + status */}
      <div style={{ display: 'flex', alignItems: 'center', gap: 9, padding: '10px 12px 9px 15px' }}>
        <span style={{ fontFamily: t.mono, fontSize: 13, color: railColor, textShadow: gT(t, railColor, 0.7) }}>$</span>
        <span style={{ flex: 1, minWidth: 0, fontFamily: t.mono, fontSize: 12.8, color: t.codeText || t.text, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{cmd}</span>
        {state === 'running'
          ? <span style={{ display: 'inline-flex', alignItems: 'center', gap: 6, fontFamily: t.mono, fontSize: 11, color: t.accent2, textShadow: gT(t, t.accent2, 0.6) }}>
              <span style={{ width: 7, height: 7, borderRadius: 99, background: t.accent2, boxShadow: t.glow ? `0 0 8px ${_ng(t, t.accent2)}` : 'none', animation: 'nkPulse 1s ease-in-out infinite' }} />running</span>
          : <span style={{ fontFamily: t.mono, fontSize: 11, fontWeight: 600, padding: '2px 8px', borderRadius: 99,
              color: railColor, background: `${railColor}1c`, border: `1px solid ${railColor}44`, textShadow: gT(t, railColor, 0.5) }}>{statusLabel}</span>}
      </div>
      {/* cwd + meta strip */}
      <div style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '0 12px 8px 15px', fontFamily: t.mono, fontSize: 10.5, color: t.dark ? 'rgba(150,176,220,0.55)' : 'rgba(180,200,235,0.7)' }}>
        {NC.I.folder('currentColor', 11)}<span>{cwd}</span>
        <span style={{ opacity: 0.5 }}>·</span>
        <span>mac-studio</span>
        <span style={{ marginLeft: 'auto', color: state === 'fail' ? railColor : 'inherit' }}>{ms}</span>
      </div>
      {/* output */}
      {expanded && out.length > 0 && (
        <div style={{ borderTop: `1px solid ${t.dark ? 'rgba(120,160,220,0.12)' : 'rgba(120,160,220,0.18)'}`,
          padding: '8px 12px 9px 15px', fontFamily: t.mono, fontSize: 11.3, lineHeight: 1.6, maxHeight: 132, overflow: 'hidden' }}>
          {out.map((l, i) => {
            const isErr = l.startsWith('!');
            const txt = isErr ? l.slice(1) : l;
            return <div key={i} style={{ color: isErr ? t.red : (t.codeText || 'rgba(214,230,255,0.82)'), whiteSpace: 'pre', textShadow: isErr ? gT(t, t.red, 0.4) : 'none' }}>{txt}</div>;
          })}
          {state === 'running' && <span style={{ display: 'inline-block', width: 8, height: 14, background: t.accent2, verticalAlign: -2, boxShadow: t.glow ? `0 0 7px ${_ng(t, t.accent2)}` : 'none', animation: 'nkBlink 1s steps(2) infinite' }} />}
        </div>
      )}
      {/* action bar */}
      <div style={{ display: 'flex', alignItems: 'center', gap: 0, borderTop: `1px solid ${t.dark ? 'rgba(120,160,220,0.12)' : 'rgba(120,160,220,0.18)'}` }}>
        {[['Copy', NC.I.file], ['Re-run', NC.I.reload], ['Open in terminal', NC.I.term]].map(([label, ic], i) => (
          <div key={label} style={{ flex: i === 2 ? 'none' : 1, display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 6,
            padding: '9px 13px', borderLeft: i ? `1px solid ${t.dark ? 'rgba(120,160,220,0.10)' : 'rgba(120,160,220,0.16)'}` : 'none',
            fontFamily: t.font, fontSize: 11.5, fontWeight: 600, color: i === 2 ? t.accent : (t.dark ? 'rgba(170,194,235,0.75)' : 'rgba(150,176,220,0.95)'),
            textShadow: i === 2 ? gT(t, t.accent, 0.5) : 'none' }}>
            {ic(i === 2 ? _ng(t) : (t.dark ? 'rgba(170,194,235,0.75)' : '#7fa0d8'), 13)}{label}
          </div>
        ))}
      </div>
    </div>
  );
}

// ── PLAN / TODO CARD (agent's command plan, a nice touch) ─────
function PlanCard({ t, title = 'Plan', steps }) {
  return (
    <div style={{ margin: '7px 2px', borderRadius: 13, overflow: 'hidden', background: t.surface, border: `1px solid ${t.border}`,
      boxShadow: t.glow ? gB(t, t.accent, 0.3) : 'none' }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '9px 13px', borderBottom: `1px solid ${t.border}` }}>
        <span style={{ fontFamily: t.mono, fontSize: 10.5, fontWeight: 700, letterSpacing: 1.4, textTransform: 'uppercase', color: t.accent, textShadow: gT(t, t.accent, 0.5) }}>{title}</span>
      </div>
      <div style={{ padding: '8px 13px 10px', display: 'flex', flexDirection: 'column', gap: 7 }}>
        {steps.map((s, i) => {
          const done = s.state === 'done', active = s.state === 'active';
          const c = done ? t.green : active ? t.accent : t.textFaint;
          return (
            <div key={i} style={{ display: 'flex', alignItems: 'center', gap: 9 }}>
              <span style={{ width: 16, height: 16, borderRadius: 99, flexShrink: 0, display: 'flex', alignItems: 'center', justifyContent: 'center',
                border: `1.5px solid ${c}`, background: done ? c : 'transparent', boxShadow: (active || done) && t.glow ? `0 0 8px ${_ng(t, c)}` : 'none' }}>
                {done && NC.I.check(t.dark ? '#04140d' : '#fff', 10)}
                {active && <span style={{ width: 5, height: 5, borderRadius: 99, background: c }} />}
              </span>
              <span style={{ fontFamily: t.font, fontSize: 13, color: done ? t.textDim : t.text, textDecoration: done ? 'line-through' : 'none', textDecorationColor: t.textFaint }}>{s.label}</span>
              {active && <span style={{ marginLeft: 'auto', fontFamily: t.mono, fontSize: 10, color: t.accent }}>running…</span>}
            </div>
          );
        })}
      </div>
    </div>
  );
}

// ── SUBAGENT / HANDOFF CARD ───────────────────────────────────
// Shows a parent agent delegating to a subagent: avatars, the task,
// a live nested progress strip, and a collapsible result summary.
function HandoffCard({ t, from = 'claude', to = 'codex', task, state = 'done', steps = 3, result, tokens = '18.2k' }) {
  const cFrom = NC.agentColor(t, from);
  const cTo = NC.agentColor(t, to);
  const running = state === 'running';
  return (
    <div style={{ margin: '8px 2px', borderRadius: 15, overflow: 'hidden', position: 'relative',
      background: t.surface, border: `1px solid ${cTo}${t.glow ? '55' : '40'}`,
      boxShadow: t.glow ? gB(t, cTo, 0.5) : (t.dark ? 'none' : '0 4px 16px rgba(13,26,48,0.1)') }}>
      {/* delegation header */}
      <div style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '11px 13px 10px' }}>
        <div style={{ display: 'flex', alignItems: 'center' }}>
          <Avatar t={t} agent={from} size={26} />
          <span style={{ margin: '0 2px', display: 'inline-flex' }}>{NC.I.chevR(t.textFaint, 13)}</span>
          <Avatar t={t} agent={to} size={26} glow />
        </div>
        <div style={{ flex: 1, minWidth: 0 }}>
          <div style={{ fontFamily: t.font, fontSize: 13, fontWeight: 650, color: t.text }}>
            <span style={{ color: cFrom }}>{from}</span> delegated to <span style={{ color: cTo, textShadow: gT(t, cTo, 0.5) }}>{to}</span>
          </div>
          <div style={{ fontFamily: t.mono, fontSize: 10.5, color: t.textFaint, marginTop: 1 }}>subagent · {tokens} tokens</div>
        </div>
        {running
          ? <span style={{ display: 'inline-flex', alignItems: 'center', gap: 5, fontFamily: t.mono, fontSize: 10.5, color: cTo, textShadow: gT(t, cTo, 0.5) }}><span style={{ width: 6, height: 6, borderRadius: 99, background: cTo, animation: 'nkPulse 1s infinite', boxShadow: t.glow ? `0 0 8px ${_ng(t, cTo)}` : 'none' }} />working</span>
          : <span style={{ fontFamily: t.mono, fontSize: 10.5, color: t.green }}>done</span>}
      </div>
      {/* the delegated task */}
      <div style={{ margin: '0 13px 10px', padding: '9px 11px', borderRadius: 10, background: t.dark ? 'rgba(0,0,0,0.28)' : 'rgba(13,26,48,0.04)', border: `1px solid ${t.border}` }}>
        <div style={{ fontFamily: t.mono, fontSize: 10, letterSpacing: 1, textTransform: 'uppercase', color: t.textFaint, marginBottom: 4 }}>task</div>
        <div style={{ fontFamily: t.font, fontSize: 13, lineHeight: 1.45, color: t.text }}>{task}</div>
      </div>
      {/* nested progress strip */}
      <div style={{ display: 'flex', gap: 5, padding: '0 13px 10px' }}>
        {Array.from({ length: steps }).map((_, i) => {
          const filled = running ? i < steps - 1 : true;
          return <span key={i} style={{ flex: 1, height: 3, borderRadius: 99, background: filled ? cTo : t.border,
            boxShadow: filled && t.glow ? `0 0 6px ${_ng(t, cTo)}` : 'none' }} />;
        })}
      </div>
      {/* result summary */}
      {result && (
        <div style={{ display: 'flex', gap: 9, alignItems: 'flex-start', padding: '10px 13px', borderTop: `1px solid ${t.border}`,
          background: t.dark ? 'rgba(62,240,160,0.05)' : 'rgba(18,168,102,0.05)' }}>
          <span style={{ marginTop: 1 }}>{NC.I.check(t.green, 15)}</span>
          <div style={{ flex: 1, fontFamily: t.font, fontSize: 12.8, lineHeight: 1.5, color: t.textDim }}>{result}</div>
        </div>
      )}
    </div>
  );
}

// agent avatar (cat mark in a tinted rounded square)
function Avatar({ t, agent, size = 28, glow }) {
  const c = NC.agentColor(t, agent);
  return (
    <div style={{ width: size, height: size, borderRadius: size * 0.32, flexShrink: 0, display: 'flex', alignItems: 'center', justifyContent: 'center',
      background: `${c}1e`, border: `1px solid ${c}${t.glow ? '66' : '44'}`,
      boxShadow: glow && t.glow ? `0 0 10px ${_ng(t, c)}55` : 'none' }}>
      <NC.ConduitMark t={t} size={size * 0.72} color={c} />
    </div>
  );
}

// ── MODEL SWITCH / AGENT SWAP inline notice ───────────────────
function SwapNotice({ t, label }) {
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 8, justifyContent: 'center', margin: '8px 0 6px' }}>
      <span style={{ height: 1, flex: 1, background: `linear-gradient(90deg, transparent, ${t.border})` }} />
      <span style={{ display: 'inline-flex', alignItems: 'center', gap: 6, fontFamily: t.mono, fontSize: 10.5, color: t.textDim, padding: '3px 10px', borderRadius: 99, border: `1px solid ${t.border}`, background: t.surface }}>
        {NC.I.swap(t.accent, 12)}{label}
      </span>
      <span style={{ height: 1, flex: 1, background: `linear-gradient(90deg, ${t.border}, transparent)` }} />
    </div>
  );
}

Object.assign(window, { CommandCard, PlanCard, HandoffCard, Avatar, SwapNotice, gT, gB });
