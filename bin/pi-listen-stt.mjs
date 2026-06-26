#!/usr/bin/env node
import { spawn } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = dirname(fileURLToPath(import.meta.url));

function emit(status, text) {
	process.stdout.write(`${status}\t${text}\n`);
}

function run(command, args) {
	const child = spawn(command, args, {
		stdio: ["ignore", "pipe", "pipe"],
	});

	child.stdout.pipe(process.stdout);
	child.stderr.on("data", (chunk) => {
		const text = chunk.toString("utf8").trim();
		if (text) {
			emit("error", text);
		}
	});
	child.once("error", (error) => {
		emit("error", error.message);
		process.exitCode = 1;
	});
	child.once("close", (code, signal) => {
		if (signal) {
			process.exit(0);
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
