// scripts/verify_live.mjs (ADR-075): is what the sites serve exactly the source at a commit on
// main? Runs the script against fake sites on this machine, served the way Cloudflare serves
// static assets (/x.html at /x, /dir/index.html at /dir/), and a fake short link, with a small
// Git repository made for the test as the source (as in a clone) and a fake GitHub API backed by it
// (as anywhere else). Nothing here reaches the network.
//   node --test tests/scripts/verify_live.test.mjs

import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { after, before, test } from "node:test";
import { fileURLToPath } from "node:url";

import {
  GitHubSource, GitSource, GRACE_MS, askable, assetsIgnore, expectedHeaders, httpClient, main, parseHeaders, parseRedirects, verify,
} from "../../scripts/verify_live.mjs";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const REPOSITORY = "https://code.example/DirectorLink";
const IGNORE = "wrangler.jsonc\n.assetsignore\nREADME.md\n";
const FILES = {
  "app/index.html": "<!doctype html><title>App</title>\n",
  "app/app.js": "export const version = 1;\n",
  "app/js/views/home.js": "export const home = true;\n",
  "app/icons/icon.png": Buffer.from(Array.from({ length: 256 }, (_, i) => i)),
  "app/README.md": "# The app (not published)\n",
  "app/js/README.md": "A pattern without a slash matches at any depth: not published either.\n",
  "app/wrangler.jsonc": "{}\n",
  "app/.assetsignore": IGNORE,
  "app/_headers": "/*\n  X-Frame-Options: DENY\n  Content-Security-Policy: default-src 'self'\n",
  "app/_redirects": "# Cloudflare reads this file; it is not served.\n/console.html https://console.example/ 301\n",
  "console/index.html": "<!doctype html><title>Console</title>\n",
  "console/console.js": "export const console = true;\n",
  "console/.assetsignore": IGNORE,
  "console/_headers": "/*\n  X-Frame-Options: DENY\n",
  "site/index.html": "<!doctype html><title>Site</title>\n",
  "site/privacy.html": "<!doctype html><title>Privacy</title>\n",
  "site/drivers/index.html": "<!doctype html><title>Drivers</title>\n",
  "site/drivers/fridge.html": "<!doctype html><title>Fridge</title>\n",
  "site/.assetsignore": IGNORE,
  "site/_headers": "/*\n  X-Frame-Options: DENY\n",
  "site/_redirects": [
    "/drivers/fridge/download https://code.example/DirectorLink-Fridge/releases/latest/download/Fridge.c4z 302",
    "/drivers/fridge/source https://code.example/DirectorLink-Fridge 302",
    "",
  ].join("\n"),
  "github-link/worker.js": [
    `const REPOSITORY = "${REPOSITORY}";`,
    "export default {",
    "  fetch(request) {",
    "    const url = new URL(request.url);",
    '    const path = url.pathname === "/" ? "" : url.pathname;',
    "    return Response.redirect(REPOSITORY + path + url.search, 301);",
    "  },",
    "};",
    "",
  ].join("\n"),
};
const NOT_SERVED = new Set([".assetsignore", "_headers", "_redirects", "wrangler.jsonc", "README.md", "js/README.md"]);
const HEADERS = {
  app: { "x-frame-options": "DENY", "content-security-policy": "default-src 'self'" },
  console: { "x-frame-options": "DENY" },
  site: { "x-frame-options": "DENY" },
};

let repo;
let commits;
const servers = [];

function git(...args) {
  return execFileSync("git", args, { cwd: repo, encoding: "utf8", windowsHide: true }).trim();
}

function write(files) {
  for (const [path, content] of Object.entries(files)) {
    mkdirSync(dirname(join(repo, path)), { recursive: true });
    writeFileSync(join(repo, path), content);
  }
}

function commit(message) {
  git("add", "-A");
  git("commit", "-q", "-m", message);
  return git("rev-parse", "HEAD");
}

