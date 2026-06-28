#!/usr/bin/env node
import { spawn } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = dirname(fileURLToPath(import.meta.url));

function emit(status, text) {
	process.stdout.write(`${status}\t${text}\n`);
}

function run(command, args) {
	const swiftCache = process.platform === "darwin"
		? mkdtempSync(join(tmpdir(), "pi-listen-swift-cache-"))
		: undefined;
	let emittedOutput = false;
	const child = spawn(command, args, {
		stdio: ["ignore", "pipe", "pipe"],
		env: swiftCache
			? {
				...process.env,
				CLANG_MODULE_CACHE_PATH: swiftCache,
			}
			: process.env,
	});

	child.stdout.on("data", (chunk) => {
		emittedOutput = true;
		process.stdout.write(chunk);
	});
	child.stderr.on("data", (chunk) => {
		const text = chunk.toString("utf8").trim();
		if (text) {
			emittedOutput = true;
			emit("error", text);
		}
	});
	child.once("error", (error) => {
		emittedOutput = true;
		emit("error", error.message);
		process.exitCode = 1;
	});
	child.once("close", (code, signal) => {
		if (swiftCache) {
			rmSync(swiftCache, { recursive: true, force: true });
		}
		if (signal) {
			process.exit(0);
		}
		if (!emittedOutput) {
			emit("error", `${command} exited before producing transcript output (code=${code ?? "none"}).`);
		}
		process.exit(code ?? 0);
	});

	const stop = () => {
		if (!child.killed) {
			child.kill("SIGTERM");
		}
	};
	process.once("SIGINT", stop);
	process.once("SIGTERM", stop);
}

if (process.platform === "darwin") {
	run("swift", [join(root, "pi-listen-darwin.swift")]);
} else if (process.platform === "win32") {
	run("powershell.exe", ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", join(root, "pi-listen-windows.ps1")]);
} else {
	emit("error", "pi-listen has no bundled Linux speech-to-text backend yet. Set PI_LISTEN_WHISPER_CMD to a command that prints transcript frames.");
}
