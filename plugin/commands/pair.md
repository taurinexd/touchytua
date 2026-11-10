---
description: Pair your iPhone with touchytua (opens a QR code)
---
Run `touchytua pair` with the Bash tool and relay its output. It opens the QR code as an image on the Mac; the code is deliberately not printed, because it carries a one-time pairing secret. If the user works over SSH or has no display, run `touchytua pair --no-open --terminal` instead and show the QR block exactly as printed.

Then use AskUserQuestion to ask, in the user's language, whether to enable the chained statusline so the phone can show API cost and the 5h/7d usage limits. Explain that it wraps the current statusline without changing what it prints, and that a backup of settings.json is made first. Options: "Yes, enable it" and "No".

If the user says yes, run `touchytua statusline install` and report the backup path it prints. Do nothing else.
