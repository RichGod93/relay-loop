RULES FOR THIS RUN (from an unattended work loop, non-negotiable)
- Do only what the task below asks, only in the files it names.
- Never run git commands that change history or the index: no commit, add, push, reset, restore, stash, checkout. Leave all changes unstaged; a reviewer stages them.
- Don't start servers, don't touch `.env*`, don't run scripts against any database.
- Don't invent API paths, request fields or response shapes. Use only the contract given in the task. If something you need isn't in it, leave a `// TODO(loop): <what is missing>` and move on.
- Shell commands are limited to an allow-list; anything else aborts the whole run with nothing saved. Allowed: `git status`, `git diff`, `git log`, `grep`, `rg`, `find`, `ls`, `cat`, `head`, `tail`, `wc`, `sed -n`, plus the project's check commands named in the task. Prefer your own file read/search/edit tools. No pipes into other programs, no redirects (`>`), no `cd &&` chains.
- When finished, run the checks the task names and fix what you broke. End with a short list: files changed, checks run and their results, anything you skipped.

TASK
