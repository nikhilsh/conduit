// neon-app.jsx — interactive Neon prototype: a phone with a screen switcher
// and a Tweaks panel (mode / palette / glow / platform).

const NA = window;
const { makeNeon, NEON_PALETTES } = window;

const SCREENS = [
  ['chat', 'Chat', (t, p) => <NA.NeonChatScreen t={t} platform={p} />],
  ['home', 'Home', (t, p) => <NA.HomeScreen t={t} platform={p} />],
  ['terminal', 'Terminal', (t, p) => <NA.TerminalScreen t={t} platform={p} />],
  ['browser', 'Browser', (t, p) => <NA.BrowserScreen t={t} platform={p} />],
  ['new', 'New', (t, p) => <NA.NewSessionScreen t={t} platform={p} />],
  ['history', 'History', (t, p) => <NA.HistoryScreen t={t} platform={p} />],
  ['connect', 'Pair', (t, p) => <NA.ConnectScreen t={t} platform={p} />],
  ['settings', 'Settings', (t, p, tw, setTweak) => <NA.NeonSettingsScreen t={t} platform={p} tw={tw} setTweak={setTweak} />],
];

const TWEAK_DEFAULTS = {
  mode: 'dark',
  palette: 'ice',
  glow: true,
  platform: 'ios',
  form: 'phone',
};
function loadSettings() {
  try { return { ...TWEAK_DEFAULTS, ...JSON.parse(localStorage.getItem('nk_settings') || '{}') }; }
  catch (e) { return { ...TWEAK_DEFAULTS }; }
}

// device frame (custom cyberpunk bezel, scales to fit)
function Phone({ t, platform, children }) {
  const W = platform === 'ios' ? 390 : 400;
  const H = 838;
  const ig = NA.neonGlowColor(t);
  return (
    <div style={{ width: W, height: H, borderRadius: platform === 'ios' ? 52 : 40, padding: 11, boxSizing: 'border-box',
      background: t.dark ? 'linear-gradient(160deg,#11161f,#04060c)' : 'linear-gradient(160deg,#cfd8e8,#aab6cc)',
      boxShadow: t.glow
        ? `0 0 0 1px ${ig}40, 0 0 38px ${ig}33, 0 30px 80px rgba(0,0,0,${t.dark ? 0.6 : 0.3})`
        : `0 0 0 1px ${t.borderStrong}, 0 30px 80px rgba(0,0,0,${t.dark ? 0.6 : 0.25})`,
      position: 'relative', flexShrink: 0 }}>
      <div style={{ width: '100%', height: '100%', borderRadius: platform === 'ios' ? 42 : 30, overflow: 'hidden', position: 'relative',
        background: t.bg, border: `1px solid ${t.dark ? 'rgba(0,0,0,0.6)' : 'rgba(255,255,255,0.5)'}` }}>
        {/* status bar */}
        <div style={{ position: 'absolute', top: 0, left: 0, right: 0, height: platform === 'ios' ? 46 : 34, zIndex: 30,
          display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: platform === 'ios' ? '0 26px' : '0 18px',
          fontFamily: t.mono, fontSize: 12.5, fontWeight: 600, color: t.text, pointerEvents: 'none' }}>
          <span style={{ paddingTop: platform === 'ios' ? 10 : 0 }}>9:41</span>
          <span style={{ display: 'flex', gap: 6, alignItems: 'center', paddingTop: platform === 'ios' ? 10 : 0, opacity: 0.85 }}>
            {NA.I.wifi(t.text, 15)}<span style={{ fontSize: 11 }}>100%</span>
          </span>
        </div>
        {platform === 'ios' && <div style={{ position: 'absolute', top: 11, left: '50%', transform: 'translateX(-50%)', width: 108, height: 30, borderRadius: 99, background: '#000', zIndex: 40 }} />}
        <div style={{ position: 'absolute', inset: 0, paddingTop: platform === 'ios' ? 0 : 0 }}>{children}</div>
      </div>
    </div>
  );
}

function ScreenSwitcher({ t, value, onPick }) {
  const ig = NA.neonGlowColor(t);
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 6, padding: 8, borderRadius: 16,
      background: t.dark ? 'rgba(12,18,32,0.7)' : 'rgba(255,255,255,0.7)', border: `1px solid ${t.border}`,
      backdropFilter: 'blur(12px)', WebkitBackdropFilter: 'blur(12px)' }}>
      {SCREENS.map(([id, label]) => {
        const on = id === value;
        return (
          <button key={id} onClick={() => onPick(id)} style={{ appearance: 'none', cursor: 'pointer', textAlign: 'left',
            display: 'flex', alignItems: 'center', gap: 8, padding: '8px 12px', borderRadius: 10, minWidth: 116,
            background: on ? (t.dark ? `${ig}1e` : `${t.accent}14`) : 'transparent',
            border: `1px solid ${on ? (t.dark ? ig + '55' : t.accent + '40') : 'transparent'}`,
            color: on ? (t.dark ? ig : t.accent) : t.textDim, fontFamily: t.font, fontSize: 13, fontWeight: on ? 700 : 500,
            boxShadow: on && t.glow ? `0 0 14px ${ig}30` : 'none', transition: 'all .12s' }}>
            <span style={{ width: 6, height: 6, borderRadius: 99, background: on ? ig : t.textFaint, boxShadow: on && t.glow ? `0 0 7px ${ig}` : 'none' }} />
            {label}
          </button>
        );
      })}
    </div>
  );
}

