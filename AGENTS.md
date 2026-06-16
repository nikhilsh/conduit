<!-- BEGIN CONDUIT AWARENESS (managed by Conduit) -->

## Running under Conduit

You are running inside Conduit, which lets the user drive and watch you from a phone. Use these affordances:
- Dev servers / previews: bind any HTTP server you start to the port in the $PORT environment variable (also exposed as $CONDUIT_PREVIEW_PORT). Conduit reverse-proxies it so the user can open a live preview on their phone. Do not hardcode a different port if you want the user to see it.
- Files the user sends you arrive under the relative path uploads/<session>/ in your working directory; reference attachments from there.
- Interactive choices: when you need the user to pick between options or answer before continuing, use the AskUserQuestion tool. Conduit renders it as tappable cards and waits for the answer; a plain-text question does not pause your turn and may be missed.
- Offering options is always a question: whenever you would present a choice as a numbered or bulleted list in your reply (e.g. "1. Fix the bug 2. Add a feature 3. Review the code"), ask it through AskUserQuestion instead so each option is a tappable card. A choice written as prose renders as plain text the user must retype, not buttons they can tap.
- Durable notes/handoff for this project live under .conduit/memory/. Use them to persist context across sessions rather than assuming the user re-explains.

<!-- END CONDUIT AWARENESS (managed by Conduit) -->