before(() => {
  repo = mkdtempSync(join(tmpdir(), "verify-live-"));
  git("init", "-q", "-b", "main");
  git("config", "user.name", "Test");
  git("config", "user.email", "test@example.invalid");
  git("config", "core.autocrlf", "false");
  write(FILES);
  const first = commit("first");
  write({ "app/app.js": "export const version = 2;\n", "app/js/new.js": "export const added = true;\n" });
  const second = commit("second");
  git("checkout", "-q", "-b", "side");
  write({ "app/app.js": "export const version = 'not on main';\n" });
  const side = commit("a commit on another branch");
  git("checkout", "-q", "main");
  commits = { first, second, side };
});

after(async () => {
  await Promise.all(servers.map((server) => new Promise((done) => server.close(done))));
  rmSync(repo, { recursive: true, force: true });
});

// What Cloudflare publishes from a folder at a commit: its files but the settings and the ignored.
function published(commitId, folder) {
  const files = new Map();
  const listed = git("ls-tree", "-r", "--name-only", commitId, "--", `${folder}/`).split("\n").filter(Boolean);
  for (const path of listed) {
    const inside = path.slice(folder.length + 1);
    if (NOT_SERVED.has(inside)) continue;
    files.set(`/${inside}`, execFileSync("git", ["cat-file", "blob", `${commitId}:${path}`], { cwd: repo }));
  }
  return files;
}

function redirectsAt(commitId, folder) {
  const rules = new Map();
  let text = "";
  try {
    text = execFileSync("git", ["cat-file", "blob", `${commitId}:${folder}/_redirects`], { cwd: repo, encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] });
  } catch {
    return rules;
  }
  for (const rule of parseRedirects(text)) rules.set(rule.from, [rule.status, rule.to]);
  return rules;
}

function listen(handler) {
  return new Promise((done) => {
    const server = createServer(handler);
    servers.push(server);
    server.listen(0, "127.0.0.1", () => done(`http://127.0.0.1:${server.address().port}`));
  });
}

// A static-assets Worker: _redirects first, then html_handling "auto-trailing-slash", then files.
function site(state) {
  return listen((request, response) => {
    const path = decodeURIComponent(new URL(request.url, "http://localhost").pathname);
    state.asked.push(path);
    if (state.failFirst > 0) {
      state.failFirst -= 1;
      request.socket.destroy();
      return;
    }
    const redirect = state.redirects.get(path);
    if (redirect) {
      response.writeHead(redirect[0], { location: redirect[1] });
      response.end();
      return;
    }
    if (path === "/build.json" && state.build) {
      response.writeHead(200, { "content-type": "application/json" });
      response.end(typeof state.build === "string" ? state.build : JSON.stringify(state.build));
      return;
    }
    const shorter = path.endsWith("/index.html") ? path.slice(0, -"index.html".length) : path.endsWith(".html") ? path.slice(0, -".html".length) : null;
    if (shorter && state.files.has(path)) {
      response.writeHead(307, { location: shorter });
      response.end();
      return;
    }
    const file = path.endsWith("/") ? `${path}index.html` : state.files.has(path) ? path : `${path}.html`;
    if (!state.files.has(file)) {
      response.writeHead(404);
      response.end("Not found");
      return;
    }
    response.writeHead(200, state.headers);
    response.end(state.files.get(file));
  });
}

function shortLink(state) {
  return listen((request, response) => {
    const url = new URL(request.url, "http://localhost");
    const path = url.pathname === "/" ? "" : url.pathname;
    response.writeHead(301, { location: (state.repository ?? REPOSITORY) + path + url.search });
    response.end();
  });
}

const ISO_AGO = (ms) => new Date(Date.now() - ms).toISOString();

