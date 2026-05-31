// neon-screens.jsx — enhanced Chat + Terminal for the Neon prototype,
// showcasing the upgraded command + subagent/handoff cards.
const NS = window;

function NeonChatScreen({ t, platform }) {
  const [info, setInfo] = React.useState(false);
  return (
    <NS.Screen t={t}>
      <NS.SessionHeader t={t} platform={platform} title="Fix auth refresh loop" agent="claude" branch="fix/auth" status="live" onInfo={() => setInfo(true)} />
      <NS.TabBar t={t} platform={platform} active="chat" />
      <div style={{ flex: 1, overflow: 'auto', padding: '4px 12px' }}>
        <NS.UserBubble t={t}>the token refresh loops on a 401 — find it, fix it, and make sure tests pass</NS.UserBubble>

        <NS.Assistant t={t}>On it. Here's my plan:</NS.Assistant>
        <NS.PlanCard t={t} steps={[
          { label: 'Locate the refresh path', state: 'done' },
          { label: 'Patch the re-entry bug', state: 'done' },
          { label: 'Run the auth test suite', state: 'active' },
          { label: 'Commit on fix/auth', state: 'todo' },
        ]} />

        <NS.Assistant t={t}>Found it in <NS.Code t={t}>auth/session.ts</NS.Code> — the 401 handler re-enters <NS.Code t={t}>refresh()</NS.Code> before the new token is saved.</NS.Assistant>
        <NS.CommandCard t={t} cmd="rg -n 'refresh\\(' src/auth" cwd="~/envoy-api" state="ok" exit={0} ms="120ms" out={[
          'session.ts:42:  if (res.status === 401) refresh()',
          'session.ts:58:  await refresh()   // re-entry',
        ]} />

        <NS.DiffCard t={t} file="src/auth/session.ts" added={4} removed={2} lines={[
          ' async function refresh() {',
          '-  const t = await mint()',
          '+  if (inFlight) return inFlight',
          '+  inFlight = mint().then(save)',
          ' }',
        ]} />

        <NS.CommandCard t={t} cmd="npm test -- auth" cwd="~/envoy-api" state="fail" exit={1} ms="2.4s" out={[
          ' ✓ refreshes once on 401',
          '! ✗ clears inFlight after failure',
          '! AssertionError: expected null',
          '! Tests: 1 failed, 6 passed',
        ]} />

        <NS.Assistant t={t}>One edge case left — <NS.Code t={t}>inFlight</NS.Code> isn't reset when mint throws. I'll hand the regression test to a subagent while I patch:</NS.Assistant>
        <NS.HandoffCard t={t} from="claude" to="codex" task="Write a regression test: inFlight must reset to null when mint() rejects, so a later 401 can retry."
          state="done" steps={3} tokens="12.4k"
          result="Added auth/session.test.ts ›  “retries after a failed refresh”. Reproduces the bug, green against the patched guard." />

        <NS.CommandCard t={t} cmd="npm test -- auth" cwd="~/envoy-api" state="ok" exit={0} ms="0.9s" out={[
          ' ✓ refreshes once on 401',
          ' ✓ does not loop on repeat 401',
          ' ✓ retries after a failed refresh',
          ' Tests: 7 passed (7)',
        ]} />

        <NS.PendingCard t={t} prompt="All green. Commit on fix/auth?"
          options={['Commit “fix: guard token refresh re-entry”', 'Edit the message', 'Not yet']} />
      </div>
      <NS.QuickReplies t={t} items={['Commit & push', 'Open a PR', 'Show the diff']} />
      <NS.Composer t={t} platform={platform} />
      <div style={{ height: NS.botPad(platform) }} />
      {info && <NS.SessionInfoSheet t={t} platform={platform} onClose={() => setInfo(false)} />}
    </NS.Screen>
  );
}

