// T26 · how long a Claude reply may take, as the page states it, and the one warning the Thinking control carries.
//
// The host decides the budget (`reply_budget` in cockpit/src/claude_connection.rs) and stops a reply that outlasts
// it. The page only says it, before the reply starts, so a person knows how long "waiting" can honestly be. This is
// the page's copy, and `tools/reply-budget-test.mjs` holds it equal to the host's by reading the Rust source: a
// second copy of a number that nobody checks is how a page comes to promise ten minutes the host never gives.
//
// The values and their measurements are in superlane/t26/TASK.md (C3): one file of up to 64 KiB at `high` needs
// about 1,092 s at the slowest measured rate, and no level gets less than 1,800 s.
export const REPLY_BUDGET_S = Object.freeze({'': 1800, low: 1800, medium: 1800, high: 1800, xhigh: 2700, max: 3600});

/** Seconds the host allows a Claude reply at this thinking level ('' or null = the provider's default). */
export const replyBudget = effort => REPLY_BUDGET_S[effort ?? ''] ?? REPLY_BUDGET_S[''];

/** The line shown while a reply is awaited. Only the Claude connection's budget is set here. */
export function waitingText(provider, effort) {
  if (provider === 'codex') return 'Waiting for Codex… Large file replies can take up to five minutes.';
  if (provider === 'claude') return `Waiting for claude… Replies can take up to ${Math.round(replyBudget(effort) / 60)} minutes.`;
  return `Waiting for ${provider}… Replies can take up to two minutes.`;
}

/* S1, measured 2026-10-01 (superlane/silow/RUN.md): at `max` the first response spent all 128,000 output tokens on
   thinking (`stop_reason: max_tokens`) and wrote nothing, and the resumed one was still thinking when the budget ran
   out. The level stays the person's to choose; the page says what it measured and sends what was chosen. */
export const MAX_EFFORT_WARNING = 'Max can spend the whole output allowance (128,000 tokens) on thinking and reply with nothing: measured 2026-10-01 (S1). The level is sent as chosen.';

/** The note a thinking-level control shows for `level`, or null. */
export const effortWarning = level => (level === 'max' ? MAX_EFFORT_WARNING : null);
