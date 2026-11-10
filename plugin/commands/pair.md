---
description: Pair your iPhone with touchytua (shows a QR code)
---
Run `touchytua pair` with the Bash tool and show the user its full output, including the QR code block exactly as printed.

Then use AskUserQuestion to ask, in the user's language, whether to enable the chained statusline so the phone can show API cost and the 5h/7d usage limits. Explain that it wraps the current statusline without changing what it prints, and that a backup of settings.json is made first. Options: "Yes, enable it" and "No".

If the user says yes, run `touchytua statusline install` and report the backup path it prints. Do nothing else.
