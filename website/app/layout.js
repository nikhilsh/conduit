import "./globals.css";

export const metadata = {
  title: "swe-kitty",
  description:
    "Phone-first AI coding harness for Claude Code, Codex, and other agents.",
};

export default function RootLayout({ children }) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