// ── Interactive Settings (Appearance controls drive the real theme) ──
function NeonSettingsScreen({ t, platform, tw, setTweak }) {
  const ig = NS.neonGlowColor(t);
  const PAL = NS.NEON_PALETTES;
  const card = { borderRadius: t.radius - 4, overflow: 'hidden', border: `1px solid ${t.border}`, background: t.surface, marginBottom: 16 };
  const rowPad = { padding: '13px 14px' };

  const Seg = ({ value, options, onPick }) => (
    <div style={{ display: 'flex', gap: 4, padding: 3, borderRadius: 11, background: t.dark ? 'rgba(0,0,0,0.3)' : 'rgba(13,26,48,0.06)', border: `1px solid ${t.border}` }}>
      {options.map(o => {
        const on = o === value;
        return (
          <button key={o} onClick={() => onPick(o)} style={{ appearance: 'none', cursor: 'pointer', flex: 1, padding: '7px 10px', borderRadius: 8,
            background: on ? (t.dark ? `${ig}22` : '#fff') : 'transparent', border: on ? `1px solid ${t.dark ? ig + '66' : t.accent + '44'}` : '1px solid transparent',
            color: on ? (t.dark ? ig : t.accent) : t.textDim, fontFamily: t.font, fontSize: 12.5, fontWeight: on ? 700 : 500, textTransform: 'capitalize',
            boxShadow: on && t.glow ? `0 0 12px ${ig}33` : 'none', transition: 'all .12s' }}>{o}</button>
        );
      })}
    </div>
  );
  const Switch = ({ on, onToggle }) => (
    <button onClick={onToggle} style={{ appearance: 'none', cursor: 'pointer', width: 46, height: 28, borderRadius: 99, padding: 3, border: 'none', display: 'flex', alignItems: 'center',
      justifyContent: on ? 'flex-end' : 'flex-start', background: on ? (t.dark ? ig : t.accent) : (t.dark ? 'rgba(255,255,255,0.14)' : 'rgba(13,26,48,0.16)'),
      boxShadow: on && t.glow ? `0 0 14px ${ig}88` : 'none', transition: 'all .15s' }}>
      <span style={{ width: 22, height: 22, borderRadius: 99, background: '#fff', boxShadow: '0 1px 3px rgba(0,0,0,0.3)' }} />
    </button>
  );

  return (
    <NS.Screen t={t}>
      <NS.AppBar t={t} platform={platform}
        leading={<NS.NavBtn t={t} platform={platform}>{NS.I.back(t.textDim)}</NS.NavBtn>}
        center={<span style={{ fontFamily: t.font, fontSize: 17, fontWeight: 700, color: t.text }}>Settings</span>}
        trailing={<span />} />
      <div style={{ flex: 1, overflow: 'auto', padding: '4px 14px' }}>
        {/* identity */}
        <div style={{ display: 'flex', alignItems: 'center', gap: 13, padding: 15, borderRadius: t.radius - 2, marginBottom: 18, background: t.surface, border: `1px solid ${t.border}`, boxShadow: t.glow ? `0 0 22px ${ig}22` : 'none' }}>
          <NS.AppIcon size={50} />
          <div style={{ flex: 1 }}>
            <div style={{ fontFamily: t.mono, fontSize: 15, fontWeight: 700, color: t.text, letterSpacing: 0.5 }}>conduit</div>
            <div style={{ fontFamily: t.mono, fontSize: 11, color: t.textFaint, marginTop: 2 }}>v1.4.0 · broker :1977</div>
          </div>
          <span style={{ display: 'inline-flex', alignItems: 'center', gap: 5, fontFamily: t.mono, fontSize: 11, color: t.green }}><NS.Dot color={t.green} glow={t.glow} size={6} />synced</span>
        </div>

        {/* APPEARANCE — interactive */}
        <NS.SectionLabel t={t}>Appearance</NS.SectionLabel>
        <div style={card}>
          <div style={{ ...rowPad }}>
            <div style={{ fontFamily: t.font, fontSize: 15, fontWeight: 600, color: t.text, marginBottom: 9 }}>Mode</div>
            <Seg value={tw.mode} options={['dark', 'light']} onPick={(v) => setTweak('mode', v)} />
          </div>
          <div style={{ height: 1, background: t.border }} />
          <div style={{ ...rowPad }}>
            <div style={{ display: 'flex', alignItems: 'baseline', justifyContent: 'space-between', marginBottom: 10 }}>
              <span style={{ fontFamily: t.font, fontSize: 15, fontWeight: 600, color: t.text }}>Accent palette</span>
              <span style={{ fontFamily: t.mono, fontSize: 11.5, color: t.accent }}>{PAL[tw.palette].label}</span>
            </div>
            <div style={{ display: 'flex', gap: 9 }}>
              {Object.entries(PAL).map(([id, p]) => {
                const on = id === tw.palette;
                return (
                  <button key={id} onClick={() => setTweak('palette', id)} style={{ appearance: 'none', cursor: 'pointer', flex: 1, display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 6, padding: '4px 0', background: 'none', border: 'none' }}>
                    <span style={{ width: 38, height: 38, borderRadius: 11, background: `linear-gradient(135deg, ${p.accent}, ${p.accent2})`,
                      border: on ? `2px solid ${t.text}` : `1px solid ${t.border}`,
                      boxShadow: on ? `0 0 0 2px ${p.accent}, 0 0 16px ${p.accent}88` : 'none', transition: 'all .12s' }} />
                    <span style={{ fontFamily: t.mono, fontSize: 9.5, color: on ? t.text : t.textFaint, fontWeight: on ? 700 : 400 }}>{p.label}</span>
                  </button>
                );
              })}
            </div>
          </div>
          <div style={{ height: 1, background: t.border }} />
          <div style={{ ...rowPad, display: 'flex', alignItems: 'center', gap: 12 }}>
            <div style={{ flex: 1 }}>
              <div style={{ fontFamily: t.font, fontSize: 15, fontWeight: 600, color: t.text }}>Glow &amp; scanlines</div>
              <div style={{ fontFamily: t.mono, fontSize: 11, color: t.textFaint, marginTop: 2 }}>neon halos · {t.dark ? 'on dark' : 'dimmed in light'}</div>
            </div>
            <Switch on={tw.glow} onToggle={() => setTweak('glow', !tw.glow)} />
          </div>
        </div>

        {/* live preview chip */}
        <div style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '11px 13px', borderRadius: 12, marginBottom: 18, background: t.codeBg, border: `1px solid ${t.borderStrong}`, boxShadow: t.glow ? `0 0 18px ${ig}33` : 'none' }}>
          <span style={{ fontFamily: t.mono, fontSize: 13, color: ig, textShadow: NS.gT(t, ig, 0.6) }}>$</span>
          <span style={{ flex: 1, fontFamily: t.mono, fontSize: 12.5, color: t.codeText || t.text }}>conduit --theme {tw.palette}</span>
          <span style={{ fontFamily: t.mono, fontSize: 11, color: t.green }}>preview</span>
        </div>

        {/* TERMINAL */}
        <NS.SectionLabel t={t}>Terminal</NS.SectionLabel>
        <div style={card}>
          <div style={{ ...rowPad, display: 'flex', alignItems: 'center', gap: 12 }}>
            <div style={{ flex: 1 }}>
              <div style={{ fontFamily: t.font, fontSize: 15, fontWeight: 600, color: t.text }}>Native Ghostty terminal</div>
              <div style={{ fontFamily: t.mono, fontSize: 11, color: t.textFaint, marginTop: 2 }}>experimental · Metal renderer</div>
            </div>
            <Switch on={false} onToggle={() => {}} />
          </div>
          <div style={{ height: 1, background: t.border }} />
          <div style={{ ...rowPad, display: 'flex', alignItems: 'center', gap: 12 }}>
            <div style={{ flex: 1 }}>
              <div style={{ fontFamily: t.font, fontSize: 15, fontWeight: 600, color: t.text }}>Accessory key bar</div>
              <div style={{ fontFamily: t.mono, fontSize: 11, color: t.textFaint, marginTop: 2 }}>esc · ctrl · arrows</div>
            </div>
            <Switch on={true} onToggle={() => {}} />
          </div>
        </div>

        {/* ACCOUNTS */}
        <NS.SectionLabel t={t}>Agents &amp; accounts</NS.SectionLabel>
        <div style={card}>
          <NS.Row t={t} leading={<NS.Dot color={t.claude} glow={t.glow} size={10} />} title="Anthropic" sub="claude" badge={<span style={{ fontFamily: t.mono, fontSize: 10, color: t.green }}>linked</span>} trailing={NS.I.chevR(t.textFaint, 14)} />
          <div style={{ height: 1, background: t.border }} />
          <NS.Row t={t} leading={<NS.Dot color={t.codex} glow={t.glow} size={10} />} title="OpenAI" sub="codex" badge={<span style={{ fontFamily: t.mono, fontSize: 10, color: t.green }}>linked</span>} trailing={NS.I.chevR(t.textFaint, 14)} />
          <div style={{ height: 1, background: t.border }} />
          <div style={{ ...rowPad, display: 'flex', alignItems: 'center', gap: 12 }}>
            <div style={{ flex: 1 }}>
              <div style={{ fontFamily: t.font, fontSize: 15, fontWeight: 600, color: t.text }}>Push notifications</div>
              <div style={{ fontFamily: t.mono, fontSize: 11, color: t.textFaint, marginTop: 2 }}>when an agent needs you</div>
            </div>
            <Switch on={true} onToggle={() => {}} />
          </div>
        </div>

        <div style={{ display: 'flex', gap: 18, justifyContent: 'center', fontFamily: t.mono, fontSize: 11.5, color: t.textFaint, padding: '6px 0' }}>
          <span>Licenses</span><span>Self-host docs</span><span>Sign out</span>
        </div>
      </div>
      <div style={{ height: NS.botPad(platform) }} />
    </NS.Screen>
  );
}

Object.assign(window, { NeonChatScreen, NeonSettingsScreen });