// The three sites and the short link, as deployed from a commit; change() alters what they serve.
async function deployment({ commitId = commits.second, stamped = true, builtAgo = 60 * 60 * 1000 } = {}) {
  const states = {};
  const sites = [];
  for (const [name, folder] of [["app", "app"], ["console", "console"], ["website", "site"]]) {
    const state = {
      files: published(commitId, folder),
      headers: { ...HEADERS[folder] },
      redirects: redirectsAt(commitId, folder),
      build: stamped ? { commit: commitId, built_at: ISO_AGO(builtAgo) } : null,
      failFirst: 0,
      asked: [],
    };
    states[folder] = state;
    sites.push({ name, folder, url: await site(state) });
  }
  states.link = {};
  const link = { name: "short link", folder: "github-link", url: await shortLink(states.link), paths: ["/", "/releases/latest"] };
  return { states, sites, link };
}

const client = () => httpClient({ attempts: 3, delays: [5, 5], timeoutMs: 5000 });
const fromClone = () => new GitSource({ root: repo, main: "refs/heads/main", fetch: false });

async function check(setup, source = fromClone()) {
  return verify({ source, sites: setup.sites, shortLink: setup.link, get: client() });
}

const problemsOf = (report, folder) => report.sites.find((entry) => entry.folder === folder).problems;

test("sites that serve exactly the source at their build.json commit pass", async () => {
  const setup = await deployment();
  const report = await check(setup);
  assert.equal(report.result, "equal", report.text);
  const app = report.sites.find((entry) => entry.folder === "app");
  assert.equal(app.commit, commits.second);
  assert.equal(app.files, 5, "index.html, app.js, js/views/home.js, js/new.js and the icon; not the README files, the settings or wrangler.jsonc");
  assert.equal(app.redirects, 1);
  assert.equal(report.sites.find((entry) => entry.folder === "site").redirects, 2);
  assert.ok(setup.states.app.asked.includes("/index.html") && setup.states.app.asked.includes("/"), "/index.html is followed to /");
  assert.ok(setup.states.site.asked.includes("/privacy"), "/privacy.html is followed to /privacy");
  assert.ok(!setup.states.app.asked.includes("/README.md") && !setup.states.app.asked.includes("/_headers"), "what Cloudflare does not publish is not asked for");
  assert.match(report.text, /Result: everything served is the same as the public source\./);
  assert.equal(report.fingerprint, null);
});

test("a changed byte is a difference, named with both SHA-256", async () => {
  const setup = await deployment();
  const changed = Buffer.from(setup.states.app.files.get("/icons/icon.png"));
  changed[100] ^= 1;
  setup.states.app.files.set("/icons/icon.png", changed);
  const report = await check(setup);
  assert.equal(report.result, "differs");
  const [found] = problemsOf(report, "app");
  assert.equal(found.kind, "changed");
  assert.equal(found.path, "/icons/icon.png");
  assert.notEqual(found.served_sha256, found.source_sha256);
  assert.match(found.message, /^\/icons\/icon\.png is not the file in the source: served 256 bytes, SHA-256 [0-9a-f]{16}…; the source has 256 bytes/);
  assert.match(report.text, /DIFFERENT from the source/);
  assert.match(report.text, /please report it privately: https:\/\/github\.directorlink\.io\/security\/advisories\/new/);
  assert.match(report.fingerprint, /^[0-9a-f]{16}$/);
});

test("in a clone, a changed file says which commit and branch its bytes come from", async () => {
  const setup = await deployment();
  const blob = (commitId) => execFileSync("git", ["cat-file", "blob", `${commitId}:app/app.js`], { cwd: repo });
  setup.states.app.files.set("/app.js", blob(commits.side));
  setup.states.console.files.set("/console.js", Buffer.from("export const console = 'in no commit';\n"));
  setup.states.site.files.set("/index.html", Buffer.from("<!doctype html><title>Site</title>\n<!-- edited -->\n"));
  let report = await check(setup);
  const [app] = problemsOf(report, "app");
  assert.match(app.message, new RegExp(`…; the served bytes are the file of commit ${commits.side.slice(0, 7)} \\(side\\), which is not on main$`));
  assert.equal(app.served_from, `commit ${commits.side.slice(0, 7)} (side), which is not on main`);
  assert.equal(problemsOf(report, "console")[0].served_from, undefined, "bytes in no commit: nothing to say");

  setup.states.app.files.set("/app.js", blob(commits.first));
  report = await check(setup);
  assert.equal(problemsOf(report, "app")[0].served_from, `commit ${commits.first.slice(0, 7)} on main`, "an older version");
});

