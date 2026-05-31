// neon-theme.jsx — cyberpunk Neon theme factory.
// makeNeon({ mode:'dark'|'light', palette:'ice'|'synth'|'matrix'|'amber', glow:bool })
// returns a token object shaped like themes.jsx, consumable by every screen.

const NEON_PALETTES = {
  ice:    { label: 'Ice',       accent: '#22d3ee', accent2: '#4f8cff', accentDark: '#0a93ad' },
  synth:  { label: 'Synthwave', accent: '#ff49e0', accent2: '#22d3ee', accentDark: '#c01ea6' },
  matrix: { label: 'Matrix',    accent: '#39f08a', accent2: '#b6f23d', accentDark: '#14a85c' },
  amber:  { label: 'Amber CRT', accent: '#ffb627', accent2: '#ff7847', accentDark: '#c6810a' },
};

function makeNeon({ mode = 'dark', palette = 'ice', glow = true } = {}) {
  const p = NEON_PALETTES[palette] || NEON_PALETTES.ice;
  const dark = mode === 'dark';
  const A = p.accent, A2 = p.accent2;

  const common = {
    id: 'neon',
    name: 'Neon Terminal',
    paletteId: palette,
    mode,
    glow,
    dark,
    accent: A,
    accent2: A2,
    // agent + status wires (kept constant so agents stay recognizable)
    claude: dark ? '#ff9d4d' : '#d9731a',
    codex: A,
    purple: dark ? '#b487ff' : '#7a48d8',
    blue: A2,
    green: dark ? '#3ef0a0' : '#12a866',
    red: dark ? '#ff5c72' : '#d83048',
    yellow: dark ? '#ffd24d' : '#c79200',
    font: "'Space Grotesk', system-ui, sans-serif",
    mono: "'JetBrains Mono', ui-monospace, monospace",
    radius: 20,
  };

  if (dark) {
    return {
      ...common,
      bg: '#04050a',
      appBg: `radial-gradient(125% 90% at 50% -12%, ${A}14 0%, #0a1020 34%, #05060d 70%, #04050a 100%)`,
      surface: 'rgba(16,24,42,0.66)',
      surface2: 'rgba(26,38,64,0.74)',
      surfaceSolid: '#0a1120',
      panel: '#0b1322',
      border: `${A}22`,
      borderStrong: `${A}44`,
      grid: `${A}0e`,
      text: '#eaf3ff',
      textDim: 'rgba(196,214,244,0.66)',
      textFaint: 'rgba(160,184,224,0.40)',
      accentText: '#03121a',
      codeBg: 'rgba(0,4,12,0.6)',
    };
  }
  // LIGHT cyberpunk: cool paper-white, ink navy text, neon as saturated ink + halos
  return {
    ...common,
    accent: p.accentDark,           // darker accent for contrast on white
    accentBright: A,                // keep bright for glows/badges
    bg: '#dfe6f2',
    appBg: `radial-gradient(125% 90% at 50% -12%, ${A}1f 0%, #eef3fb 40%, #e7edf7 100%)`,
    surface: 'rgba(255,255,255,0.8)',
    surface2: '#ffffff',
    surfaceSolid: '#ffffff',
    panel: '#f4f7fc',
    border: 'rgba(18,32,58,0.12)',
    borderStrong: `${p.accentDark}55`,
    grid: 'rgba(18,32,58,0.05)',
    text: '#0d1a30',
    textDim: 'rgba(28,46,78,0.66)',
    textFaint: 'rgba(40,60,96,0.42)',
    accentText: '#ffffff',
    codeBg: '#0c1322',              // code blocks stay dark even in light mode (terminal feel)
    codeText: '#d6e6ff',
  };
}

// helper: bright accent for glows (light mode uses accentBright)
function neonGlowColor(t, c) {
  if (c) return c;
  return t.accentBright || t.accent;
}

Object.assign(window, { NEON_PALETTES, makeNeon, neonGlowColor });
