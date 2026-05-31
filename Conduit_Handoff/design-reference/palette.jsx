// palette.jsx — history & search upgrade:
//  • SESSIONS — one source of truth, each with real outcomes (diff/PR/tests)
//  • OutcomeChips — glanceable result of a session (landed diff, PR, tests)
//  • CommandPalette — fuzzy search across sessions, repos, branches & messages
//  • HistoryScreen (override) — grouped by time, outcome-first rows, opens palette
const PL = window;
const _ngP = window.neonGlowColor;
const { gT: _gtP, gB: _gbP } = window;

// ── data: sessions with outcomes + a few searchable message lines ──
const SESSIONS = [
  { id: 's1', name: 'Fix auth refresh loop', repo: 'envoy-api', branch: 'fix/auth', agent: 'claude',
    status: 'live', when: 'now', group: 'Today',
    preview: 'The 401 handler re-enters refresh() before the new token is saved. Patched + guarded.',
    outcomes: { diff: { add: 24, rem: 9 }, pr: { num: 412, state: 'open' }, tests: { pass: 7, total: 7 }, commits: 2 },
    messages: ['the token refresh loops on a 401 — find it, fix it', 'inFlight isn’t reset when mint() rejects'] },
  { id: 's2', name: 'Port matrix to Compose', repo: 'conduit', branch: 'android-ui', agent: 'codex',
    status: 'paused', when: '14m', group: 'Today',
    preview: 'Mapped 6 screens to Jetpack Compose. Waiting on a call: bottom sheet vs full dialog?',
    outcomes: { diff: { add: 318, rem: 142 }, pr: null, tests: { pass: 22, total: 24 }, commits: 5 },
    messages: ['port the new-session bottom sheet to compose', 'keep the matrix layout or switch to LazyColumn?'] },
  { id: 's3', name: 'Add rate limiting', repo: 'envoy-api', branch: 'feat/ratelimit', agent: 'claude',
    status: 'done', when: 'yesterday', group: 'Yesterday',
    preview: 'Token-bucket middleware on the gateway. 429 with Retry-After. Merged to main.',
    outcomes: { diff: { add: 96, rem: 4 }, pr: { num: 408, state: 'merged' }, tests: { pass: 14, total: 14 }, commits: 3 },
    messages: ['add a token bucket rate limiter to the api gateway', 'return 429 with a Retry-After header'] },
  { id: 's4', name: 'Migrate to pnpm', repo: 'conduit', branch: 'chore/pnpm', agent: 'codex',
    status: 'done', when: '2d', group: 'This week',
    preview: 'Swapped npm → pnpm workspaces, fixed hoisting in CI. Lockfile committed.',
    outcomes: { diff: { add: 41, rem: 880 }, pr: { num: 401, state: 'merged' }, tests: { pass: 31, total: 31 }, commits: 1 },
    messages: ['migrate the monorepo from npm to pnpm', 'CI cache key needs the pnpm lockfile hash'] },
  { id: 's5', name: 'Debug flaky CI', repo: 'envoy-api', branch: 'ci/flake', agent: 'claude',
    status: 'done', when: '3d', group: 'This week',
    preview: 'Race in the test DB teardown. Serialized the suite, added a fixture lock.',
    outcomes: { diff: { add: 18, rem: 6 }, pr: { num: 397, state: 'merged' }, tests: { pass: 212, total: 212 }, commits: 2 },
    messages: ['the auth integration test fails ~1 in 5 on CI', 'teardown races with the next test’s setup'] },
  { id: 's6', name: 'Tidy release notes', repo: 'conduit', branch: 'main', agent: 'claude',
    status: 'idle', when: '3d', group: 'This week',
    preview: 'Drafted v1.4 notes from merged PRs. Grouped by feature / fix / chore.',
    outcomes: { diff: { add: 60, rem: 2 }, pr: { num: 399, state: 'draft' }, tests: null, commits: 1 },
    messages: ['draft v1.4 release notes from the merged PRs', 'group by feature, fix and chore'] },
  { id: 's7', name: 'Spike: voice rail', repo: 'conduit', branch: 'spike/voice', agent: 'codex',
    status: 'archived', when: '1w', group: 'Earlier',
    preview: 'Prototyped push-to-talk dictation into the composer. Parked behind a flag.',
    outcomes: { diff: { add: 240, rem: 30 }, pr: null, tests: { pass: 4, total: 9 }, commits: 4 },
    messages: ['spike a voice dictation rail above the keyboard', 'whisper streaming vs on-device?'] },
  { id: 's8', name: 'Old onboarding copy', repo: 'marketing', branch: 'copy/onboard', agent: 'claude',
    status: 'archived', when: '2w', group: 'Earlier',
    preview: 'Rewrote first-run copy. Superseded by the new pairing flow.',
    outcomes: { diff: { add: 12, rem: 48 }, pr: { num: 388, state: 'merged' }, tests: null, commits: 1 },
    messages: ['rewrite the first-run onboarding copy', 'shorter, less jargon'] },
];