test("a file of the source that is not served is a difference", async () => {
  const setup = await deployment();
  setup.states.console.files.delete("/console.js");
  const report = await check(setup);
  assert.equal(report.result, "differs");
  assert.deepEqual(problemsOf(report, "console").map((found) => [found.kind, found.path]), [["missing", "/console.js"]]);
});

test("a redirect the source does not have is a difference: off the site, or to another target", async () => {
  const setup = await deployment();
  setup.states.app.redirects.set("/app.js", [302, "https://elsewhere.example/app.js"]);
  setup.states.site.redirects.set("/drivers/fridge/download", [302, "https://elsewhere.example/Fridge.c4z"]);
  const report = await check(setup);
  assert.equal(report.result, "differs");
  const [app] = problemsOf(report, "app");
  assert.equal(app.kind, "redirected");
  assert.match(app.message, /^\/app\.js redirects to https:\/\/elsewhere\.example\/app\.js \(302\) instead of serving the file$/);
  const [driver] = problemsOf(report, "site");
  assert.equal(driver.kind, "redirect");
  assert.equal(driver.message, "/drivers/fridge/download answers 302 to https://elsewhere.example/Fridge.c4z; _redirects says 302 to https://code.example/DirectorLink-Fridge/releases/latest/download/Fridge.c4z");
});

test("a redirect of _redirects that is missing or answers another status is a difference", async () => {
  const setup = await deployment();
  setup.states.app.redirects.delete("/console.html");
  setup.states.site.redirects.set("/drivers/fridge/source", [301, "https://code.example/DirectorLink-Fridge"]);
  const report = await check(setup);
  assert.deepEqual(problemsOf(report, "app").map((found) => found.message), ["/console.html answers 404, no redirect; _redirects says 301 to https://console.example/"]);
  assert.deepEqual(problemsOf(report, "site").map((found) => found.message), ["/drivers/fridge/source answers 301 to https://code.example/DirectorLink-Fridge; _redirects says 302 to https://code.example/DirectorLink-Fridge"]);
});

test("a header _headers sets that is changed or missing is a difference, once for all the files", async () => {
  const setup = await deployment();
  setup.states.app.headers["content-security-policy"] = "default-src *";
  delete setup.states.site.headers["x-frame-options"];
  const report = await check(setup);
  assert.equal(report.result, "differs");
  assert.deepEqual(problemsOf(report, "app").map((found) => found.message), [
    `the content-security-policy header of 5 files (/app.js and others) is "default-src *"; _headers says "default-src 'self'"`,
  ]);
  assert.deepEqual(problemsOf(report, "site").map((found) => found.message), [
    `the x-frame-options header of 4 files (/drivers/fridge.html and others) is missing; _headers says "DENY"`,
  ]);
});

test("a build.json commit that is not on main is a difference, even right after a deploy", async () => {
  const setup = await deployment();
  setup.states.app.build = { commit: commits.side, built_at: ISO_AGO(60 * 1000) };
  const report = await check(setup);
  assert.equal(report.result, "differs");
  const [found] = problemsOf(report, "app");
  assert.equal(found.kind, "not-on-main");
  assert.equal(found.message, `/build.json says the site was built from commit ${commits.side}, which is not on main`);
});

test("a build.json that is not what deploy.yml writes is a difference", async () => {
  const setup = await deployment();
  setup.states.console.build = "<html>not json</html>";
  setup.states.site.build = { commit: "main", built_at: ISO_AGO(0) };
  const report = await check(setup);
  assert.equal(report.result, "differs");
  assert.equal(problemsOf(report, "console")[0].kind, "build-json");
  assert.equal(problemsOf(report, "site")[0].kind, "build-json");
});

