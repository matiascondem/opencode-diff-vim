import type { TuiPlugin, TuiPluginApi, TuiPluginModule } from "@opencode-ai/plugin/tui"
import { runReview } from "../plugin/index.ts"

const command = "diff-vim.open"

function errorMessage(error: unknown) {
  if (error instanceof Error) return error.message
  return String(error)
}

function latestUserSelection(api: TuiPluginApi, sessionID: string) {
  const message = api.state.session.messages(sessionID).findLast((item) => item.role === "user")
  if (!message || message.role !== "user") return {}
  return {
    agent: message.agent,
    model: {
      providerID: message.model.providerID,
      modelID: message.model.modelID,
    },
    variant: message.model.variant,
  }
}

type ReviewRunner = typeof runReview

export function createTui(review: ReviewRunner = runReview): TuiPlugin {
  return async (api) => {
    let running = false

    async function open() {
      const route = api.route.current
      const sessionID =
        "params" in route && typeof route.params?.sessionID === "string" ? route.params.sessionID : undefined
      if (route.name !== "session" || !sessionID) {
        api.ui.toast({ variant: "warning", message: "Open a session before starting a diff review." })
        return
      }
      if (running) {
        api.ui.toast({ variant: "info", message: "A diff review is already open." })
        return
      }

      running = true
      api.ui.toast({ variant: "info", message: "Opening diff review...", duration: 1500 })

      try {
        const outcome = await review({
          worktree: api.state.path.worktree,
          directory: api.state.path.directory,
          sessionID,
          signal: api.lifecycle.signal,
        })

        if (outcome.status === "cancelled") {
          api.ui.toast({ variant: "info", message: "Diff review closed without feedback." })
          return
        }
        if (outcome.status === "notice") {
          api.ui.toast({ variant: "info", message: outcome.message })
          return
        }
        if (outcome.status === "error") {
          api.ui.toast({ variant: "error", title: "Diff review failed", message: outcome.message })
          return
        }

        await api.client.session.promptAsync(
          {
            sessionID,
            directory: api.state.path.directory,
            ...latestUserSelection(api, sessionID),
            parts: [{ type: "text", text: outcome.prompt }],
          },
          { throwOnError: true },
        )
      } catch (error) {
        api.ui.toast({ variant: "error", title: "Diff review failed", message: errorMessage(error) })
      } finally {
        running = false
      }
    }

    api.keymap.registerLayer({
      commands: [
        {
          name: command,
          title: "Open diff review in Neovim",
          desc: "Review working-tree changes and send inline feedback to the current agent",
          category: "VCS",
          namespace: "palette",
          slashName: "diff-vim",
          enabled: () => !running,
          run() {
            void open()
          },
        },
      ],
    })
  }
}

const tui = createTui()

const plugin: TuiPluginModule & { id: string } = {
  id: "diff-vim",
  tui,
}

export default plugin