const REPOS = ['envoy-api', 'conduit', 'marketing'];

// ── subsequence fuzzy score (returns null if no match) ──
function fuzzy(q, s) {
  if (!q) return 0;
  q = q.toLowerCase(); s = s.toLowerCase();
  const idx = s.indexOf(q);
  if (idx >= 0) return 1000 - idx;        // contiguous = best
  let qi = 0, score = 0, last = -1;
  for (let i = 0; i < s.length && qi < q.length; i++) {
    if (s[i] === q[qi]) { score += (i === last + 1 ? 3 : 1); last = i; qi++; }
  }
  return qi === q.length ? score : null;
}

// ── outcome chips: the result of a session at a glance ──
function OutcomeChips({ t, o, dense }) {
  if (!o) return null;
  const fs = dense ? 9.5 : 10.5;
  const pad = dense ? '1px 6px' : '2px 7px';
  const chip = (key, color, children) => (
    <span key={key} style={{ display: 'inline-flex', alignItems: 'center', gap: 4, padding: pad, borderRadius: 99,
      fontFamily: t.mono, fontSize: fs, fontWeight: 600, color, background: `${color}14`, border: `1px solid ${color}33`,
      whiteSpace: 'nowrap' }}>{children}</span>
  );
  const prState = o.pr && (o.pr.state === 'merged' ? t.purple : o.pr.state === 'open' ? t.green : t.textFaint);
  return (
    <div style={{ display: 'flex', flexWrap: 'wrap', gap: 6, alignItems: 'center' }}>
      {o.diff && chip('diff', t.textDim,
        <><span style={{ color: t.green }}>+{o.diff.add}</span><span style={{ color: t.red }}>−{o.diff.rem}</span></>)}
      {o.pr && chip('pr', prState,
        <>{PL.I.branch(prState, 10)}#{o.pr.num} {o.pr.state}</>)}
      {o.tests && chip('tests', o.tests.pass === o.tests.total ? t.green : t.yellow,
        <>{PL.I.check(o.tests.pass === o.tests.total ? t.green : t.yellow, 10)}{o.tests.pass}/{o.tests.total}</>)}
      {o.commits != null && chip('commits', t.textFaint, <>{o.commits} commit{o.commits === 1 ? '' : 's'}</>)}
    </div>
  );
}

// highlight matched substring inside a label
function Hi({ t, text, q }) {
  if (!q) return <>{text}</>;
  const i = text.toLowerCase().indexOf(q.toLowerCase());
  if (i < 0) return <>{text}</>;
  const c = _ngP(t);
  return <>{text.slice(0, i)}<span style={{ color: c, fontWeight: 700, textShadow: _gtP(t, c, 0.4) }}>{text.slice(i, i + q.length)}</span>{text.slice(i + q.length)}</>;
}

// ── COMMAND PALETTE ──────────────────────────────────────────
function CommandPalette({ t, platform, onClose, compact }) {
  const [q, setQ] = React.useState('');
  const c = _ngP(t);
  const inputRef = React.useRef(null);
  React.useEffect(() => { const id = setTimeout(() => inputRef.current && inputRef.current.focus(), 60); return () => clearTimeout(id); }, []);

  // build result groups from the query
  const groups = React.useMemo(() => {
    const out = [];
    const scoreSort = (arr) => arr.filter(x => x.s != null).sort((a, b) => b.s - a.s).map(x => x.v);

    // sessions
    const sess = scoreSort(SESSIONS.map(v => {
      const hay = `${v.name} ${v.repo} ${v.branch} ${v.agent}`;
      return { v, s: q ? fuzzy(q, hay) : 1 };
    }));
    if (sess.length) out.push({ key: 'sessions', label: 'Sessions', icon: 'chat', items: sess.slice(0, 6).map(v => ({ kind: 'session', v })) });

    // repos
    const repos = scoreSort(REPOS.map(r => ({ v: r, s: q ? fuzzy(q, r) : 1 })));
    if (repos.length) out.push({ key: 'repos', label: 'Repositories', icon: 'folder', items: repos.map(r => ({ kind: 'repo', v: r })) });

    // branches
    const branches = scoreSort(SESSIONS.map(v => ({ v, s: q ? fuzzy(q, v.branch) : null })));
    if (branches.length && q) out.push({ key: 'branches', label: 'Branches', icon: 'branch', items: branches.slice(0, 5).map(v => ({ kind: 'branch', v })) });

    // messages (only when searching)
    if (q) {
      const msgs = [];
      SESSIONS.forEach(v => v.messages.forEach(m => { const s = fuzzy(q, m); if (s != null) msgs.push({ v, m, s }); }));
      msgs.sort((a, b) => b.s - a.s);
      if (msgs.length) out.push({ key: 'messages', label: 'In messages', icon: 'search', items: msgs.slice(0, 5).map(x => ({ kind: 'message', v: x.v, m: x.m })) });
    }
    return out;
  }, [q]);

  const total = groups.reduce((n, g) => n + g.items.length, 0);
  const ic = (name, color, s) => (PL.I[name] || PL.I.chat)(color, s);

  return (
    <div onClick={onClose} style={{ position: 'absolute', inset: 0, zIndex: 80, display: 'flex', flexDirection: 'column',
      alignItems: 'center', paddingTop: compact ? 60 : 84, background: t.dark ? 'rgba(2,4,10,0.62)' : 'rgba(20,30,52,0.34)',
      backdropFilter: 'blur(4px)', WebkitBackdropFilter: 'blur(4px)' }}>
      <div onClick={e => e.stopPropagation()} style={{ width: compact ? '92%' : 560, maxWidth: '92%', maxHeight: '78%',
        display: 'flex', flexDirection: 'column', borderRadius: 18, overflow: 'hidden',
        background: t.surfaceSolid, border: `1px solid ${t.glow ? c + '55' : t.borderStrong}`,
        boxShadow: t.glow ? `${_gbP(t, c, 0.6)}, 0 30px 80px rgba(0,0,0,0.5)` : '0 30px 80px rgba(0,0,0,0.4)' }}>
        {/* search field */}
        <div style={{ display: 'flex', alignItems: 'center', gap: 11, padding: '14px 16px', borderBottom: `1px solid ${t.border}` }}>
          {PL.I.search(t.glow ? c : t.textDim, 19)}
          <input ref={inputRef} value={q} onChange={e => setQ(e.target.value)} placeholder="Search sessions, repos, branches, messages…"
            style={{ flex: 1, appearance: 'none', background: 'transparent', border: 'none', outline: 'none',
              fontFamily: t.font, fontSize: 16, color: t.text, caretColor: c }} />
          <span style={{ fontFamily: t.mono, fontSize: 10.5, color: t.textFaint, padding: '3px 7px', borderRadius: 6, border: `1px solid ${t.border}` }}>esc</span>
        </div>

        {/* quick filters */}
        <div style={{ display: 'flex', gap: 7, padding: '10px 16px', flexWrap: 'wrap', borderBottom: `1px solid ${t.border}` }}>
          {['agent:claude', 'agent:codex', 'status:live', 'repo:envoy-api'].map(f => (
            <button key={f} onClick={() => setQ(f.split(':')[1])} style={{ appearance: 'none', cursor: 'pointer',
              fontFamily: t.mono, fontSize: 11, color: t.textDim, padding: '4px 9px', borderRadius: 99,
              background: t.dark ? 'rgba(255,255,255,0.04)' : 'rgba(0,0,0,0.03)', border: `1px solid ${t.border}` }}>{f}</button>
          ))}
        </div>

        {/* results */}
        <div style={{ flex: 1, overflow: 'auto', padding: '8px 8px 10px' }}>
          {total === 0 && (
            <div style={{ padding: '34px 16px', textAlign: 'center', fontFamily: t.mono, fontSize: 12.5, color: t.textFaint }}>
              No matches for “{q}”
            </div>
          )}
          {groups.map(g => (
            <div key={g.key} style={{ marginBottom: 8 }}>
              <div style={{ display: 'flex', alignItems: 'center', gap: 7, padding: '6px 10px 5px' }}>
                <span style={{ fontFamily: t.mono, fontSize: 10, letterSpacing: 1.4, textTransform: 'uppercase', color: t.textFaint }}>{g.label}</span>
                <span style={{ height: 1, flex: 1, background: t.border }} />
              </div>
              {g.items.map((it, i) => {
                const agent = it.v.agent;
                const ac = it.kind === 'repo' ? t.textDim : PL.agentColor(t, agent);
                return (
                  <div key={i} style={{ display: 'flex', alignItems: 'center', gap: 11, padding: '9px 11px', borderRadius: 11, cursor: 'pointer' }}
                    onMouseEnter={e => e.currentTarget.style.background = t.dark ? 'rgba(255,255,255,0.05)' : 'rgba(0,0,0,0.035)'}
                    onMouseLeave={e => e.currentTarget.style.background = 'transparent'}>
                    <div style={{ width: 30, height: 30, borderRadius: 8, flexShrink: 0, display: 'flex', alignItems: 'center', justifyContent: 'center',
                      background: `${ac}16`, border: `1px solid ${ac}30` }}>{ic(g.icon, ac, 15)}</div>
                    <div style={{ flex: 1, minWidth: 0 }}>
                      {it.kind === 'session' && <>
                        <div style={{ fontFamily: t.font, fontSize: 13.5, fontWeight: 600, color: t.text, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}><Hi t={t} text={it.v.name} q={q} /></div>
                        <div style={{ fontFamily: t.mono, fontSize: 10.5, color: t.textFaint, marginTop: 2 }}><span style={{ color: ac }}>{agent}</span> · {it.v.repo}:{it.v.branch}</div>
                      </>}
                      {it.kind === 'repo' && <div style={{ fontFamily: t.mono, fontSize: 13.5, color: t.text }}><Hi t={t} text={it.v} q={q} /></div>}
                      {it.kind === 'branch' && <>
                        <div style={{ fontFamily: t.mono, fontSize: 13, color: t.text }}><Hi t={t} text={it.v.branch} q={q} /></div>
                        <div style={{ fontFamily: t.mono, fontSize: 10.5, color: t.textFaint, marginTop: 2 }}>{it.v.repo} · {it.v.name}</div>
                      </>}
                      {it.kind === 'message' && <>
                        <div style={{ fontFamily: t.font, fontSize: 12.5, color: t.textDim, lineHeight: 1.4, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>“<Hi t={t} text={it.m} q={q} />”</div>
                        <div style={{ fontFamily: t.mono, fontSize: 10.5, color: t.textFaint, marginTop: 2 }}>{it.v.name}</div>
                      </>}
                    </div>
                    {it.kind === 'session' && <span style={{ flexShrink: 0 }}><OutcomeChips t={t} o={{ pr: it.v.outcomes.pr }} dense /></span>}
                    {PL.I.chevR(t.textFaint, 14)}
                  </div>
                );
              })}
            </div>
          ))}
        </div>

        {/* footer key hints */}
        <div style={{ display: 'flex', alignItems: 'center', gap: 16, padding: '9px 16px', borderTop: `1px solid ${t.border}`,
          fontFamily: t.mono, fontSize: 10.5, color: t.textFaint }}>
          <span><b style={{ color: t.textDim }}>↑↓</b> navigate</span>
          <span><b style={{ color: t.textDim }}>↵</b> open</span>
          <span><b style={{ color: t.textDim }}>⌘K</b> toggle</span>
          <span style={{ marginLeft: 'auto' }}>{total} result{total === 1 ? '' : 's'}</span>
        </div>
      </div>
    </div>
  );
}

// ── HISTORY (override): grouped by time, outcome-first, opens palette ──
function HistoryRow2({ t, s }) {
  const c = PL.agentColor(t, s.agent);
  const sc = s.status === 'live' ? t.green : s.status === 'paused' ? t.claude : s.status === 'archived' ? t.textFaint : t.textDim;
  return (
    <div style={{ display: 'flex', gap: 12, padding: '12px 13px', alignItems: 'flex-start',
      background: t.surface, borderRadius: t.radius - 4, border: `1px solid ${t.border}`, opacity: s.status === 'archived' ? 0.72 : 1 }}>
      <div style={{ width: 34, height: 34, borderRadius: 9, flexShrink: 0, display: 'flex', alignItems: 'center', justifyContent: 'center',
        background: `${c}16`, border: `1px solid ${c}33` }}>
        <PL.ConduitMark t={t} size={20} color={c} />
      </div>
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 7 }}>
          <span style={{ fontFamily: t.font, fontSize: 14, fontWeight: 600, color: t.text, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis', flex: 1 }}>{s.name}</span>
          <PL.Dot color={sc} glow={t.glow} size={6} />
          <span style={{ fontFamily: t.mono, fontSize: 10, color: t.textFaint }}>{s.when}</span>
        </div>
        <div style={{ fontFamily: t.mono, fontSize: 10.5, color: t.textFaint, marginTop: 3 }}><span style={{ color: c }}>{s.agent}</span> · {s.repo}:{s.branch}</div>
        <div style={{ marginTop: 8 }}><OutcomeChips t={t} o={s.outcomes} /></div>
      </div>
    </div>
  );
}

function HistoryScreen({ t, platform }) {
  const [pal, setPal] = React.useState(false);
  const order = ['Today', 'Yesterday', 'This week', 'Earlier'];
  const byGroup = order.map(g => [g, SESSIONS.filter(s => s.group === g)]).filter(([, a]) => a.length);
  const c = _ngP(t);
  return (
    <PL.Screen t={t}>
      <PL.AppBar t={t} platform={platform}
        leading={<PL.NavBtn t={t} platform={platform}>{PL.I.back(t.textDim)}</PL.NavBtn>}
        center={<span style={{ fontFamily: t.font, fontSize: 17, fontWeight: 700, color: t.text }}>History</span>}
        trailing={<PL.NavBtn t={t} platform={platform}>{PL.I.archive(t.textDim)}</PL.NavBtn>} />
      <div style={{ flex: 1, overflow: 'auto', padding: '0 14px' }}>
        {/* tap-to-search → command palette */}
        <button onClick={() => setPal(true)} style={{ appearance: 'none', cursor: 'pointer', width: '100%', display: 'flex', alignItems: 'center', gap: 10,
          padding: '11px 14px', borderRadius: 13, marginBottom: 16, textAlign: 'left',
          background: t.dark ? 'rgba(255,255,255,0.05)' : '#fff', border: `1px solid ${t.glow ? c + '40' : t.border}`,
          boxShadow: t.glow ? _gbP(t, c, 0.22) : 'none' }}>
          {PL.I.search(t.glow ? c : t.textDim, 17)}
          <span style={{ flex: 1, fontFamily: t.font, fontSize: 14, color: t.textFaint }}>Search everything…</span>
          <span style={{ fontFamily: t.mono, fontSize: 10.5, color: t.textFaint, padding: '3px 7px', borderRadius: 6, border: `1px solid ${t.border}` }}>⌘K</span>
        </button>

        {byGroup.map(([g, items]) => (
          <div key={g} style={{ marginBottom: 16 }}>
            <PL.SectionLabel t={t}>{g}</PL.SectionLabel>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 9 }}>
              {items.map(s => <HistoryRow2 key={s.id} t={t} s={s} />)}
            </div>
          </div>
        ))}
      </div>
      <div style={{ height: PL.botPad(platform) }} />
      {pal && <CommandPalette t={t} platform={platform} compact onClose={() => setPal(false)} />}
    </PL.Screen>
  );
}

Object.assign(window, { SESSIONS, REPOS, fuzzy, OutcomeChips, CommandPalette, HistoryScreen });
