import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { createConnection, type Socket } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import type {
	ExtensionAPI,
	ExtensionCommandContext,
	ExtensionContext,
} from "@earendil-works/pi-coding-agent";

const STATUS_KEY = "pi-listen";
const WIDGET_KEY = "pi-listen";
const DEFAULT_CONNECT_TIMEOUT_MS = 5000;
const DEFAULT_RETRY_DELAY_MS = 150;
const RECORDING_INDICATOR = "REC";
const STARTUP_HEADER = [
	"pi-listen",
	"",
	"Commands:",
	"  /listen starts or toggles listening",
	"  /listen --demo simulates transcript frames",
	"  /listen-stop stops listening and clears the overlay",
	"  /listen-status shows the current runtime state",
	"",
	"Shortcuts:",
	"  Option+L / Alt+L toggles listening",
].join("\n");

type BridgePacketStatus = "streaming" | "final" | "error";

interface BridgePacket {
	status: BridgePacketStatus;
	text: string;
}

interface ListenOptions {
	demo: boolean;
	model?: string;
	whisperCommand?: string;
}

class JsonLineBuffer {
	private buffer = "";

	push(chunk: Buffer, onPacket: (packet: BridgePacket) => void) {
		this.buffer += chunk.toString("utf8");

		while (true) {
			const newlineIndex = this.buffer.indexOf("\n");
			if (newlineIndex === -1) {
				return;
			}

			const line = this.buffer.slice(0, newlineIndex).trim();
			this.buffer = this.buffer.slice(newlineIndex + 1);
			if (!line) {
				continue;
			}

			try {
				onPacket(JSON.parse(line) as BridgePacket);
			} catch (error) {
				console.error("pi-listen: Failed to parse bridge packet", error);
			}
		}
	}

	reset() {
		this.buffer = "";
	}
}

class PiListenRuntime {
	private readonly bridgePath = fileURLToPath(new URL("../bin/pi-listen-bridge.pl", import.meta.url));
	private readonly lineBuffer = new JsonLineBuffer();
	private ctx: ExtensionContext | ExtensionCommandContext | undefined;
	private bridgeProcess: ChildProcessWithoutNullStreams | null = null;
	private socket: Socket | null = null;
	private socketPath: string | null = null;
	private state: "idle" | "starting" | "listening" | "error" = "idle";
	private previewText = "";
	private lastError: string | null = null;

	setContext(ctx: ExtensionContext | ExtensionCommandContext) {
		this.ctx = ctx;
		this.render();
	}

	isActive() {
		return this.state === "starting" || this.state === "listening";
	}

	async start(ctx: ExtensionCommandContext, options: ListenOptions) {
		this.setContext(ctx);
		if (this.isActive()) {
			ctx.ui.notify("pi-listen is already running.", "info");
			return;
		}

		await this.stop(false);
		this.state = "starting";
		this.previewText = "";
		this.lastError = null;
		this.socketPath = join(tmpdir(), `pi-listen-${process.pid}.sock`);
		this.render();

		const args = ["--socket", this.socketPath];
		if (options.demo) {
			args.push("--demo");
		}
		if (options.model) {
			args.push("--model", options.model);
		}
		if (options.whisperCommand) {
			args.push("--whisper", options.whisperCommand);
		}

		const child = spawn("perl", [this.bridgePath, ...args], {
			stdio: ["ignore", "pipe", "pipe"],
			env: {
				...process.env,
				PI_LISTEN_MODEL: options.model ?? process.env.PI_LISTEN_MODEL ?? "",
			},
		});

		this.bridgeProcess = child;
		child.stdout.on("data", (chunk) => {
			console.log(`pi-listen bridge: ${chunk.toString("utf8").trimEnd()}`);
		});
		child.stderr.on("data", (chunk) => {
			console.error(`pi-listen bridge: ${chunk.toString("utf8").trimEnd()}`);
		});
		child.once("error", (error) => {
			this.fail(`Bridge failed to start: ${error.message}`);
		});
		child.once("close", (code, signal) => {
			const expected = this.state === "idle" && !this.socket;
			this.bridgeProcess = null;
			this.closeSocket();

			if (expected) {
				return;
			}

			if (code === 0 || signal === "SIGTERM") {
				this.state = "idle";
				this.previewText = "";
				this.render();
				return;
			}

			this.fail(`Bridge exited unexpectedly (code=${code}, signal=${signal ?? "none"}).`);
		});

		try {
			await this.connectSocket(this.socketPath);
			this.state = "listening";
			this.render();
			ctx.ui.notify(options.demo ? "pi-listen demo mode started." : "pi-listen started.", "info");
		} catch (error) {
			await this.stop(false);
			const message = error instanceof Error ? error.message : "Unable to connect to pi-listen bridge.";
			this.fail(message);
		}
	}

	async stop(notify = true) {
		this.previewText = "";
		this.closeSocket();

		if (this.bridgeProcess && !this.bridgeProcess.killed) {
			this.bridgeProcess.kill("SIGTERM");
		}

		this.bridgeProcess = null;
		this.state = "idle";
		this.lastError = null;
		this.render();

		if (notify && this.ctx?.hasUI) {
			this.ctx.ui.notify("pi-listen stopped.", "info");
		}
	}

	dispose() {
		this.previewText = "";
		this.closeSocket();

		if (this.bridgeProcess && !this.bridgeProcess.killed) {
			this.bridgeProcess.kill("SIGTERM");
		}

		this.bridgeProcess = null;
		this.state = "idle";
		this.lastError = null;
		this.ctx = undefined;
	}

	statusSummary() {
		if (this.state === "error" && this.lastError) {
			return `error: ${this.lastError}`;
		}
		if (this.state === "listening" && this.previewText) {
			return `listening: ${this.previewText}`;
		}
		return this.state;
	}