function App() {
  const [tw, setTw] = React.useState(loadSettings);
  const setTweak = React.useCallback((k, v) => setTw(prev => {
    const next = { ...prev, [k]: v };
    localStorage.setItem('nk_settings', JSON.stringify(next));
    return next;
  }), []);
  const [screen, setScreen] = React.useState(() => localStorage.getItem('nk_screen') || 'chat');
  React.useEffect(() => { localStorage.setItem('nk_screen', screen); }, [screen]);

  const t = React.useMemo(() => makeNeon({ mode: tw.mode, palette: tw.palette, glow: tw.glow }), [tw.mode, tw.palette, tw.glow]);
  const platform = tw.platform;
  const tablet = tw.form === 'tablet';
  const render = SCREENS.find(s => s[0] === screen)[2];
  const ig = NA.neonGlowColor(t);

  const Toggle2 = ({ value, options, onPick }) => (
    <div style={{ display: 'flex', gap: 4, padding: 3, borderRadius: 11, background: t.dark ? 'rgba(12,18,32,0.7)' : 'rgba(255,255,255,0.7)', border: `1px solid ${t.border}` }}>
      {options.map(([val, label]) => {
        const on = val === value;
        return (
          <button key={val} onClick={() => onPick(val)} style={{ appearance: 'none', cursor: 'pointer', flex: 1, padding: '7px 8px', borderRadius: 8,
            background: on ? (t.dark ? `${ig}1e` : `${t.accent}14`) : 'transparent', border: `1px solid ${on ? (t.dark ? ig + '55' : t.accent + '40') : 'transparent'}`,
            color: on ? (t.dark ? ig : t.accent) : t.textDim, fontFamily: t.font, fontSize: 12, fontWeight: on ? 700 : 500,
            boxShadow: on && t.glow ? `0 0 12px ${ig}30` : 'none', transition: 'all .12s' }}>{label}</button>
        );
      })}
    </div>
  );

  return (
    <div style={{ minHeight: '100vh', width: '100%', display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 36,
      background: t.dark
        ? `radial-gradient(120% 80% at 50% -10%, ${ig}10 0%, #05060d 55%, #030409 100%)`
        : `radial-gradient(120% 80% at 50% -10%, ${ig}22 0%, #e7edf7 55%, #dfe6f2 100%)`,
      padding: 40, boxSizing: 'border-box', flexWrap: 'wrap',
      backgroundImage: t.dark
        ? `linear-gradient(${t.grid} 1px, transparent 1px), linear-gradient(90deg, ${t.grid} 1px, transparent 1px), radial-gradient(120% 80% at 50% -10%, ${ig}10 0%, #05060d 55%, #030409 100%)`
        : `linear-gradient(${t.grid} 1px, transparent 1px), linear-gradient(90deg, ${t.grid} 1px, transparent 1px), radial-gradient(120% 80% at 50% -10%, ${ig}1c 0%, #e7edf7 55%, #dfe6f2 100%)`,
      backgroundSize: '44px 44px, 44px 44px, 100% 100%' }}>

      {/* left: title + switcher */}
      <div style={{ display: 'flex', flexDirection: 'column', gap: 18, alignSelf: 'center', flexShrink: 0 }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 11 }}>
          <NA.ConduitMark t={t} size={30} />
          <div>
            <div style={{ fontFamily: t.mono, fontSize: 17, fontWeight: 700, letterSpacing: 1, color: t.text, textShadow: NA.gT(t, ig, 0.5) }}>conduit</div>
            <div style={{ fontFamily: t.mono, fontSize: 11, color: t.textFaint }}>neon · {NEON_PALETTES[tw.palette].label.toLowerCase()} · {tw.mode}</div>
          </div>
        </div>
        {/* form factor */}
        <Toggle2 value={tw.form} options={[['phone', 'Phone'], ['tablet', 'Tablet']]} onPick={(v) => setTweak('form', v)} />
        {tablet ? (
          <div style={{ fontFamily: t.mono, fontSize: 10.5, color: t.textFaint, maxWidth: 168, lineHeight: 1.6 }}>
            <b style={{ color: t.textDim }}>Tablet IDE</b> — activity bar switches Home / Sessions / History / Boxes / Settings; Sessions shows chat + terminal / browser / usage at once. Tap <b style={{ color: t.glow ? ig : t.accent }}>Search</b> for the command palette.
          </div>
        ) : (
          <>
            <ScreenSwitcher t={t} value={screen} onPick={setScreen} />
            {/* platform switch — a viewing affordance, not a product setting */}
            <Toggle2 value={tw.platform} options={[['ios', 'iOS'], ['android', 'Android']]} onPick={(v) => setTweak('platform', v)} />
            <div style={{ fontFamily: t.mono, fontSize: 10.5, color: t.textFaint, maxWidth: 150, lineHeight: 1.5 }}>
              Theme lives in <b style={{ color: t.textDim }}>Settings ▸ Appearance</b> — mode, palette &amp; glow.
            </div>
          </>
        )}
      </div>

      {/* device */}
      {tablet
        ? <div style={{ flex: 1, minWidth: 0, display: 'flex', alignItems: 'center', justifyContent: 'center' }}><NA.TabletApp t={t} tw={tw} setTweak={setTweak} /></div>
        : <Phone t={t} platform={platform}>{render(t, platform, tw, setTweak)}</Phone>}
    </div>
  );
}

ReactDOM.createRoot(document.getElementById('root')).render(<App />);
