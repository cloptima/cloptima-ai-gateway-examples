# Running these examples safely

Every option below runs the exact same scripts. None of them require you (or your agent) to install anything permanent on your own machine, and none of them need any credential beyond the `ai:admin` key you were given - pick whichever fits how you or your agent already work.

| Option | Setup | Human action needed | Can an agent do the whole thing alone? |
| --- | --- | --- | --- |
| [Your agent's own sandbox](#option-1-your-agents-own-sandbox) | None | None | Yes, if your agent already has code execution (Claude Code, ChatGPT Code Interpreter, and similar all qualify) |
| [Local Docker container](#option-2-docker) | Docker installed | None | Yes, if your agent has local shell/tool access |
| [GitHub Codespaces](#option-3-github-codespaces) | A GitHub account (free tier is enough) | One-time: log into GitHub, click a link | Yes, after that one click, if your agent has terminal access inside the Codespace |
| [Console only, no code](#option-4-console-only) | None | Log into the web console | No - this one's for a human, not an agent |

Nothing here touches your host machine's files, network, or credentials beyond what's explicitly described. No option requires giving anything write access outside its own container/sandbox.

## Option 1: your agent's own sandbox

If your agent already runs code in its own isolated environment - Claude Code, ChatGPT's Code Interpreter, Cursor's background agents, and similar all do this by default - there's nothing to set up. Just point it at this repo and your `ai:admin` key; it can clone, install dependencies, and run scripts entirely inside its own already-sandboxed runtime, with nothing touching your actual machine.

## Option 2: Docker

Needs Docker installed, nothing else - no GitHub account, no login, no browser step of any kind.

Build it yourself from the `Dockerfile` in this repo if you want to read exactly what it does first:

```bash
git clone https://github.com/cloptima/cloptima-ai-gateway-examples.git
cd cloptima-ai-gateway-examples
docker build -t cloptima-examples .
docker run -it --rm -e CLOPTIMA_AI_ADMIN_KEY=clop_pat_... cloptima-examples
```

Or pull the prebuilt image - same Dockerfile, built automatically from this repo on every change, no local build wait:

```bash
docker run -it --rm -e CLOPTIMA_AI_ADMIN_KEY=clop_pat_... ghcr.io/cloptima/cloptima-ai-gateway-examples:latest
```

That drops you into a shell inside the container with Node, Python, and `curl`/`jq` all preinstalled. From there:

```bash
cd node && npm run quickstart-openai
# or
cd python && python -m examples.quickstart_openai
# or
cd shell && ./quickstart-openai.sh
```

Any agent with local shell/tool-execution access can run these same commands itself, with no human step at all.

## Option 3: GitHub Codespaces

Needs a GitHub account - the free tier includes a monthly quota of Codespaces usage large enough that a short evaluation session costs nothing. Click below, or open `https://codespaces.new/cloptima/cloptima-ai-gateway-examples` directly:

[![Open in GitHub Codespaces](https://github.com/codespaces/badge.svg)](https://codespaces.new/cloptima/cloptima-ai-gateway-examples)

This is the one place a human has to do something an agent can't: opening a *new* Codespace requires an authenticated GitHub session (the web UI, or `gh auth login`'s device-code flow), which needs a real browser action at least once. After that one click, you land in a ready-to-go terminal (same image as the Docker option) - export your key and run any example, or hand the terminal to a coding agent that can operate inside it.

```bash
export CLOPTIMA_AI_ADMIN_KEY=clop_pat_...
cd node && npm run quickstart-openai
```

## Option 4: console only

No code at all. Log into the console with the login you were given and follow [`docs/CONSOLE_GUIDE.md`](CONSOLE_GUIDE.md) for a five-minute guided walk. This is the only option here for someone without a coding agent and without interest in running scripts themselves.