	private async connectSocket(socketPath: string) {
		const startedAt = Date.now();

		while (Date.now() - startedAt < DEFAULT_CONNECT_TIMEOUT_MS) {
			try {
				const socket = await new Promise<Socket>((resolve, reject) => {
					const connection = createConnection(socketPath);
					const onError = (error: Error) => {
						connection.removeAllListeners();
						connection.destroy();
						reject(error);
					};

					connection.once("error", onError);
					connection.once("connect", () => {
						connection.removeListener("error", onError);
						resolve(connection);
					});
				});

				this.socket = socket;
				this.lineBuffer.reset();
				socket.on("data", (chunk) => this.lineBuffer.push(chunk, (packet) => void this.handlePacket(packet)));
				socket.once("close", () => {
					if (this.socket === socket) {
						this.socket = null;
					}
				});
				socket.once("error", (error) => {
					console.error("pi-listen: Socket error", error);
				});
				return;
			} catch {
				if (!this.bridgeProcess) {
					break;
				}
				await new Promise((resolve) => setTimeout(resolve, DEFAULT_RETRY_DELAY_MS));
			}
		}

		throw new Error("Timed out waiting for pi-listen bridge socket.");
	}

	private async handlePacket(packet: BridgePacket) {
		const ctx = this.ctx;
		if (!ctx) {
			return;
		}

		if (packet.status === "streaming") {
			this.previewText = packet.text.trim();
			this.state = "listening";
			this.render();
			return;
		}

		if (packet.status === "final") {
			const text = packet.text.trim();
			this.previewText = "";
			this.render();
			if (!text || !ctx.hasUI) {
				return;
			}

			const editorText = ctx.ui.getEditorText();
			const prefix = editorText && !/\s$/.test(editorText) ? " " : "";
			ctx.ui.pasteToEditor(`${prefix}${text}`);
			return;
		}

		this.fail(packet.text.trim() || "Bridge reported an error.");
	}

	private fail(message: string) {
		this.state = "error";
		this.previewText = "";
		this.lastError = message;
		this.render();
		if (this.ctx?.hasUI) {
			this.ctx.ui.notify(`pi-listen: ${message}`, "error");
		}
	}

	private closeSocket() {
		if (this.socket) {
			this.socket.destroy();
			this.socket = null;
		}
		this.lineBuffer.reset();
	}

	private render() {
		if (!this.ctx?.hasUI) {
			return;
		}

		const suffix =
			this.state === "error" && this.lastError
				? `error: ${this.lastError}`
				: this.state === "listening" && this.previewText
					? `${RECORDING_INDICATOR} listening: ${this.previewText}`
					: this.state === "listening"
						? `${RECORDING_INDICATOR} listening`
					: this.state;

		this.ctx.ui.setStatus(STATUS_KEY, suffix);

		if (this.previewText) {
			this.ctx.ui.setWidget(WIDGET_KEY, [`${RECORDING_INDICATOR} Mic: ${this.previewText}`], {
				placement: "belowEditor",
			});
		} else if (this.state === "listening") {
			this.ctx.ui.setWidget(WIDGET_KEY, [`${RECORDING_INDICATOR} Mic: listening`], {
				placement: "belowEditor",
			});
		} else {
			this.ctx.ui.setWidget(WIDGET_KEY, undefined);
		}
	}
}

function parseListenOptions(rawArgs: string): ListenOptions {
	const parts = rawArgs.trim().split(/\s+/).filter(Boolean);
	const options: ListenOptions = { demo: false };

	for (let index = 0; index < parts.length; index += 1) {
		const part = parts[index];
		if (part === "--demo") {
			options.demo = true;
			continue;
		}
		if (part.startsWith("--model=")) {
			options.model = part.slice("--model=".length);
			continue;
		}
		if (part === "--model" && parts[index + 1]) {
			options.model = parts[index + 1];
			index += 1;
			continue;
		}
		if (part.startsWith("--whisper=")) {
			options.whisperCommand = part.slice("--whisper=".length);
			continue;
		}
		if (part === "--whisper" && parts[index + 1]) {
			options.whisperCommand = parts[index + 1];
			index += 1;
		}
	}

	return options;
}

export default function piListen(pi: ExtensionAPI) {
	const runtime = new PiListenRuntime();

	pi.on("session_start", async (_event, ctx) => {
		runtime.setContext(ctx);
		pi.sendMessage({
			customType: "pi-listen",
			display: "pi-listen",
			content: STARTUP_HEADER,
		});
	});

	pi.on("session_shutdown", async () => {
		runtime.dispose();
	});

	pi.registerCommand("listen", {
		description: "Start or toggle pi-listen. Use --demo to simulate transcripts.",
		handler: async (args, ctx) => {
			runtime.setContext(ctx);
			if (runtime.isActive()) {
				await runtime.stop();
				return;
			}

			await runtime.start(ctx, parseListenOptions(args));
		},
	});

	pi.registerCommand("listen-stop", {
		description: "Stop the pi-listen bridge.",
		handler: async (_args, ctx) => {
			runtime.setContext(ctx);
			await runtime.stop();
		},
	});

	pi.registerCommand("listen-status", {
		description: "Show pi-listen runtime state.",
		handler: async (_args, ctx) => {
			runtime.setContext(ctx);
			ctx.ui.notify(`pi-listen ${runtime.statusSummary()}`, "info");
		},
	});

	pi.registerShortcut("alt+l", {
		description: "Toggle pi-listen",
		handler: async (ctx) => {
			runtime.setContext(ctx);
			if (runtime.isActive()) {
				await runtime.stop();
				return;
			}

			await runtime.start(ctx, parseListenOptions(""));
		},
	});

	process.once("beforeExit", () => {
		runtime.dispose();
	});
}