test("within 10 minutes of a deploy a difference waits; after them it is reported", async () => {
  const fresh = await deployment({ builtAgo: 3 * 60 * 1000 });
  fresh.states.app.files.set("/app.js", Buffer.from("export const version = 1;\n"));
  const waiting = await check(fresh);
  assert.equal(waiting.result, "pending", waiting.text);
  assert.equal(waiting.sites.find((entry) => entry.folder === "app").status, "pending");
  assert.ok(Date.parse(waiting.settled_at) > Date.now() + 6 * 60 * 1000);
  assert.match(waiting.text, /deployed less than 10 minutes ago, still settling/);
  assert.match(waiting.text, /Result: a deploy finished minutes ago and may still be settling\. Check again after/);

  const old = await deployment({ builtAgo: GRACE_MS + 60 * 1000 });
  old.states.app.files.set("/app.js", Buffer.from("export const version = 1;\n"));
  assert.equal((await check(old)).result, "differs");

  // A built_at far in the future is no reason to wait.
  const future = await deployment({ builtAgo: -60 * 60 * 1000 });
  future.states.app.files.set("/app.js", Buffer.from("export const version = 1;\n"));
  assert.equal((await check(future)).result, "differs");
});

test("--wait checks again once the deploy has settled", async () => {
  const setup = await deployment({ builtAgo: 9 * 60 * 1000 });
  setup.states.app.files.set("/app.js", Buffer.from("export const version = 1;\n"));
  const waited = [];
  const out = { text: "", write(chunk) { this.text += chunk; } };
  const err = { text: "", write(chunk) { this.text += chunk; } };
  const code = await main(["--wait"], {
    out, err, source: fromClone(), sites: setup.sites, shortLink: setup.link, get: client(),
    wait: async (ms) => {
      waited.push(ms);
      setup.states.app.files = published(commits.second, "app");
    },
  });
  assert.equal(code, 0, out.text);
  assert.equal(waited.length, 1);
  assert.ok(waited[0] > 30 * 1000 && waited[0] <= 2 * 60 * 1000, `waits until the 10 minutes are over (${waited[0]} ms)`);
  assert.match(err.text, /A deploy finished minutes ago: checking again in \d+ s\./);
  assert.match(out.text, /Result: everything served is the same/);
});

