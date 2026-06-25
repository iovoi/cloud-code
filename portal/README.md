# Claude Chat Portal

A minimal web chat UI in front of the `claude` (Claude Code) CLI. Left sidebar
shows conversation history; the center shows the current conversation. Sends
your input to Claude Code and streams the reply.

- **Zero npm dependencies** — Node built-ins only.
- Talks to `claude -p --output-format stream-json --verbose [--resume <id>]`.
- Sessions are stored under `~/.claude-portal/sessions.json`; each maps to a
  Claude `session_id` so Claude keeps its own context too.
- No API key on disk — `run.sh` fetches `ANTHROPIC_API_KEY` from GCP Secret
  Manager at startup (same pattern as `start.sh`).

## Run (on the VM, as developer)

```bash
# foreground (logs to the terminal)
/home/developer/portal/run.sh

# or as a service
sudo systemctl enable --now claude-portal
sudo journalctl -u claude-portal -f
```

Listens on `127.0.0.1:3000`. Expose it on the tailnet:

```bash
sudo tailscale serve --bg --http=8080 http://localhost:3000
# then open: http://claude-code.<tailnet>.ts.net:8080
```

## Layout

```
portal/
  server.js              # http server + SSE + claude subprocess + session store
  index.html             # the UI (sidebar + chat), inline CSS/JS
  run.sh                 # fetch key, then exec node server.js
  claude-portal.service  # systemd unit
```

Claude runs with `cwd=/home/developer/workspace`, so file operations it performs
in a conversation act on the developer workspace.
