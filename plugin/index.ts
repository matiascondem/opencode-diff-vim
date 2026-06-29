import { tool } from "@opencode-ai/plugin"
import { mkdtemp, readdir, rm } from "node:fs/promises"
import { existsSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { tmpdir } from "node:os"
import path from "node:path"

// ---------------------------------------------------------------------------
// opencode-diff-vim
//
// A fork of the data/transport layer of `opencode-diffs` that swaps the
// browser + @pierre/diffs UI for a Neovim review app launched in a terminal.
// The git collection and blocking handshake are kept; only the front-end and
// the comment schema (message-only) change.
// ---------------------------------------------------------------------------

const command = "diff-vim"
const name = "diff_vim"
const sides = ["additions", "deletions"] as const
const terminals = ["auto", "kitty", "wezterm"] as const

type Side = (typeof sides)[number]
type Terminal = (typeof terminals)[number]

type Parsed = { files?: string[]; base?: string; terminal?: Terminal; error?: string }

function usage() {
  return "Usage: /diff-vim [--base origin/dev] [--files path/to/a.ts,path/to/b.ts] [--terminal auto|kitty|wezterm]"
}

function isSide(input: unknown): input is Side {
  return typeof input === "string" && (sides as readonly string[]).includes(input)
}

function isTerminal(input: unknown): input is Terminal {
  return typeof input === "string" && (terminals as readonly string[]).includes(input)
}

function parse(raw: string | undefined): Parsed {
  if (!raw?.trim()) return {}
  const tokens = raw.trim().split(/\s+/).filter(Boolean)
  let files: string[] | undefined
  let base: string | undefined
  let terminal: Terminal | undefined
  for (let index = 0; index < tokens.length; index++) {
    const token = tokens[index]
    if (!token) continue
    const next = tokens[index + 1]
    if (token === "--files" || token.startsWith("--files=")) {
      const value = token.startsWith("--files=") ? token.slice(8) : next
      if (!value || value.startsWith("--")) return { error: `--files expects a comma-separated list.\n${usage()}` }
      const parsed = value.split(",").map((item) => item.trim()).filter(Boolean)
      if (parsed.length === 0) return { error: `--files expects a comma-separated list.\n${usage()}` }
      files = parsed
      if (token === "--files") index++
      continue
    }
    if (token === "--base" || token.startsWith("--base=")) {
      const value = token.startsWith("--base=") ? token.slice(7) : next
      if (!value || value.startsWith("--")) return { error: `--base expects a branch, tag, or ref name.\n${usage()}` }
      base = value
      if (token === "--base") index++
      continue
    }
    if (token === "--terminal" || token.startsWith("--terminal=")) {
      const value = token.startsWith("--terminal=") ? token.slice(11) : next
      if (!value || value.startsWith("--")) return { error: `--terminal expects one of: ${terminals.join(", ")}\n${usage()}` }
      if (!isTerminal(value)) return { error: `Unsupported terminal: ${value}\n${usage()}` }
      terminal = value
      if (token === "--terminal") index++
      continue
    }
    return { error: `Unsupported argument: ${token}\n${usage()}` }
  }
  return { files, base, terminal }
}

// --- finding anchoring & reconciliation ------------------------------------

function normalize(start: number, end: number) {
  return start <= end ? { start, end } : { start: end, end: start }
}

function anchor(content: string, start: number, end: number) {
  const range = normalize(start, end)
  const lines = content.split("\n")
  const begin = Math.max(1, Math.min(range.start, lines.length || 1))
  const finish = Math.max(begin, Math.min(range.end, lines.length || begin))
  return {
    before: lines[begin - 2] ?? "",
    selected: lines.slice(begin - 1, finish).join("\n"),
    after: lines[finish] ?? "",
  }
}

type Finding = {
  id: string
  round: number
  file: string
  side: Side
  start_line: number
  end_line: number
  comment: string
  status: "open" | "resolved" | "closed_auto"
  close_reason?: string
  anchor: { before: string; selected: string; after: string }
  created_at: number
  updated_at: number
  closed_at?: number
}

type RenderedFile = {
  path: string
  status: string
  additions: number
  deletions: number
  before: string
  after: string
}

type IncomingFinding = {
  id?: string
  file?: unknown
  side?: unknown
  start_line?: unknown
  end_line?: unknown
  comment?: unknown
}

function sanitize(items: IncomingFinding[], round: number, files: Map<string, RenderedFile>): Finding[] {
  const now = Date.now()
  return items.flatMap((item, index) => {
    if (typeof item.file !== "string" || !item.file) return []
    if (typeof item.comment !== "string" || !item.comment.trim()) return []
    const side: Side = isSide(item.side) ? item.side : "additions"
    if (!Number.isFinite(item.start_line as number) || !Number.isFinite(item.end_line as number)) return []
    const file = files.get(item.file)
    if (!file) return []
    const start_line = Math.max(1, Math.floor(Math.min(item.start_line as number, item.end_line as number)))
    const end_line = Math.max(start_line, Math.floor(Math.max(item.start_line as number, item.end_line as number)))
    const next = anchor(side === "deletions" ? file.before : file.after, start_line, end_line)
    if (!next.selected.trim()) return []
    return [{
      id: item.id?.trim() || `finding_${round}_${index + 1}_${crypto.randomUUID().slice(0, 6)}`,
      round,
      file: item.file,
      side,
      start_line,
      end_line,
      comment: item.comment.trim(),
      status: "open" as const,
      anchor: next,
      created_at: now,
      updated_at: now,
    }]
  })
}

// --- output formatting ------------------------------------------------------

type Completed = {
  cancelled: boolean
  round: number
  notes: string
  findings: Finding[]
}

function approvalIntent(notes: string) {
  const normalized = notes.trim().toLowerCase()
  if (!normalized) return false
  return (
    normalized.includes("/pr") ||
    normalized.includes("looks good") ||
    normalized.includes("lgtm") ||
    normalized.includes("approved") ||
    normalized.includes("ship it")
  )
}

function format(result: Completed): string {
  if (result.cancelled) {
    return [
      "Diff review was closed before submission.",
      `You can relaunch with /${command}.`,
    ].join("\n")
  }
  const open = result.findings.filter((item) => item.status === "open")
  const rows = open.map((item) => `- ${item.file}:${item.start_line}-${item.end_line} — ${item.comment.replace(/\n/g, " ")}`)
  const findings = rows.length > 0 ? rows.join("\n") : "- No comments"
  const notes = result.notes ? result.notes : "(none)"
  const workflow = approvalIntent(result.notes)
    ? [
      "The reviewer note indicates approval to continue after handling inline comments.",
      "Address any clear inline comments directly; then continue the user's requested workflow, including opening a PR when requested, without asking for another confirmation.",
    ]
    : open.length > 0
      ? [
        "Treat clear inline comments as requested code changes and implement them directly.",
        "Only stop to ask for clarification when a comment is ambiguous, conflicts with another request, or would require a high-risk/product decision.",
      ]
      : [
        "No inline comments were submitted. Use the reviewer note as the next instruction if it is actionable; otherwise ask before editing.",
      ]
  return [
    `# Diff Review (vim) — Round ${result.round}`,
    "",
    `- Comments: ${open.length}`,
    "",
    "## Reviewer note",
    notes,
    "",
    "## Comments",
    findings,
    "",
    "## Workflow instruction",
    ...workflow,
  ].join("\n")
}

// --- git plumbing (reused from opencode-diffs) ------------------------------

function split(text: string) {
  return text.split("\n").map((item) => item.trim()).filter(Boolean)
}

function count(text: string) {
  if (!text) return 0
  const lines = text.split("\n")
  if (text.endsWith("\n")) return Math.max(0, lines.length - 1)
  return lines.length
}

function textOf(content: string) {
  if (content.includes("\0")) return ""
  return content
}

async function run(cwd: string, args: string[]) {
  const proc = Bun.spawn(args, { cwd, stdout: "pipe", stderr: "pipe" })
  const [stdout, stderr, code] = await Promise.all([
    Bun.readableStreamToText(proc.stdout).catch(() => ""),
    Bun.readableStreamToText(proc.stderr).catch(() => ""),
    proc.exited,
  ])
  return { ok: code === 0, stdout, stderr }
}

async function repo(cwd: string) {
  const result = await run(cwd, ["git", "rev-parse", "--show-toplevel"])
  if (!result.ok) return { path: "", error: result.stderr.trim() || result.stdout.trim() || "failed to resolve git root" }
  const root = result.stdout.trim()
  if (!root) return { path: "", error: "failed to resolve git root" }
  return { path: root, error: undefined as string | undefined }
}

async function inside(cwd: string) {
  const result = await run(cwd, ["git", "rev-parse", "--is-inside-work-tree"])
  return result.ok && result.stdout.trim() === "true"
}

async function head(cwd: string) {
  return (await run(cwd, ["git", "rev-parse", "--verify", "HEAD"])).ok
}

function scope(root: string, dir: string) {
  const rel = path.relative(root, dir)
  if (rel.startsWith("..")) return "."
  if (!rel || rel === ".") return "."
  return rel
}

function internal(file: string) {
  return file.startsWith(".opencode/reviews/") || file.includes("/.opencode/reviews/")
}

async function names(root: string, area: string, withHead: boolean) {
  const spec = ["--", area]
  const tracked = withHead
    ? await run(root, ["git", "diff", "--name-only", "--no-renames", "HEAD", ...spec])
    : await run(root, ["git", "ls-files", "--cached", ...spec])
  if (!tracked.ok) return { files: [] as string[], error: tracked.stderr.trim() || "failed to list tracked changes" }
  const untracked = await run(root, ["git", "ls-files", "--others", "--exclude-standard", ...spec])
  if (!untracked.ok) return { files: [] as string[], error: untracked.stderr.trim() || "failed to list untracked files" }
  return {
    files: Array.from(new Set([...split(tracked.stdout), ...split(untracked.stdout)])).filter((item) => !internal(item)),
    error: undefined as string | undefined,
  }
}

async function numstat(root: string, range: string[], area: string) {
  const result = new Map<string, { additions: number; deletions: number }>()
  const diff = await run(root, ["git", "diff", "--numstat", "--no-renames", ...range, "--", area])
  if (!diff.ok) return result
  for (const row of split(diff.stdout)) {
    const [adds, dels, ...rest] = row.split("\t")
    if (!adds || !dels || rest.length === 0) continue
    const file = rest.join("\t")
    const additions = Number(adds)
    const deletions = Number(dels)
    result.set(file, {
      additions: Number.isFinite(additions) ? additions : 0,
      deletions: Number.isFinite(deletions) ? deletions : 0,
    })
  }
  return result
}

async function showAt(root: string, rev: string, file: string) {
  const result = await run(root, ["git", "show", `${rev}:${file}`])
  if (!result.ok) return ""
  return textOf(result.stdout)
}

async function workingAfter(root: string, file: string) {
  const source = Bun.file(path.join(root, file))
  if (!(await source.exists())) return ""
  return source.text().then(textOf).catch(() => "")
}

async function merge(root: string, base: string) {
  const result = await run(root, ["git", "merge-base", base, "HEAD"])
  if (!result.ok) return { rev: "", error: result.stderr.trim() || `failed to resolve merge-base for ${base}` }
  const rev = result.stdout.trim()
  if (!rev) return { rev: "", error: `failed to resolve merge-base for ${base}` }
  return { rev, error: undefined as string | undefined }
}

async function collectWorking(root: string, dir: string) {
  const area = scope(root, dir)
  const withHead = await head(root)
  const listed = await names(root, area, withHead)
  if (listed.error) return { files: [] as RenderedFile[], error: `Failed to read git diff: ${listed.error}` }
  if (listed.files.length === 0) return { files: [] as RenderedFile[], error: undefined as string | undefined }
  const map = withHead ? await numstat(root, ["HEAD"], area) : new Map()
  const files = await Promise.all(listed.files.map(async (file): Promise<RenderedFile> => {
    const prev = withHead ? await showAt(root, "HEAD", file) : ""
    const next = await workingAfter(root, file)
    const stat = map.get(file)
    return {
      path: file,
      status: prev && !next ? "deleted" : !prev && next ? "added" : "modified",
      before: prev,
      after: next,
      additions: stat?.additions ?? (prev ? Math.max(0, count(next) - count(prev)) : count(next)),
      deletions: stat?.deletions ?? Math.max(0, count(prev) - count(next)),
    }
  }))
  return { files, error: undefined as string | undefined }
}

async function collectBase(root: string, dir: string, base: string) {
  const area = scope(root, dir)
  const merged = await merge(root, base)
  if (merged.error) return { files: [] as RenderedFile[], error: `Failed to resolve --base ${base}: ${merged.error}` }
  const listed = await run(root, ["git", "diff", "--name-only", "--no-renames", `${merged.rev}..HEAD`, "--", area])
  if (!listed.ok) return { files: [] as RenderedFile[], error: `Failed to read git diff for --base ${base}` }
  const fileNames = split(listed.stdout).filter((item) => !internal(item))
  if (fileNames.length === 0) return { files: [] as RenderedFile[], error: undefined as string | undefined }
  const map = await numstat(root, [`${merged.rev}..HEAD`], area)
  const files = await Promise.all(fileNames.map(async (file): Promise<RenderedFile> => {
    const prev = await showAt(root, merged.rev, file)
    const next = await showAt(root, "HEAD", file)
    const stat = map.get(file)
    return {
      path: file,
      status: prev && !next ? "deleted" : !prev && next ? "added" : "modified",
      before: prev,
      after: next,
      additions: stat?.additions ?? (prev ? Math.max(0, count(next) - count(prev)) : count(next)),
      deletions: stat?.deletions ?? Math.max(0, count(prev) - count(next)),
    }
  }))
  return { files, error: undefined as string | undefined }
}

async function collect(root: string, dir: string, base?: string) {
  if (!(await inside(root))) return { files: [] as RenderedFile[], error: "Current directory is not a git repository." }
  if (base) return collectBase(root, dir, base)
  return collectWorking(root, dir)
}

// --- terminal + neovim launch -----------------------------------------------

// Resolve the repo root that contains nvim/init.lua, working for both the
// local-dev shim (<repo>/plugin/index.ts) and a future npm install.
function findNvimInit(): string | undefined {
  let dir = path.dirname(fileURLToPath(import.meta.url))
  for (let i = 0; i < 6; i++) {
    const candidate = path.join(dir, "nvim", "init.lua")
    if (existsSync(candidate)) return candidate
    const parent = path.dirname(dir)
    if (parent === dir) break
    dir = parent
  }
  return undefined
}

async function kittySocket(): Promise<string | undefined> {
  const env = process.env.KITTY_LISTEN_ON
  if (env) return env
  try {
    const entries = await readdir("/tmp")
    const socks = entries.filter((e) => e.startsWith("kitty-"))
    if (socks.length === 0) return undefined
    // newest by name suffix is a fine heuristic; prefer any
    return `unix:/tmp/${socks[socks.length - 1]}`
  } catch {
    return undefined
  }
}

type LaunchOpts = {
  cwd: string
  init: string
  payloadFile: string
  submitUrl: string
  tabTitle: string
}

function shellQuote(value: string) {
  return `'${value.replace(/'/g, `'"'"'`)}'`
}

function reviewEnv(opts: LaunchOpts) {
  return {
    DIFF_VIM_PAYLOAD: opts.payloadFile,
    DIFF_VIM_SUBMIT_URL: opts.submitUrl,
    NVIM_APPNAME: "diff-vim",
  }
}

function envCommand(opts: LaunchOpts) {
  return Object.entries(reviewEnv(opts)).map(([key, value]) => `${key}=${shellQuote(value)}`).join(" ")
}

async function launchKitty(opts: LaunchOpts): Promise<{ ok: boolean; error?: string }> {
  const socket = await kittySocket()
  if (!socket) return { ok: false, error: "no kitty socket (KITTY_LISTEN_ON unset and no /tmp/kitty-*)" }
  const bin = Bun.which("kitty")
  if (!bin) return { ok: false, error: "kitty not found on PATH" }

  const args = [
    "@", "--to", socket,
    "launch",
    "--type=tab",
    "--location=after",
    "--tab-title", opts.tabTitle,
    "--cwd", opts.cwd,
    "--env", `DIFF_VIM_PAYLOAD=${opts.payloadFile}`,
    "--env", `DIFF_VIM_SUBMIT_URL=${opts.submitUrl}`,
    "--env", "NVIM_APPNAME=diff-vim",
    "nvim", "-u", opts.init,
  ]
  const proc = Bun.spawn([bin, ...args], { stdout: "pipe", stderr: "pipe" })
  const [stderr, code] = await Promise.all([
    Bun.readableStreamToText(proc.stderr).catch(() => ""),
    proc.exited,
  ])
  if (code !== 0) return { ok: false, error: stderr.trim() || `kitty launch exited ${code}` }
  return { ok: true }
}

async function launchWezTerm(opts: LaunchOpts): Promise<{ ok: boolean; error?: string }> {
  const bin = Bun.which("wezterm")
  if (!bin) return { ok: false, error: "wezterm not found on PATH" }

  const command = `${envCommand(opts)} nvim -u ${shellQuote(opts.init)}`
  const args = ["cli", "spawn"]
  if (!process.env.WEZTERM_PANE) args.push("--new-window")
  args.push("--cwd", opts.cwd, "--", "sh", "-lc", command)
  const proc = Bun.spawn([bin, ...args], { stdout: "pipe", stderr: "pipe" })
  const [stderr, code] = await Promise.all([
    Bun.readableStreamToText(proc.stderr).catch(() => ""),
    proc.exited,
  ])
  if (code !== 0) return { ok: false, error: stderr.trim() || `wezterm cli spawn exited ${code}` }
  return { ok: true }
}

async function launchReview(opts: LaunchOpts, terminal: Terminal = "auto"): Promise<{ ok: boolean; error?: string; terminal: Exclude<Terminal, "auto"> }> {
  if (terminal === "wezterm" || (terminal === "auto" && process.env.WEZTERM_PANE)) {
    const result = await launchWezTerm(opts)
    return { ...result, terminal: "wezterm" }
  }

  const result = await launchKitty(opts)
  return { ...result, terminal: "kitty" }
}

// --- plugin -----------------------------------------------------------------

const DiffVimPlugin = async (ctx: any) => {
  const init = findNvimInit()
  return {
    config: async (output: any) => {
      if (output.command?.[command]) return
      output.command = {
        ...output.command,
        [command]: {
          description: "Open a vim-native diff review in a terminal tab and collect inline comments",
          template: [
            `Call the ${name} tool exactly once.`,
            "Pass raw command arguments from $ARGUMENTS into the tool arg `raw`.",
            "After the tool returns, follow its workflow instruction.",
            "Treat clear inline comments as requested code changes and implement them directly.",
            "Only stop to ask for clarification when feedback is ambiguous, conflicts with another request, or would require a high-risk/product decision.",
            "If the reviewer note indicates approval, such as `looks good`, `LGTM`, `approved`, `ship it`, or `/pr`, address inline comments first and then continue the user's requested workflow, including opening a PR when requested, without asking for another confirmation.",
          ].join("\n"),
        },
      }
    },
    tool: {
      [name]: tool({
        description:
          "Open a Neovim-based diff review in a new terminal tab for the current session and return structured comments for proposal discussion.",
        args: { raw: tool.schema.string().optional().describe("Raw command arguments from /diff-vim") },
        async execute(args: { raw?: string }, context: any) {
          if (!init) return "Failed to locate nvim/init.lua next to the plugin. Reinstall opencode-diff-vim."
          const parsed = parse(args.raw)
          if (parsed.error) return parsed.error

          const roots = [context.worktree, context.directory].filter(Boolean) as string[]
          const root = (await Promise.all(roots.map((item) => repo(item)))).find((item) => !item.error)
          if (!root?.path) {
            return ["Failed to resolve git repository root for this session.", `worktree=${context.worktree}`, `directory=${context.directory}`].join("\n")
          }
          const scope_root = context.worktree || context.directory
          const source = await collect(root.path, scope_root, parsed.base)
          if (source.error) return source.error

          const all = source.files
          const scoped = parsed.files?.length
            ? all.filter((item) => parsed.files?.includes(item.path) || parsed.files?.some((value) => item.path.endsWith(value)))
            : all
          if (scoped.length === 0) {
            const available = all.map((item) => `- ${item.path}`).join("\n")
            return parsed.files?.length
              ? ["No files matched --files filter.", "", usage(), "", "Available files:", available || "- none"].join("\n")
              : parsed.base
                ? `No changes found for --base ${parsed.base}.`
                : "No git working-tree changes found yet."
          }

          const files = scoped
          const temp_root = await mkdtemp(path.join(tmpdir(), "opencode-diff-vim-"))
          const payload_file = path.join(temp_root, "vim-payload.json")

          const id = `review_${Date.now().toString(36)}_${crypto.randomUUID().slice(0, 6)}`
          const token = crypto.randomUUID().replaceAll("-", "")
          const data = {
            id,
            session_id: context.sessionID,
            repo_root: root.path,
            scope_root,
            round: 1,
            files,
            existing_findings: [],
            draft: { notes: "", new_findings: [] },
            filter: parsed.files,
            base: parsed.base,
          }
          await Bun.write(payload_file, JSON.stringify(data, null, 2))

          const fileMap = new Map(files.map((item) => [item.path, item]))
          let done = false
          let finish: (value: Completed) => void = () => {}
          const wait = new Promise<Completed>((resolve) => {
            finish = resolve
          })
          const resolveOnce = (result: Completed) => {
            if (done) return
            done = true
            finish(result)
          }

          const server = Bun.serve({
            port: 0,
            hostname: "127.0.0.1",
            fetch: async (request) => {
              const url = new URL(request.url)
              const pathname = url.pathname
              if (pathname === "/health") return new Response("ok")
              if (url.searchParams.get("token") !== token) return new Response("unauthorized", { status: 401 })

              if (request.method === "GET" && pathname === `/api/review/${id}`) {
                return new Response(JSON.stringify(data), { headers: { "content-type": "application/json" } })
              }

              if (request.method === "POST" && pathname === `/api/review/${id}/submit`) {
                const input = (await request.json().catch(() => ({}))) as any
                const notes = typeof input.notes === "string" ? input.notes.trim() : ""
                const fresh = Array.isArray(input.new_findings) ? input.new_findings : []
                const round = 1
                const created = sanitize(fresh, round, fileMap)
                queueMicrotask(() => resolveOnce({ cancelled: false, round, notes, findings: created }))
                return new Response(JSON.stringify({ ok: true, round }), { headers: { "content-type": "application/json" } })
              }

              if (request.method === "POST" && pathname === `/api/review/${id}/cancel`) {
                queueMicrotask(() => resolveOnce({ cancelled: true, round: 1, notes: "", findings: [] }))
                return new Response(JSON.stringify({ ok: true }), { headers: { "content-type": "application/json" } })
              }

              return new Response("not found", { status: 404 })
            },
          })

          const submitUrl = `http://127.0.0.1:${server.port}/api/review/${id}/submit?token=${token}`
          const launched = await launchReview({
            cwd: root.path,
            init,
            payloadFile: payload_file,
            submitUrl,
            tabTitle: "diff-vim · review",
          }, parsed.terminal ?? "auto")
          if (!launched.ok) {
            server.stop(true)
            await rm(temp_root, { recursive: true, force: true }).catch(() => {})
            return [
              `Failed to open the Neovim review tab in ${launched.terminal}.`,
              `Reason: ${launched.error}`,
              "",
              "Checklist:",
              "- For Kitty, enable `allow_remote_control yes` and configure a `listen_on` socket.",
              "- For WezTerm, run opencode inside WezTerm so `WEZTERM_PANE` is available, or pass `--terminal wezterm`.",
              "- `nvim` and the selected terminal CLI must be on PATH.",
            ].join("\n")
          }

          context.metadata?.({
            title: "Diff review (vim)",
            metadata: {
              files: files.length,
              scope: parsed.files?.length ? parsed.files.join(",") : "all",
              base: parsed.base || "working_tree",
              repo: root.path,
            },
          })
          await ctx.client.app.log({
            body: {
              service: "diff-vim",
              level: "info",
              message: `vim review launched for ${context.sessionID}`,
              extra: { files: files.length, base: parsed.base || "working_tree", repo: root.path },
            },
            query: { directory: context.directory },
          }).catch(() => {})

          context.abort?.addEventListener("abort", () => {
            resolveOnce({ cancelled: true, round: 1, notes: "", findings: [] })
          }, { once: true })

          const result = await wait
          await new Promise((resolve) => setTimeout(resolve, 150))
          server.stop(true)
          await rm(temp_root, { recursive: true, force: true }).catch(() => {})
          return format(result)
        },
      }),
    },
  }
}

export { DiffVimPlugin, DiffVimPlugin as default }
