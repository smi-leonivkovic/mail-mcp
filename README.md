# Apple Mail MCP

Pure Swift MCP server for Apple Mail on macOS — one binary, no dependencies, no config.
Modelled on [AlexChambers/calendar-mcp](https://github.com/AlexChambers/calendar-mcp).
Talks to Mail.app via Apple Events, so it uses the accounts already set up in Mail
(no IMAP passwords on disk).

## Tools
| Tool | What it does |
|---|---|
| `mail_list_accounts` | Accounts + addresses |
| `mail_list_mailboxes` | Folders with unread counts |
| `mail_list_messages` | Newest messages in a mailbox (optionally unread only) |
| `mail_search` | By query/from/subject/since/unread/flagged (body search optional, slow) |
| `mail_get_message` | Headers, attachment names, plain-text body |
| `mail_compose` | New email — opens a draft for review by default, `send=true` sends |
| `mail_reply` | Reply / reply-all — draft by default, `send=true` sends |
| `mail_update_message` | Mark read/flagged, move to another mailbox |

Messages are addressed by `messageId` + `account` + `mailbox` (all returned by list/search).

## Build & install
```bash
swift build -c release
claude mcp add apple-mail -s user "$PWD/.build/release/apple-mail-mcp"
```
Claude Desktop: add `{"apple-mail": {"command": "<path>/.build/release/apple-mail-mcp"}}` under `mcpServers`.

First use triggers macOS's "… wants to control Mail" prompt — allow it
(System Settings → Privacy & Security → Automation).
