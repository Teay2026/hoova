# Security

Hoova reads what's on your screen: the word under your pointer, the text you select, and the text around them. A security hole in Hoova could expose that text. Please report one privately.

## Report a vulnerability

Use [Report a vulnerability](https://github.com/Teay2026/hoova/security/advisories/new), on the Security tab of this repository. Only the maintainer sees your report.

Please don't open a public issue, discussion or pull request for a vulnerability.

Tell us:

- what an attacker could do, and in which conditions;
- how to reproduce it, step by step;
- the Hoova version and the macOS version.

Never include an API key, a password, or a screenshot with private text.

## What happens next

Hoova has a single maintainer, who works on it in their free time. You'll get an answer within a week. Once a fix is out, the advisory is published, with your name if you want it.

## What's covered

- The app: reading the screen, the AI models, the API keys and the downloads.
- `scripts/build-app.sh`.
- The website, in `site/`.

Only the latest release gets security fixes.
