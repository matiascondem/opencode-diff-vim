import assert from "node:assert/strict"
import { describe, test } from "node:test"
import type { TuiPluginApi } from "@opencode-ai/plugin/tui"
import { createTui } from "../tui/index.ts"

function harness(route: TuiPluginApi["route"]["current"] = { name: "session", params: { sessionID: "session-1" } }) {
  const prompts: unknown[][] = []
  const toasts: unknown[] = []
  let run = () => {}

  const api = {
    route: { current: route },
    state: {
      path: { worktree: "/repo", directory: "/repo/package" },
      session: {
        messages: () => [
          {
            role: "user",
            agent: "build",
            model: { providerID: "openai", modelID: "gpt-test", variant: "fast" },
          },
        ],
      },
    },
    lifecycle: { signal: new AbortController().signal },
    ui: { toast: (input: unknown) => toasts.push(input) },
    client: {
      session: {
        promptAsync: async (...input: unknown[]) => {
          prompts.push(input)
          return { data: undefined }
        },
      },
    },
    keymap: {
      registerLayer(input: { commands: Array<{ run: () => void }> }) {
        run = input.commands[0]!.run
        return () => {}
      },
    },
  } as unknown as TuiPluginApi

  return { api, prompts, run: () => run(), toasts }
}

async function activate(api: TuiPluginApi, review: Parameters<typeof createTui>[0]) {
  await createTui(review)(api, undefined, {} as never)
}

describe("diff-vim TUI command", () => {
  test("submits review feedback with the latest session selection", async () => {
    const testkit = harness()
    await activate(testkit.api, async () => ({ status: "submitted", prompt: "review feedback" }))

    testkit.run()
    await new Promise((resolve) => setTimeout(resolve, 0))

    assert.equal(testkit.prompts.length, 1)
    assert.deepEqual(testkit.prompts[0]?.[0], {
      sessionID: "session-1",
      directory: "/repo/package",
      agent: "build",
      model: { providerID: "openai", modelID: "gpt-test" },
      variant: "fast",
      parts: [{ type: "text", text: "review feedback" }],
    })
  })

  test("does not prompt the agent when the review is cancelled", async () => {
    const testkit = harness()
    await activate(testkit.api, async () => ({ status: "cancelled" }))

    testkit.run()
    await new Promise((resolve) => setTimeout(resolve, 0))

    assert.equal(testkit.prompts.length, 0)
  })

  test("requires an active session", async () => {
    const testkit = harness({ name: "home" })
    let called = false
    await activate(testkit.api, async () => {
      called = true
      return { status: "cancelled" }
    })

    testkit.run()
    await new Promise((resolve) => setTimeout(resolve, 0))

    assert.equal(called, false)
    assert.deepEqual(testkit.toasts.at(-1), {
      variant: "warning",
      message: "Open a session before starting a diff review.",
    })
  })
})
