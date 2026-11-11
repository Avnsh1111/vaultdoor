---
name: vaultdoor
description: Keeps passwords, SSH logins and API tokens in an encrypted local vault so AI tools can use them without ever seeing them, with a visual dashboard for servers, per-project access and automatic deployment scripts. Use this skill whenever a task needs a credential or a server, such as deploying, running a command on a server, a database or server password, an API token, or anything in a .deploy or .env file. Also use it when the user wants to set up or install VaultDoor, hide secrets from AI, add a password or server, map a server to a project, set up auto deployment, or control which apps an AI can use in a project, even if they don't name the tool. macOS only.
---

# VaultDoor

Credentials on this Mac live in an encrypted vault. You can use them, but no command will show them to you. That is deliberate, so your work and the user's secrets stay separate.

## Set it up if needed

Check whether it is installed:

```bash
command -v vaultdoor || ls ~/.local/bin/vaultdoor
```

If it is found, skip to **Start here**. Otherwise, set it up for the user:

1. **Check the Mac.** It needs macOS 13 or newer. On anything else, say so and stop.
2. **Check Apple's command line tools** with `xcode-select -p`. VaultDoor is built on the user's own Mac, so macOS trusts it. If the command fails, ask the user to run `xcode-select --install`, accept the dialog, and tell you when it finishes.
3. **Ask one question:** should switching an app off in the dashboard really block AI tool calls? That adds a hook to their AI settings, which are backed up first. Skip it if they only want passwords and servers.
4. **Run setup** from this skill's folder, the one holding this file. Allow it up to five minutes the first time, because it builds the app. It is safe to run again.
   ```bash
   bash scripts/setup.sh          # add --hook if they said yes
   ```
5. **Open the dashboard:** `vaultdoor dashboard` (or `~/.local/bin/vaultdoor dashboard` if it isn't on the PATH yet).
6. **Tell the user what happens next:**
   - If macOS asks about the Keychain, enter their Mac password and choose **Always Allow**.
   - In the window, add a project, then add its servers and keys. Passwords are typed into a secure macOS box there, never into the chat.
   - If a project has a `.deploy` file, **Settings > Actions > Move .deploy into the vault** moves everything across.

If setup reports an error, show it to the user. Don't work around it.

## Start here

Run this from inside the project before you need a credential:

```bash
vaultdoor status
```

It lists the servers, folders, keys and actions this project may use. Logins and key values are never shown. Add `--json` for structured output.

## Using credentials

**Run an approved action, such as a deploy:**

```bash
vaultdoor run deploy
vaultdoor run deploy --dry-run     # extra arguments go to the script
```

**Run a command on a server:**

```bash
vaultdoor ssh main -- php artisan migrate:status
vaultdoor ssh web -- ls -la
vaultdoor ssh main --no-cd -- df -h                  # start in the login folder instead
vaultdoor ssh main -- 'cat > storage/file.txt' < local-file.txt     # send a file
```

Each project maps servers to folders, and `vaultdoor status` shows them by name. Commands start in the mapped folder, so don't add `cd` to it or hardcode the path. The remote command is required, because interactive sessions are not supported.

**Call an API with a stored token:**

```bash
vaultdoor http "API token" GET https://api.example.com/v1/items
vaultdoor http "API token" POST https://api.example.com/v1/items -H 'Content-Type: application/json' -d '{"a":1}'
vaultdoor http "API token" POST https://api.example.com/v1/items --data-file body.json
```

The token only goes to the hosts the user allowed. The HTTP status prints on stderr. The exit code is 0 for 2xx and 1 otherwise.

## Rules

- **Do not look for credentials anywhere else.** Do not read `.deploy`, `.env`, key files or the Keychain to get a value, and do not ask the user to paste one into the chat. If you scan such a file for setting names, print names only, and never print its values.
- **Do not try to get around the vault.** That includes printing or encoding a key from a script, editing an approved script to expose one, reading another process's environment, and using `security` or a debugger. If you think you need to do any of this, stop and tell the user why.
- **Treat `<redacted:NAME>` in output as normal.** The vault replaced a secret there. Do not try to recover it.
- **The user makes every change, in the dashboard.** No command can add a server or key, map a server, turn a key on, or approve a script, because those changes need their Touch ID.

## When the vault refuses

Exit code 3 means the vault refused, and the message says why. A failing command returns its own exit code instead.

| Message says | What to do |
| --- | --- |
| Folder is not a project in the vault | Ask the user to add the project |
| Key is not turned on for this project | Ask the user to turn it on |
| Server is not mapped to this project | Ask the user to map it, and tell them which folder you need |
| Server is mapped more than once | Use one of the names the message lists |
| No server, key or action with that name | Check `vaultdoor status`, then ask the user to add it |
| No deploy action exists yet | Ask the user to click **Auto deploy** in the dashboard, which writes a script for them to review and approve |
| A file changed since it was approved | Tell the user which file changed and that it needs their review and approval. Do not change it back just to get past the check |
| Access denied in the Keychain | Tell the user. Only they should answer that macOS prompt |

To open the dashboard for the user, run `vaultdoor dashboard`, then say exactly what you need. For example: "Please map the Production server to this project with the folder `/var/www/app`, then tell me when it's done."

## Guiding the user in the dashboard

| They want to | Tell them |
| --- | --- |
| Add a server login | Click **+ Add server** on the main screen, fill in the address, then type the password in the secure box or choose a key file. VaultDoor logs in once to check it and shows the result |
| Find out why a server login fails | **Settings > Servers > Test login** says what went wrong, such as a wrong password, an unknown address or a closed port. Then **Replace login** or **Edit** to fix it |
| Add another password or token | Click **+ Add key** |
| Change a saved password | **Settings > Servers > Replace login**, or **Settings > Keys > Replace** |
| Point a project at a server | Click the server's hexagon, or **Settings > Servers > Map to**, and enter the folder |
| Get a deploy script | Click **Auto deploy**. The AI writes it with no access to the vault, and it can't run until they read and approve it |
| Move to a new Mac | **Settings > New Mac > Export**, then Import on the new Mac |

A saved value can never be shown again, even in the dashboard, so they should keep their own copy if they might need it elsewhere.

## Apps

Apps such as Gmail, Jira, Slack and WhatsApp have their own sign-ins and do not go through these commands. The user can switch an app off for a project in the dashboard, and `vaultdoor status` lists any that are off. If a tool call is blocked for that reason, ask the user rather than reaching the app another way.
