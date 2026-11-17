# mail-mcp — Apple Mail MCP server

Pure Swift MCP server for Apple Mail on macOS: one binary, no dependencies, no config.
Modelled on [AlexChambers/calendar-mcp](https://github.com/AlexChambers/calendar-mcp).

- **Fast reads.** Listing and search go to Mail's own SQLite index (`~/Library/Mail/V*/MailData/Envelope Index`, opened read-only). They take milliseconds across every account and folder.
- **Native writes.** Reading bodies, composing, replying, moving and saving attachments go through Mail.app via Apple Events. It uses the accounts already set up in Mail, so no IMAP passwords are stored on disk.
- **Fallback.** If the index can't be read (no Full Disk Access) or a query fails, it falls back to the AppleScript lookup automatically. Pass `useIndex: false` to force the fallback.

## Tools
| Tool | What it does |
|---|---|
| `mail_list_accounts` | Accounts, addresses, and which search mode is active |
| `mail_list_mailboxes` | Folders with message/unread counts |
| `mail_list_messages` | Newest messages in a mailbox (optionally unread only) |
| `mail_search` | All accounts and folders: words, from, to, subject, since/until, unread, flagged, attachments. Gmail label copies are de-duplicated |
| `mail_get_message` | Headers, attachment names, plain-text body |
| `mail_save_attachments` | Save attachments of one or many messages (default `~/Downloads/Mail Attachments`; never overwrites) |
| `mail_compose` | New email. Opens a draft for review by default; `send=true` sends |
| `mail_reply` | Reply / reply-all. Draft by default; `send=true` sends |
| `mail_update_messages` | Bulk mark read/flagged, archive, move, or move to Trash |

Messages are addressed by `messageId` (returned by list/search). With the index available, that id is all a tool needs.

## Build & install
```bash
swift build -c release
claude mcp add mail-mcp -s user "$PWD/.build/release/apple-mail-mcp"
```
For Claude Desktop, add `{"mail-mcp": {"command": "<path>/.build/release/apple-mail-mcp"}}` under `mcpServers`.

## Permissions
- **Automation → Mail** (prompted on first use) is required.
- **Full Disk Access** for the host app (Claude, or your terminal) is optional. It enables the fast index.
