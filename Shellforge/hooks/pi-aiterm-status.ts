// AiTerm PI extension schema: 5
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

// The port is AiTermPaths.hookPort, which PiDriver writes in place of the placeholder.
const endpoint = "http://127.0.0.1:__AITERM_HOOK_PORT__/hook/pi";

// PI may wait on what a handler returns, and reporting must never hold PI up: a daemon that accepts
// the connection and stalls would cost every turn the request's whole timeout. Handlers hand back
// nothing, except under the driver test, which has to see the acknowledgement before PI exits.
const settle = (posted: Promise<void>) => process.env.AITERM_INTEGRATION_TEST ? posted : undefined;

type Usage = { input?: number; output?: number; cacheRead?: number; cacheWrite?: number };
type Tally = { input: number; cached: number; output: number };
type Entry = { type?: string; usage?: Usage; message?: { role?: string; usage?: Usage } };

// What this PI process's subagents have spent, by session. pi-subagents runs every child in this
// process and loads this extension into each, so a child records its own tally here and the
// session the user drives -- the only one that reports -- adds them all to its own. On globalThis
// rather than in this module, which each activation may load afresh.
type Ledger = { children: Map<string, Tally>; changed?: () => void };
const LEDGER = Symbol.for("aiterm.pi.subagent-tallies");
const ledger = ((globalThis as Record<symbol, unknown>)[LEDGER] ??= { children: new Map() }) as Ledger;

// PI's `usage.input` leaves the cache out; the tally counts it in.
function add(tally: Tally, usage: Usage | undefined) {
	if (!usage) return;
	const cached = (usage.cacheRead ?? 0) + (usage.cacheWrite ?? 0);
	tally.input += (usage.input ?? 0) + cached;
	tally.cached += cached;
	tally.output += usage.output ?? 0;
}

// The session's own spend, as PI's getSessionStats sums it, but without a tool result's usage:
// that is where pi-subagents' `reportUsage` hangs a child's spend, which the ledger already counts.
function ownTally(ctx: ExtensionContext): Tally {
	const tally = { input: 0, cached: 0, output: 0 };
	for (const entry of ctx.sessionManager.getEntries() as unknown as Entry[]) {
		if (entry.type === "usage" || entry.type === "compaction" || entry.type === "branch_summary") add(tally, entry.usage);
		else if (entry.type === "message" && entry.message?.role === "assistant") add(tally, entry.message.usage);
	}
	return tally;
}

function sessionTally(ctx: ExtensionContext): Tally {
	const tally = ownTally(ctx);
	for (const child of ledger.children.values()) {
		tally.input += child.input;
		tally.cached += child.cached;
		tally.output += child.output;
	}
	return tally;
}

// A subagent records what it has spent for the session the user drives, and tells it.
function record(ctx: ExtensionContext) {
	try {
		if (ctx.hasUI) return;
		ledger.children.set(ctx.sessionManager.getSessionId(), ownTally(ctx));
		ledger.changed?.();
	} catch {
		// A ctx PI has invalidated: the child's last record stands.
	}
}

async function report(event: string, ctx: ExtensionContext, overrides: Record<string, unknown> = {}) {
	try {
		// pi-subagents loads every extension into each child session, in this process and so with
		// this tab's ITERM_SESSION_ID. A child has no UI; only the session the user drives reports.
		if (!ctx.hasUI) return;
		const usage = ctx.getContextUsage();
		const testId = process.env.AITERM_INTEGRATION_TEST;
		const body = {
			hook_event_name: event,
			session_id: ctx.sessionManager.getSessionId(),
			cwd: ctx.cwd,
			model: ctx.model ? `${ctx.model.provider}/${ctx.model.id}` : null,
			reasoning: ctx.thinkingLevel ?? null,
			context_percent: usage?.percent ?? null,
			tokens: sessionTally(ctx),
			...(testId ? { _aiterm_test_id: testId } : {}),
			...overrides,
		};
		const response = await fetch(endpoint, {
			method: "POST",
			headers: {
				"Content-Type": "application/json",
				"X-AiTerm-Hook": "1",
				...(process.env.ITERM_SESSION_ID ? { "X-AiTerm-iTerm-Session": process.env.ITERM_SESSION_ID } : {}),
			},
			body: JSON.stringify(body),
			signal: AbortSignal.timeout(1500),
		});
		if (testId) {
			const acknowledgement = await response.json() as { ok?: boolean; testId?: string };
			if (acknowledgement.ok && acknowledgement.testId === testId) {
				process.stderr.write(`AITERM_INTEGRATION_TEST_OK=${testId}\n`);
			}
		}
	} catch {
		// Status reporting must never interrupt PI — nor must a ctx gone stale.
	}
}

export default function (pi: ExtensionAPI) {
	// Background subagents outlive the turn that started them. pi-subagents announces them on the
	// shared bus, whose handlers get no ctx: report them against the last session that started.
	// Kept past `session_shutdown`, so a child ending then is still reported rather than left
	// running in the sidebar; a ctx PI has invalidated throws, and `report` drops the post.
	let session: ExtensionContext | undefined;
	const relay = (event: string) => (data: unknown) => {
		const id = (data as { id?: unknown } | null)?.id;
		if (session && typeof id === "string" && id) void report(event, session, { agent_id: id });
	};
	pi.events.on("subagents:started", relay("subagent_start"));
	pi.events.on("subagents:completed", relay("subagent_stop"));
	pi.events.on("subagents:failed", relay("subagent_stop"));

	// The reason tells the daemon whether a new conversation began (it forgets the old one's
	// subagents) or the extensions merely reloaded.
	pi.on("session_start", (event, ctx) => {
		session = ctx;
		if (ctx.hasUI) {
			// A new conversation's subagents start from nothing; a reload keeps the running ones.
			if (event.reason !== "reload") ledger.children.clear();
			ledger.changed = () => { if (session) void report("tokens", session); };
		}
		return settle(report("session_start", ctx, { reason: event.reason }));
	});
	pi.on("agent_start", (_event, ctx) => settle(report("agent_start", ctx)));
	pi.on("agent_settled", (_event, ctx) => { record(ctx); return settle(report("agent_settled", ctx)); });
	pi.on("turn_end", (_event, ctx) => { record(ctx); return settle(report("turn_end", ctx)); });
	pi.on("ui_prompt_start", (_event, ctx) => settle(report("ui_prompt_start", ctx)));
	pi.on("ui_prompt_end", (_event, ctx) => settle(report("ui_prompt_end", ctx)));
	pi.on("model_select", (event, ctx) => settle(report("model_select", ctx, {
		model: `${event.model.provider}/${event.model.id}`,
	})));
	pi.on("thinking_level_select", (event, ctx) => settle(report("thinking_level_select", ctx, {
		reasoning: event.level,
	})));
}