test("a site without a build.json is compared with main's latest commits that changed its folder", async () => {
  // Served from the first commit: main changed app/ since (not deployed yet), not console/ or site/.
  const setup = await deployment({ commitId: commits.first, stamped: false });
  const report = await check(setup);
  assert.equal(report.result, "equal", report.text);
  const app = report.sites.find((entry) => entry.folder === "app");
  assert.equal(app.build_json, false);
  assert.equal(app.commit, commits.first);
  assert.deepEqual(app.notes, ["not deployed with a build.json yet"]);
  assert.match(report.text, /: not deployed with a build\.json yet, and the same as the source\./);
  assert.match(report.text, new RegExp(`those of commit ${commits.first.slice(0, 7)}; main has 1 newer change to app/ not deployed yet`));
  assert.match(report.text, new RegExp(`those of commit ${commits.first.slice(0, 7)}, the latest change to console/ on main`));

  // Files that are none of them are a difference, compared with the closest.
  setup.states.console.files.set("/console.js", Buffer.from("export const console = 'changed';\n"));
  const changed = await check(setup);
  assert.equal(changed.result, "differs");
  assert.deepEqual(problemsOf(changed, "console").map((found) => found.kind), ["changed"]);
  assert.match(changed.text, /Not deployed with a build\.json, and none of main's latest commits that changed console\/ is what it serves/);
});

test("the short link must lead to the repository as github-link/worker.js says", async () => {
  const setup = await deployment();
  setup.states.link.repository = "https://elsewhere.example/DirectorLink";
  const report = await check(setup);
  assert.equal(report.result, "differs");
  const link = report.sites.find((entry) => entry.folder === "github-link");
  assert.deepEqual(link.problems.map((found) => found.message), [
    `/ answers 301 to https://elsewhere.example/DirectorLink; github-link/worker.js says 301 to ${REPOSITORY}`,
    `/releases/latest answers 301 to https://elsewhere.example/DirectorLink/releases/latest; github-link/worker.js says 301 to ${REPOSITORY}/releases/latest`,
  ]);
});

test("network errors are tried again, and a site that stays away is not called different", async () => {
  const setup = await deployment();
  setup.states.app.failFirst = 2;
  const retried = await check(setup);
  assert.equal(retried.result, "equal", retried.text);

  const closed = await listen(() => {});
  servers.at(-1).close();
  const away = await deployment();
  away.sites[1].url = closed;
  const report = await check(away);
  assert.equal(report.result, "incomplete");
  const console = report.sites.find((entry) => entry.folder === "console");
  assert.equal(console.status, "incomplete");
  assert.equal(console.problems.length, 0);
  assert.match(report.text, /could not be checked completely; nothing found differs/);
  assert.match(report.text, /Result: not everything could be checked/);
});

test("a site that turns the check away (403) is not called different", async () => {
  const setup = await deployment();
  const blocked = await listen((request, response) => {
    response.writeHead(403);
    response.end("challenge");
  });
  setup.sites[2].url = blocked;
  const report = await check(setup);
  assert.equal(report.result, "incomplete");
  assert.match(report.sites.find((entry) => entry.folder === "site").notes[0], /answered 403: this check was turned away/);
});

// GitHub's API and raw files, answered from the test's repository.
async function fakeGitHub() {
  const asked = [];
  const url = await listen((request, response) => {
    const { pathname, searchParams } = new URL(request.url, "http://localhost");
    asked.push(pathname);
    const json = (status, body) => {
      response.writeHead(status, { "content-type": "application/json" });
      response.end(JSON.stringify(body));
    };
    const run = (...args) => execFileSync("git", args, { cwd: repo, stdio: ["ignore", "pipe", "ignore"] });
    let match;
    if ((match = /^\/repos\/DirectorLink\/DirectorLink\/compare\/([0-9a-f]+)\.\.\.main$/.exec(pathname))) {
      try {
        run("cat-file", "-e", `${match[1]}^{commit}`);
      } catch {
        return json(404, { message: "Not Found" });
      }
      if (match[1] === git("rev-parse", "main")) return json(200, { status: "identical" });
      try {
        run("merge-base", "--is-ancestor", match[1], "main");
        return json(200, { status: "ahead" });
      } catch {
        return json(200, { status: "diverged" });
      }
    }
    if (pathname === "/repos/DirectorLink/DirectorLink/commits") {
      const shas = git("log", `-n${searchParams.get("per_page")}`, "--format=%H", searchParams.get("sha"), "--", `${searchParams.get("path")}/`).split("\n").filter(Boolean);
      return json(200, shas.map((sha) => ({ sha })));
    }
    if (pathname === "/repos/DirectorLink/DirectorLink/branches/main") return json(200, { commit: { sha: git("rev-parse", "main") } });
    if ((match = /^\/repos\/DirectorLink\/DirectorLink\/git\/trees\/([0-9a-f]+)$/.exec(pathname))) {
      const tree = git("ls-tree", "-r", match[1]).split("\n").filter(Boolean).map((line) => {
        const [meta, path] = line.split("\t");
        const [mode, type, sha] = meta.split(" ");
        return { path, mode, type, sha };
      });
      return json(200, { sha: match[1], tree, truncated: false });
    }
    if ((match = /^\/DirectorLink\/DirectorLink\/([0-9a-f]+)\/(.+)$/.exec(pathname))) {
      try {
        response.writeHead(200);
        return response.end(run("cat-file", "blob", `${match[1]}:${decodeURIComponent(match[2])}`));
      } catch {
        response.writeHead(404);
        return response.end();
      }
    }
    return json(404, { message: "Not Found" });
  });
  return { url, asked };
}

test("anywhere else it compares with the public repository on GitHub", async () => {
  const github = await fakeGitHub();
  const fromGitHub = () => new GitHubSource({ api: github.url, raw: github.url, get: client() });
  const setup = await deployment();
  const report = await check(setup, fromGitHub());
  assert.equal(report.result, "equal", report.text);
  assert.match(report.text, /against the public repository on GitHub \(https:\/\/github\.directorlink\.io\)/);
  assert.ok(github.asked.some((path) => path.endsWith(`/compare/${commits.second}...main`)));

  setup.states.app.build = { commit: commits.side, built_at: ISO_AGO(60 * 60 * 1000) };
  setup.states.console.build = { commit: "0123456789abcdef0123456789abcdef01234567", built_at: ISO_AGO(60 * 60 * 1000) };
  const wrong = await check(setup, fromGitHub());
  assert.equal(wrong.result, "differs");
  assert.equal(problemsOf(wrong, "app")[0].kind, "not-on-main");
  assert.equal(problemsOf(wrong, "console")[0].kind, "not-on-main", "a commit GitHub does not have is not on main");

  const unstamped = await deployment({ commitId: commits.first, stamped: false });
  const before = await check(unstamped, fromGitHub());
  assert.equal(before.result, "equal", before.text);
  assert.equal(before.sites[0].commit, commits.first);
});

test("--github asks GitHub's API and raw files, from the command line too", async () => {
  const github = await fakeGitHub();
  const client_ = client();
  // api.github.com and raw.githubusercontent.com, answered by the fake.
  const get = (url, options) => {
    const target = new URL(url);
    if (target.host === "api.github.com" || target.host === "raw.githubusercontent.com") return client_(new URL(`${target.pathname}${target.search}`, github.url), options);
    return client_(url, options);
  };
  const setup = await deployment();
  const out = { text: "", write(chunk) { this.text += chunk; } };
  const code = await main(["--github"], { out, err: out, root: repo, sites: setup.sites, shortLink: setup.link, get });
  assert.equal(code, 0, out.text);
  assert.match(out.text, /against the public repository on GitHub/);
  assert.ok(github.asked.some((path) => path.startsWith("/repos/DirectorLink/DirectorLink/git/trees/")));
  assert.ok(github.asked.some((path) => path.startsWith(`/DirectorLink/DirectorLink/${commits.second}/app/`)));
});

test("in a clone that cannot fetch, a commit it does not have is not checked rather than called different", async () => {
  const setup = await deployment();
  setup.states.app.build = { commit: "0123456789abcdef0123456789abcdef01234567", built_at: ISO_AGO(60 * 60 * 1000) };
  const report = await check(setup);
  assert.equal(report.result, "incomplete");
  assert.match(report.sites[0].notes[0], /^commit 0123456 is not in this clone: run git fetch origin, or leave out --no-fetch$/);

  // Allowed to fetch, but origin cannot be reached: the same, saying why.
  git("remote", "add", "origin", join(repo, "no-such-origin"));
  try {
    const offline = await check(setup, new GitSource({ root: repo, main: "refs/heads/main", fetch: true }));
    assert.equal(offline.result, "incomplete", offline.text);
    assert.match(offline.sites[0].notes[0], /^commit 0123456 is not on this clone's main, and git fetch failed: /);
    assert.equal(offline.sites[1].status, "equal", "a commit the clone has is checked as usual");
  } finally {
    git("remote", "remove", "origin");
  }
});

test("the command line: exit code 0 or 1, and --json writes the report", async () => {
  const setup = await deployment();
  const folder = mkdtempSync(join(tmpdir(), "verify-live-report-"));
  try {
    const out = { text: "", write(chunk) { this.text += chunk; } };
    const options = { out, err: out, source: fromClone(), sites: setup.sites, shortLink: setup.link, get: client() };
    assert.equal(await main(["--json", join(folder, "report.json")], options), 0);
    const saved = JSON.parse(readFileSync(join(folder, "report.json"), "utf8"));
    assert.equal(saved.result, "equal");
    assert.equal(saved.sites.length, 4);
    assert.equal(saved.text, out.text);

    setup.states.app.files.delete("/app.js");
    out.text = "";
    assert.equal(await main(["--json", join(folder, "report.json")], options), 1);
    assert.equal(JSON.parse(readFileSync(join(folder, "report.json"), "utf8")).result, "differs");

    out.text = "";
    assert.equal(await main(["--help"], options), 0);
    assert.match(out.text, /Exit code 0 when everything served is the same as the source, 1 otherwise\./);
    assert.equal(await main(["--nonsense"], options), 1);
  } finally {
    rmSync(folder, { recursive: true, force: true });
  }
});

test(".assetsignore is read as wrangler reads it (.gitignore rules)", () => {
  const ignored = assetsIgnore("wrangler.jsonc\nREADME.md\n/only-here.txt\ndocs/\n*.map\n!keep.map\n# a comment\n\nvendor/**/*.txt\n");
  for (const path of ["README.md", "js/README.md", "only-here.txt", "docs/a.html", "a/docs/b.html", "app.js.map", "_headers", "_redirects", ".assetsignore", "vendor/a/b/c.txt", "vendor/c.txt"]) {
    assert.equal(ignored(path), true, path);
  }
  for (const path of ["build.json", "x/only-here.txt", "docs", "keep.map", "js/_headers", "index.html", "vendor/c.js"]) {
    assert.equal(ignored(path), false, path);
  }
});

test("each site's real .assetsignore publishes build.json and keeps its README back", () => {
  for (const folder of ["app", "console", "site"]) {
    const ignored = assetsIgnore(readFileSync(join(ROOT, folder, ".assetsignore"), "utf8"));
    assert.equal(ignored("build.json"), false, folder);
    assert.equal(ignored("wrangler.jsonc"), true, folder);
    assert.equal(ignored("index.html"), false, folder);
  }
});

test("_headers: rules apply in order, the same header twice is joined, ! takes one away", () => {
  const rules = parseHeaders("# headers\n/*\n  X-Frame-Options: DENY\n  Link: </a>\n/secure/*\n  ! X-Frame-Options\n  Link: </b>\n/:name/page\n  X-Name: yes\n");
  const at = (path) => Object.fromEntries(expectedHeaders(rules, new URL(path, "https://site.example")));
  assert.deepEqual(at("/index.html"), { "x-frame-options": "DENY", link: "</a>" });
  assert.deepEqual(at("/secure/x"), { link: "</a>, </b>" });
  assert.deepEqual(at("/any/page"), { "x-frame-options": "DENY", link: "</a>", "x-name": "yes" });
});

test("_redirects: every line of the real website's and app's is checked", () => {
  for (const folder of ["site", "app"]) {
    const text = readFileSync(join(ROOT, folder, "_redirects"), "utf8");
    const rules = parseRedirects(text);
    assert.equal(rules.length, text.split("\n").filter((line) => line.startsWith("/")).length, folder);
    assert.ok(rules.length && rules.every(askable), folder);
  }
  const drivers = parseRedirects(readFileSync(join(ROOT, "site", "_redirects"), "utf8"));
  assert.ok(drivers.every((rule) => rule.status === 302 && /^\/drivers\/[a-z0-9-]+\/(download|releases|issues|source)$/.test(rule.from)));
  assert.equal(askable({ from: "/drivers/*", to: "/x", status: 302 }), false, "a splat cannot be asked");
  assert.equal(askable({ from: "/a/:name", to: "/b/:name", status: 301 }), false, "nor a placeholder");
  assert.equal(askable({ from: "/a", to: "/b", status: 200 }), false, "nor a rewrite");
});
