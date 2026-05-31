// themes.jsx — three aesthetic directions for Conduit, as token sets.
// Each screen component consumes a theme `t` + a `platform` string.

const NEON = {
  id: 'neon',
  name: 'Neon Terminal',
  dark: true,
  // surfaces
  bg: '#06070d',            // device backdrop (deep space navy)
  appBg: 'radial-gradient(120% 90% at 50% -10%, #11203a 0%, #0a0f1e 42%, #06070d 100%)',
  surface: 'rgba(20,30,52,0.66)',
  surface2: 'rgba(30,44,72,0.72)',
  surfaceSolid: '#0c1322',
  border: 'rgba(120,170,255,0.16)',
  borderStrong: 'rgba(120,180,255,0.32)',
  // text
  text: '#eaf2ff',
  textDim: 'rgba(200,216,245,0.66)',
  textFaint: 'rgba(170,190,230,0.40)',
  // accents
  accent: '#3dd9eb',        // cyan whisker — primary
  accent2: '#5b8cff',       // blue
  accentText: '#03121a',
  // agent + status colors (the four neon wires)
  claude: '#ffae57',        // orange
  codex: '#3dd9eb',         // cyan
  purple: '#a98bff',
  blue: '#5b8cff',
  green: '#46e0a8',
  red: '#ff6b81',
  // type
  font: "'Space Grotesk', system-ui, sans-serif",
  mono: "'JetBrains Mono', ui-monospace, monospace",
  radius: 22,
  glow: true,
};

const SLATE = {
  id: 'slate',
  name: 'Slate',
  dark: true,
  bg: '#0d0f13',
  appBg: '#101318',
  surface: '#181c23',
  surface2: '#1f242d',
  surfaceSolid: '#181c23',
  border: 'rgba(255,255,255,0.07)',
  borderStrong: 'rgba(255,255,255,0.14)',
  text: '#e7eaf0',
  textDim: 'rgba(200,208,222,0.62)',
  textFaint: 'rgba(180,190,206,0.36)',
  accent: '#56b6c2',        // calm teal, used sparingly
  accent2: '#7aa2f7',
  accentText: '#06181b',
  claude: '#e0975a',
  codex: '#56b6c2',
  purple: '#9d86e0',
  blue: '#7aa2f7',
  green: '#69c08a',
  red: '#e06c75',
  font: "'IBM Plex Sans', system-ui, sans-serif",
  mono: "'IBM Plex Mono', ui-monospace, monospace",
  radius: 16,
  glow: false,
};

const PAPER = {
  id: 'paper',
  name: 'Paper',
  dark: false,
  bg: '#e9e3d8',
  appBg: '#f7f3ea',
  surface: '#ffffff',
  surface2: '#fbf8f1',
  surfaceSolid: '#ffffff',
  border: 'rgba(40,33,22,0.10)',
  borderStrong: 'rgba(40,33,22,0.18)',
  text: '#241f17',
  textDim: 'rgba(60,52,40,0.66)',
  textFaint: 'rgba(80,70,55,0.42)',
  accent: '#1c2330',        // ink navy — primary action
  accent2: '#c8632b',       // warm orange whisker accent
  accentText: '#f7f3ea',
  claude: '#c8632b',
  codex: '#2c7d72',
  purple: '#7a5bd0',
  blue: '#2f6bd0',
  green: '#2c8a55',
  red: '#c0413f',
  font: "'Hanken Grotesk', system-ui, sans-serif",
  mono: "'Spline Sans Mono', ui-monospace, monospace",
  radius: 18,
  glow: false,
};

const THEMES = { neon: NEON, slate: SLATE, paper: PAPER };

// glow helper: text glow only in dark mode; box glow softens in light
function glowText(t, color, strength = 1) {
  if (!t.glow || !t.dark) return 'none';
  const c = color || t.accent;
  return `0 0 ${6 * strength}px ${c}cc, 0 0 ${16 * strength}px ${c}66`;
}
function glowBox(t, color, strength = 1) {
  if (!t.glow) return 'none';
  const c = color || t.accent;
  const s = t.dark ? strength : strength * 0.6;
  return `0 0 ${10 * s}px ${c}33, 0 0 ${28 * s}px ${c}1f`;
}
// hex + alpha (00-ff) helper for agent tint chips
function tint(hex, a) {
  return hex + a;
}

Object.assign(window, { THEMES, NEON, SLATE, PAPER, glowText, glowBox, tint });
