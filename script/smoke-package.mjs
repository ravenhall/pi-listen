import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";

const tempRoot = mkdtempSync(join(tmpdir(), "pi-listen-pack-"));

function run(command, args, options = {}) {
	const result = spawnSync(command, args, {
		encoding: "utf8",
		stdio: ["ignore", "pipe", "pipe"],
		...options,
	});

	if (result.status !== 0) {
		const detail = [result.stdout, result.stderr].filter(Boolean).join("\n");
		throw new Error(`${command} ${args.join(" ")} failed\n${detail}`);
	}

	return result;
}

try {
	const env = {
		...process.env,
		npm_config_cache: join(tempRoot, "npm-cache"),
	};

	const pack = run("npm", ["pack", "--pack-destination", tempRoot], { env });
	const tarball = pack.stdout.trim().split(/\r?\n/).at(-1);
	if (!tarball) {
		throw new Error("npm pack did not report a tarball name.");
	}

	const tarballPath = join(tempRoot, tarball);
	const listing = run("tar", ["-tf", tarballPath]).stdout;
	if (!listing.includes("package/lib/Pi/Listen/Bridge.pm\n")) {
		throw new Error("Packaged tarball is missing lib/Pi/Listen/Bridge.pm.");
	}

	run("tar", ["-xzf", tarballPath, "-C", tempRoot]);
	run("perl", ["-c", join(tempRoot, "package", "bin", "pi-listen-bridge.pl")]);
	console.log("Package smoke test passed.");
} finally {
	rmSync(tempRoot, { recursive: true, force: true });
}
