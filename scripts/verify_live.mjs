#!/usr/bin/env node
// Is what DirectorLink's sites serve exactly the public source? (ADR-075)
//
//   node scripts/verify_live.mjs [--wait] [--json report.json] [--github] [--no-fetch]
//
// app.directorlink.io, console.directorlink.io and directorlink.io each serve /build.json, which
// .github/workflows/deploy.yml writes when the owner approves a deploy: the commit the site was
// built from, and when. This script checks that the commit is on main, then fetches every file
// that folder of the repository publishes at that commit, as Cloudflare publishes it (not what its
// .assetsignore names, nor _headers and _redirects, which are Cloudflare's settings, not files),
// and compares each one's SHA-256 with the file in the repository. It also checks the headers
// _headers sets, every redirect _redirects lists (the drivers' download links on directorlink.io),
// and that https://github.directorlink.io leads to the repository as github-link/worker.js says.
// A site without a build.json (deployed before ADR-075) is compared with the latest commits of
// main that changed its folder.
//
// In a clone of the repository it reads the clone, and fetches origin's main when a site names a
// commit the clone does not have yet; anywhere else it reads the public repository on GitHub
// (GITHUB_TOKEN, if set, only raises GitHub's limit on requests). Node 22 or later, nothing to
// install, no secrets. Exit code 0 when everything served is the same as the source, 1 otherwise;
// the report says what differs, or what could not be checked.

import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { parseArgs, promisify } from "node:util";

const execFileAsync = promisify(execFile);
const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");

// The repository on GitHub (owner/name), for its API and raw files.
export const REPOSITORY = "DirectorLink/DirectorLink";
export const SITES = [
  { name: "app", url: "https://app.directorlink.io", folder: "app" },
  { name: "console", url: "https://console.directorlink.io", folder: "console" },
  { name: "website", url: "https://directorlink.io", folder: "site" },
];
// The short link is a Worker script, not files: it is checked by what it answers.
export const SHORT_LINK = { name: "short link", url: "https://github.directorlink.io", folder: "github-link", paths: ["/", "/releases/latest"] };
// Right after a deploy, Cloudflare may still serve some of the files before it: a difference
// within this time after build.json's built_at is checked again later, not reported.
export const GRACE_MS = 10 * 60 * 1000;
const CLOCK_SLACK_MS = 2 * 60 * 1000;
// How many of main's latest commits that changed a folder a site without a build.json is compared
// with (each costs GitHub API requests when there is no clone).
const HISTORY = { git: 50, github: 5 };
const BUILD_FILE = "build.json";
// What Cloudflare never publishes from an assets directory (wrangler's own defaults).
const ALWAYS_IGNORED = ["/.assetsignore", "/_redirects", "/_headers"];
const COMMIT = /^[0-9a-f]{40}(?:[0-9a-f]{24})?$/;
const REDIRECT_STATUSES = new Set([301, 302, 303, 307, 308]);
// Turned away (a firewall's challenge, say): that says nothing about the files, so it is not a
// difference, only something not checked.
const BLOCKED = new Set([401, 403]);
// A clone whose origin is this repository: on GitHub, or through the short link.
const PROJECT_REMOTE = /^(?:(?:https:\/\/|ssh:\/\/git@|git@)github\.com[:/]DirectorLink\/DirectorLink(?:\.git)?\/?|https:\/\/github\.directorlink\.io\/?)$/i;
const REPORT_TO = "https://github.directorlink.io/security/advisories/new";

const USAGE = `Checks that app.directorlink.io, console.directorlink.io, directorlink.io and
github.directorlink.io serve exactly DirectorLink's public source (ADR-075).

  node scripts/verify_live.mjs [options]

  --wait          when a deploy finished minutes ago, or something could not be
                  reached, wait and check again before answering
  --json FILE     also write the report as JSON to FILE
  --github        compare with the public repository on GitHub, even in a clone
  --no-fetch      in a clone, never run git fetch
  -h, --help      this text

Exit code 0 when everything served is the same as the source, 1 otherwise.
`;

// Something that could not be asked or read: not a difference, only something not checked.
export class Unreachable extends Error {}

const sleep = (ms) => new Promise((done) => setTimeout(done, ms));
const sha256 = (bytes) => createHash("sha256").update(bytes).digest("hex");
const shortCommit = (commit) => String(commit).slice(0, 7);
const host = (url) => new URL(url).host;
const plural = (count, one, many = `${one}s`) => `${count.toLocaleString("en-US")} ${count === 1 ? one : many}`;
// "84 files, their headers and 2 redirects", or "14 files and their headers".
const counted = (site) => (site.redirects
  ? `${plural(site.files, "file")}, their headers and ${plural(site.redirects, "redirect")}`
  : `${plural(site.files, "file")} and their headers`);
const utc = (date) => `${new Date(date).toISOString().slice(0, 16).replace("T", " ")} UTC`;
const urlPath = (path) => `/${path.split("/").map(encodeURIComponent).join("/")}`;

// GET without caches and without following redirects, tried again on a network error, 5xx or
// 429. Anything else is an answer; a server that keeps failing is Unreachable.
export function httpClient({ attempts = 3, delays = [2000, 6000], timeoutMs = 30000 } = {}) {
  return async function get(url, { headers = {} } = {}) {
    let why = "";
    for (let attempt = 1; attempt <= attempts; attempt += 1) {
      try {
        const response = await fetch(url, {
          redirect: "manual",
          headers: { "cache-control": "no-cache", pragma: "no-cache", "user-agent": "DirectorLink verify_live", ...headers },
          signal: AbortSignal.timeout(timeoutMs),
        });
        const body = Buffer.from(await response.arrayBuffer());
        if (response.status < 500 && response.status !== 429) return { status: response.status, headers: response.headers, body };
        why = `answered ${response.status}`;
      } catch (error) {
        why = error?.cause?.code || error?.cause?.message || error?.message || String(error);
      }
      if (attempt < attempts) await sleep(delays[Math.min(attempt - 1, delays.length - 1)]);
    }
    throw new Unreachable(`${url} could not be reached (${why})`);
  };
}

// --- What Cloudflare publishes, and its settings -------------------------------------------------

function escapeRegex(text) {
  return text.replace(/[.*+?^${}()|[\]\\/]/g, "\\$&");
}

function globToRegex(glob) {
  let out = "";
  for (let i = 0; i < glob.length; i += 1) {
    const c = glob[i];
    if (c === "*" && glob[i + 1] === "*") {
      if (glob[i + 2] === "/") {
        out += "(?:.*/)?";
        i += 2;
      } else {
        out += ".*";
        i += 1;
      }
    } else if (c === "*") {
      out += "[^/]*";
    } else if (c === "?") {
      out += "[^/]";
    } else if (c === "[" && glob.indexOf("]", i + 2) > i) {
      const end = glob.indexOf("]", i + 2);
      const set = glob.slice(i + 1, end).replace(/\\/g, "\\\\");
      out += `[${set.startsWith("!") ? `^${set.slice(1)}` : set}]`;
      i = end;
    } else if (c === "\\" && i + 1 < glob.length) {
      i += 1;
      out += escapeRegex(glob[i]);
    } else {
      out += escapeRegex(c);
    }
  }
  return out;
}

// The paths an .assetsignore keeps from being published, read as wrangler reads it (.gitignore
// rules): a pattern without a slash matches at any depth, one with a slash from the folder, a
// trailing slash only folders, ! takes a path back, and nothing comes back from an ignored folder.
export function assetsIgnore(text = "") {
  const rules = [];
  for (let line of [...ALWAYS_IGNORED, ...text.split(/\r?\n/)]) {
    line = line.replace(/(?<!\\)\s+$/, "");
    if (!line || line.startsWith("#")) continue;
    let negate = false;
    if (line.startsWith("!")) {
      negate = true;
      line = line.slice(1);
    } else if (line.startsWith("\\!") || line.startsWith("\\#")) {
      line = line.slice(1);
    }
    let folderOnly = false;
    if (line.endsWith("/")) {
      folderOnly = true;
      line = line.slice(0, -1);
    }
    const anchored = line.includes("/");
    line = line.replace(/^\//, "");
    if (!line) continue;
    rules.push({ negate, folderOnly, regex: new RegExp(`^${anchored ? "" : "(?:.*/)?"}${globToRegex(line)}$`) });
  }
  return (path) => {
    const parts = path.split("/");
    for (let depth = 1; depth <= parts.length; depth += 1) {
      const candidate = parts.slice(0, depth).join("/");
      const isFolder = depth < parts.length;
      let ignored = false;
      for (const rule of rules) {
        if ((!rule.folderOnly || isFolder) && rule.regex.test(candidate)) ignored = !rule.negate;
      }
      if (ignored) return true;
    }
    return false;
  };
}

// A _headers or _redirects path: * matches anything, :name one part of the path.
function pathPattern(pattern) {
  let out = "";
  for (let i = 0; i < pattern.length; i += 1) {
    const placeholder = /^:[A-Za-z]\w*/.exec(pattern.slice(i));
    if (pattern[i] === "*") {
      out += ".*";
    } else if (placeholder) {
      out += "[^/]+";
      i += placeholder[0].length - 1;
    } else {
      out += escapeRegex(pattern[i]);
    }
  }
  return new RegExp(`^${out}$`);
}

// _headers: a path (or an address) on a line of its own, then its headers indented under it;
// "! Name" takes away one an earlier rule set.
export function parseHeaders(text = "") {
  const rules = [];
  let rule = null;
  for (const line of text.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;
    if (!/^\s/.test(line)) {
      rule = { pattern: trimmed, regex: pathPattern(trimmed), set: [], detach: [] };
      rules.push(rule);
    } else if (rule && trimmed.startsWith("!")) {
      rule.detach.push(trimmed.slice(1).trim().toLowerCase());
    } else if (rule && trimmed.indexOf(":") > 0) {
      const colon = trimmed.indexOf(":");
      rule.set.push([trimmed.slice(0, colon).trim().toLowerCase(), trimmed.slice(colon + 1).trim()]);
    }
  }
  return rules;
}

// The headers _headers gives a URL: every rule that matches, in order; the same header from two
// rules is joined with a comma, as Cloudflare does.
export function expectedHeaders(rules, url) {
  const headers = new Map();
  for (const rule of rules) {
    const target = /^https?:\/\//i.test(rule.pattern) ? `${url.origin}${url.pathname}` : url.pathname;
    if (!rule.regex.test(target)) continue;
    for (const name of rule.detach) headers.delete(name);
    for (const [name, value] of rule.set) headers.set(name, headers.has(name) ? `${headers.get(name)}, ${value}` : value);
  }
  return headers;
}

// _redirects: "from to [status]", 302 when no status is given.
export function parseRedirects(text = "") {
  const rules = [];
  for (const line of text.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;
    const [from, to, status = "302"] = trimmed.split(/\s+/);
    if (from && to) rules.push({ from, to, status: Number(status) });
  }
  return rules;
}

// A rule this script can ask about: one fixed path that answers with a redirect (no * or
// :placeholder, no rewrite with 200).
export const askable = (rule) => REDIRECT_STATUSES.has(rule.status) && !/\*|:[A-Za-z]/.test(rule.from) && !/:[A-Za-z]/.test(rule.to.replace(/^https?:/i, ""));

// --- The source: this clone, or the public repository on GitHub ----------------------------------

export class GitSource {
  constructor({ root, main = "refs/remotes/origin/main", fetch = true }) {
    this.root = root;
    this.main = main;
    this.fetch = fetch;
    this.fetched = false;
    this.blobs = new Map();
  }

  // This clone, when its origin is DirectorLink's repository and it has origin/main.
  static async detect(root, options = {}) {
    try {
      const top = (await git(root, ["rev-parse", "--show-toplevel"])).trim();
      const origin = (await git(top, ["remote", "get-url", "origin"])).trim();
      if (!PROJECT_REMOTE.test(origin)) return null;
      await git(top, ["rev-parse", "--verify", "--quiet", "refs/remotes/origin/main^{commit}"]);
      return new GitSource({ root: top, ...options });
    } catch {
      return null;
    }
  }

  describe() {
    return this.main === "refs/remotes/origin/main" ? "this clone of the repository (origin/main)" : `this clone of the repository (${this.main})`;
  }

  async git(args, options) {
    try {
      return await git(this.root, args, options);
    } catch (error) {
      if (error.code === 1 && args[0] === "merge-base") throw error;
      throw new Unreachable(`git ${args[0]} failed: ${String(error.stderr || error.message).trim().split("\n").pop()}`);
    }
  }

  // Origin's main, once: a site may come from a commit newer than this clone. When that fails
  // (offline), what the clone has is used, and a commit it cannot place is not checked.
  async refresh() {
    if (!this.fetch || this.fetched) return;
    this.fetched = true;
    try {
      await this.git(["fetch", "--quiet", "--no-tags", "origin", "+refs/heads/main:refs/remotes/origin/main"]);
    } catch (error) {
      this.fetchError = error.message;
    }
  }

  async has(commit) {
    try {
      await this.git(["cat-file", "-e", `${commit}^{commit}`]);
      return true;
    } catch {
      return false;
    }
  }

  async isOnMain(commit) {
    try {
      await this.git(["merge-base", "--is-ancestor", commit, this.main]);
      return true;
    } catch (error) {
      if (error.code === 1) return false;
      throw error;
    }
  }

  async onMain(commit) {
    if ((await this.has(commit)) && (await this.isOnMain(commit))) return true;
    if (this.fetch && !this.fetched) {
      await this.refresh();
      return this.onMain(commit);
    }
    if (!this.fetch && !(await this.has(commit))) {
      throw new Unreachable(`commit ${shortCommit(commit)} is not in this clone: run git fetch origin, or leave out --no-fetch`);
    }
    if (this.fetchError) {
      throw new Unreachable(`commit ${shortCommit(commit)} is not on this clone's main, and ${this.fetchError}`);
    }
    // origin's main was just fetched: a commit that is not on it is not on main.
    return (await this.has(commit)) && (await this.isOnMain(commit));
  }

  async history(folder, limit = HISTORY.git) {
    await this.refresh();
    const out = await this.git(["log", `-n${limit}`, "--format=%H", this.main, "--", `${folder}/`]);
    return out.split("\n").filter(Boolean);
  }

  async mainCommit() {
    return (await this.git(["rev-parse", `${this.main}^{commit}`])).trim();
  }

  // Where bytes a site serves are in this clone, on any branch: "commit 6aec92d (origin/dev/x),
  // which is not on main". Null when they are in no commit here (or the clone is SHA-256).
  whereIs(bytes) {
    const id = createHash("sha1").update(`blob ${bytes.length}\0`).update(bytes).digest("hex");
    this.found ??= new Map();
    if (!this.found.has(id)) this.found.set(id, this.locate(id));
    return this.found.get(id);
  }

  async locate(id) {
    try {
      await this.git(["cat-file", "-e", id]);
      // The first commit that has them (--find-object also lists the one that changed them).
      const commit = (await this.git(["log", "--all", "--reverse", "--format=%H", `--find-object=${id}`])).split("\n")[0].trim();
      if (!commit) return null;
      if (await this.isOnMain(commit)) return `commit ${shortCommit(commit)} on main`;
      const refs = (await this.git(["for-each-ref", "--contains", commit, "--format=%(refname:short)", "refs/heads", "refs/remotes"])).split("\n").filter(Boolean);
      return `commit ${shortCommit(commit)}${refs.length ? ` (${refs.slice(0, 3).join(", ")})` : ""}, which is not on main`;
    } catch {
      return null;
    }
  }

  // The folder's files at a commit: [{ path (inside the folder), id (Git's blob id) }].
  async tree(commit, folder) {
    const out = await this.git(["ls-tree", "-r", "-z", commit, "--", `${folder}/`]);
    return out.split("\0").filter(Boolean).flatMap((line) => {
      const tab = line.indexOf("\t");
      const [mode, type, id] = line.slice(0, tab).split(" ");
      const path = line.slice(tab + 1);
      return type === "blob" && mode !== "120000" ? [{ path: path.slice(folder.length + 1), id }] : [];
    });
  }

  blob(commit, path, id) {
    const key = id ?? `${commit}:${path}`;
    if (!this.blobs.has(key)) this.blobs.set(key, this.git(["cat-file", "blob", key], { binary: true }));
    return this.blobs.get(key);
  }
}

async function git(cwd, args, { binary = false } = {}) {
  const { stdout } = await execFileAsync("git", args, { cwd, encoding: binary ? "buffer" : "utf8", maxBuffer: 256 * 1024 * 1024, windowsHide: true });
  return stdout;
}

export class GitHubSource {
  constructor({ api = "https://api.github.com", raw = "https://raw.githubusercontent.com", repository = REPOSITORY, get = httpClient(), token } = {}) {
    this.api = api;
    this.raw = raw;
    this.repository = repository;
    this.get = get;
    this.token = token;
    this.trees = new Map();
    this.blobs = new Map();
  }

  describe() {
    return "the public repository on GitHub (https://github.directorlink.io)";
  }

  async json(path) {
    const headers = { accept: "application/vnd.github+json", ...(this.token ? { authorization: `Bearer ${this.token}` } : {}) };
    const answer = await this.get(new URL(`/repos/${this.repository}${path}`, this.api), { headers });
    if (answer.status === 404 || answer.status === 422) return null;
    if (answer.status !== 200) {
      const limit = answer.status === 403 ? ": its limit on requests without a token, try again in an hour or set GITHUB_TOKEN" : "";
      throw new Unreachable(`GitHub's API answered ${answer.status}${limit}`);
    }
    return JSON.parse(answer.body.toString("utf8"));
  }

  async onMain(commit) {
    const comparison = await this.json(`/compare/${commit}...main?per_page=1`);
    return comparison?.status === "ahead" || comparison?.status === "identical";
  }

  async history(folder, limit = HISTORY.github) {
    const commits = await this.json(`/commits?sha=main&path=${encodeURIComponent(folder)}&per_page=${limit}`);
    return (commits ?? []).map((commit) => commit.sha);
  }

  async mainCommit() {
    const branch = await this.json("/branches/main");
    if (!branch) throw new Unreachable("GitHub has no main branch for this repository");
    return branch.commit.sha;
  }

  async tree(commit, folder) {
    if (!this.trees.has(commit)) this.trees.set(commit, this.json(`/git/trees/${commit}?recursive=1`));
    const tree = await this.trees.get(commit);
    if (!tree) throw new Unreachable(`GitHub has no commit ${shortCommit(commit)}`);
    if (tree.truncated) throw new Unreachable("GitHub's list of the files came back cut short");
    return tree.tree
      .filter((entry) => entry.type === "blob" && entry.mode !== "120000" && entry.path.startsWith(`${folder}/`))
      .map((entry) => ({ path: entry.path.slice(folder.length + 1), id: entry.sha }));
  }

  blob(commit, path, id) {
    const key = id ?? `${commit}:${path}`;
    if (!this.blobs.has(key)) {
      this.blobs.set(key, (async () => {
        const answer = await this.get(new URL(`/${this.repository}/${commit}${urlPath(path)}`, this.raw));
        if (answer.status !== 200) throw new Unreachable(`GitHub answered ${answer.status} for ${path}`);
        return answer.body;
      })());
    }
    return this.blobs.get(key);
  }
}

// --- Comparing -----------------------------------------------------------------------------------

// A path as the site serves it: redirects within the site are followed (Cloudflare serves
// /privacy.html at /privacy and /drivers/index.html at /drivers/), one elsewhere is the answer.
async function servedFile(get, base, path) {
  let url = new URL(path, base);
  for (let hop = 0; ; hop += 1) {
    const answer = await get(url);
    if (!REDIRECT_STATUSES.has(answer.status)) return { ...answer, url };
    const target = new URL(answer.headers.get("location") ?? "", url);
    if (target.origin !== url.origin || hop >= 3) return { status: answer.status, redirectedTo: target.href };
    url = target;
  }
}

async function eachLimited(items, limit, work) {
  let next = 0;
  const workers = Array.from({ length: Math.min(limit, items.length) }, async () => {
    while (next < items.length) {
      const item = items[next];
      next += 1;
      await work(item);
    }
  });
  await Promise.all(workers);
}

function memo(get) {
  const answers = new Map();
  return (url) => {
    const key = String(url);
    if (!answers.has(key)) answers.set(key, get(url));
    return answers.get(key);
  };
}

const problem = (kind, path, message, detail = {}) => ({ kind, path, message, ...detail });

// One site against one commit: every file it publishes, their headers, and its redirects.
async function compare(site, commit, get, { source, concurrency }) {
  const result = { commit, files: 0, redirects: 0, problems: [], unreachable: [] };
  const tree = await source.tree(commit, site.folder);
  const entries = new Map(tree.map((entry) => [entry.path, entry]));
  const setting = async (name) => {
    const entry = entries.get(name);
    return entry ? (await source.blob(commit, `${site.folder}/${name}`, entry.id)).toString("utf8") : "";
  };
  const ignored = assetsIgnore(await setting(".assetsignore"));
  const headerRules = parseHeaders(await setting("_headers"));
  const redirectRules = parseRedirects(await setting("_redirects")).filter(askable);
  const files = tree.filter((entry) => entry.path !== BUILD_FILE && !ignored(entry.path)).sort((a, b) => a.path.localeCompare(b.path));
  const wrongHeaders = new Map();
  let located = 0;

  await eachLimited(files, concurrency, async (entry) => {
    const path = urlPath(entry.path);
    let answer;
    try {
      answer = await servedFile(get, site.url, path);
    } catch (error) {
      if (!(error instanceof Unreachable)) throw error;
      result.unreachable.push(path);
      return;
    }
    if (BLOCKED.has(answer.status)) {
      result.unreachable.push(path);
      return;
    }
    result.files += 1;
    if (answer.redirectedTo) {
      result.problems.push(problem("redirected", path, `${path} redirects to ${answer.redirectedTo} (${answer.status}) instead of serving the file`));
      return;
    }
    if (answer.status === 404) {
      result.problems.push(problem("missing", path, `${path} is not served (404), but the source has it`));
      return;
    }
    if (answer.status !== 200) {
      result.problems.push(problem("status", path, `${path} answered ${answer.status} instead of the file`));
      return;
    }
    const expected = await source.blob(commit, `${site.folder}/${entry.path}`, entry.id);
    const [servedHash, sourceHash] = [sha256(answer.body), sha256(expected)];
    if (servedHash !== sourceHash) {
      // Where those bytes come from, if this clone has them (for the first ten such files).
      located += 1;
      const elsewhere = source.whereIs && located <= 10 ? await source.whereIs(answer.body) : null;
      result.problems.push(problem("changed", path,
        `${path} is not the file in the source: served ${plural(answer.body.length, "byte")}, SHA-256 ${servedHash.slice(0, 16)}…; the source has ${plural(expected.length, "byte")}, SHA-256 ${sourceHash.slice(0, 16)}…${elsewhere ? `; the served bytes are the file of ${elsewhere}` : ""}`,
        { served_sha256: servedHash, source_sha256: sourceHash, ...(elsewhere ? { served_from: elsewhere } : {}) }));
    }
    for (const [name, value] of expectedHeaders(headerRules, answer.url)) {
      const actual = answer.headers.get(name);
      if (actual === value) continue;
      const key = `${name}\n${actual}\n${value}`;
      if (!wrongHeaders.has(key)) wrongHeaders.set(key, { name, actual, value, paths: [] });
      wrongHeaders.get(key).paths.push(path);
    }
  });

  for (const { name, actual, value, paths } of wrongHeaders.values()) {
    paths.sort();
    const where = paths.length === 1 ? paths[0] : `${plural(paths.length, "file")} (${paths[0]} and others)`;
    result.problems.push(problem("header", paths[0],
      `the ${name} header of ${where} is ${actual === null ? "missing" : `"${actual}"`}; _headers says "${value}"`,
      { header: name, files: paths.length }));
  }

  for (const rule of redirectRules) {
    let answer;
    try {
      answer = await get(new URL(rule.from, site.url));
    } catch (error) {
      if (!(error instanceof Unreachable)) throw error;
      result.unreachable.push(rule.from);
      continue;
    }
    if (BLOCKED.has(answer.status)) {
      result.unreachable.push(rule.from);
      continue;
    }
    result.redirects += 1;
    const location = answer.headers.get("location");
    const target = new URL(rule.to, site.url).href;
    if (answer.status !== rule.status || location === null || new URL(location, site.url).href !== target) {
      const got = REDIRECT_STATUSES.has(answer.status) ? `${answer.status} to ${location}` : `${answer.status}, no redirect`;
      result.problems.push(problem("redirect", rule.from, `${rule.from} answers ${got}; _redirects says ${rule.status} to ${rule.to}`));
    }
  }
  result.problems.sort((a, b) => a.message.localeCompare(b.message));
  result.unreachable.sort();
  return result;
}

const withinGrace = (builtAt, now) => {
  const at = Date.parse(builtAt ?? "");
  return Number.isFinite(at) && now - at < GRACE_MS && at - now < CLOCK_SLACK_MS;
};

async function verifySite(site, { source, get, now, concurrency }) {
  const result = {
    name: site.name, url: site.url, folder: site.folder, status: "equal", build_json: false,
    commit: null, built_at: null, files: 0, redirects: 0, problems: [], unreachable: [], notes: [],
  };
  const cached = memo(get);
  const incomplete = (why) => {
    result.status = "incomplete";
    result.notes.push(why);
    return result;
  };

  let stamp;
  try {
    stamp = await cached(new URL(`/${BUILD_FILE}`, site.url));
  } catch (error) {
    if (error instanceof Unreachable) return incomplete(error.message);
    throw error;
  }

  let candidates;
  try {
    if (stamp.status === 200) {
      let build = null;
      try {
        build = JSON.parse(stamp.body.toString("utf8"));
      } catch {
        // reported below
      }
      if (!build || typeof build.commit !== "string" || !COMMIT.test(build.commit)) {
        result.status = "differs";
        result.problems.push(problem("build-json", `/${BUILD_FILE}`, `/${BUILD_FILE} is not what deploy.yml writes (${JSON.stringify(stamp.body.toString("utf8").slice(0, 120))})`));
        return result;
      }
      result.build_json = true;
      result.commit = build.commit;
      result.built_at = typeof build.built_at === "string" ? build.built_at : null;
      if (!(await source.onMain(build.commit))) {
        result.status = "differs";
        result.problems.push(problem("not-on-main", `/${BUILD_FILE}`, `/${BUILD_FILE} says the site was built from commit ${build.commit}, which is not on main`));
        return result;
      }
      candidates = [build.commit];
    } else if (BLOCKED.has(stamp.status)) {
      return incomplete(`${site.url}/${BUILD_FILE} answered ${stamp.status}: this check was turned away`);
    } else if (stamp.status === 404) {
      result.notes.push("not deployed with a build.json yet");
      candidates = await source.history(site.folder);
      if (!candidates.length) {
        result.status = "differs";
        result.problems.push(problem("no-source", null, `main has no ${site.folder}/ to compare with`));
        return result;
      }
    } else {
      result.status = "differs";
      const where = REDIRECT_STATUSES.has(stamp.status) ? ` to ${stamp.headers.get("location")}` : "";
      result.problems.push(problem("build-json", `/${BUILD_FILE}`, `/${BUILD_FILE} answered ${stamp.status}${where}`));
      return result;
    }

    // With a build.json, its commit; without, main's latest commits that changed the folder,
    // newest first, until one is the same (else the one with the fewest differences).
    let best = null;
    for (const commit of candidates) {
      const comparison = await compare(site, commit, cached, { source, concurrency });
      if (!best || comparison.problems.length < best.problems.length) best = comparison;
      if (!comparison.problems.length) break;
    }
    Object.assign(result, { commit: best.commit, files: best.files, redirects: best.redirects, problems: best.problems, unreachable: best.unreachable });
    if (!result.build_json) result.newer = candidates.indexOf(best.commit);
  } catch (error) {
    if (error instanceof Unreachable) return incomplete(error.message);
    throw error;
  }

  if (result.problems.length) {
    result.status = result.build_json && withinGrace(result.built_at, now()) ? "pending" : "differs";
  } else if (result.unreachable.length) {
    result.status = "incomplete";
    result.notes.push(`${plural(result.unreachable.length, "path")} could not be reached: ${result.unreachable.slice(0, 5).join(", ")}${result.unreachable.length > 5 ? ", …" : ""}`);
  }
  return result;
}

async function verifyShortLink(link, sites, { source, get, now }) {
  const result = {
    name: link.name, url: link.url, folder: link.folder, status: "equal", build_json: false,
    commit: null, built_at: null, files: 0, redirects: 0, problems: [], unreachable: [], notes: [],
  };
  // deploy.yml deploys the four folders together, from one commit: the website's tells which.
  const website = sites.find((site) => site.folder === "site" && site.commit && site.status !== "differs");
  try {
    result.commit = website?.commit ?? (await source.mainCommit());
    result.built_at = website?.built_at ?? null;
    const tree = await source.tree(result.commit, link.folder);
    const entry = tree.find((file) => file.path === "worker.js");
    const worker = entry ? (await source.blob(result.commit, `${link.folder}/worker.js`, entry.id)).toString("utf8") : "";
    const repository = /const REPOSITORY = "([^"]+)";/.exec(worker)?.[1];
    const status = Number(/Response\.redirect\([^;]*,\s*(\d{3})\s*\)/.exec(worker)?.[1] ?? 0);
    if (!repository || !REDIRECT_STATUSES.has(status)) {
      result.status = "incomplete";
      result.notes.push(`${link.folder}/worker.js at ${shortCommit(result.commit)} no longer says plainly where it leads: not checked`);
      return result;
    }
    for (const path of link.paths) {
      let answer;
      try {
        answer = await get(new URL(path, link.url));
      } catch (error) {
        if (!(error instanceof Unreachable)) throw error;
        result.unreachable.push(path);
        continue;
      }
      if (BLOCKED.has(answer.status)) {
        result.unreachable.push(path);
        continue;
      }
      result.redirects += 1;
      const expected = repository + (path === "/" ? "" : path);
      const location = answer.headers.get("location");
      if (answer.status !== status || location !== expected) {
        const got = REDIRECT_STATUSES.has(answer.status) ? `${answer.status} to ${location}` : `${answer.status}, no redirect`;
        result.problems.push(problem("redirect", path, `${path} answers ${got}; ${link.folder}/worker.js says ${status} to ${expected}`));
      }
    }
  } catch (error) {
    if (!(error instanceof Unreachable)) throw error;
    result.status = "incomplete";
    result.notes.push(error.message);
    return result;
  }
  if (result.problems.length) result.status = website?.build_json && withinGrace(result.built_at, now()) ? "pending" : "differs";
  else if (result.unreachable.length) {
    result.status = "incomplete";
    result.notes.push(`${result.unreachable.join(", ")} could not be reached`);
  }
  return result;
}

const RANK = { equal: 0, incomplete: 1, pending: 2, differs: 3 };

export async function verify({ source, sites = SITES, shortLink = SHORT_LINK, get = httpClient(), now = Date.now, concurrency = 8 } = {}) {
  const checkedAt = now();
  const results = [];
  for (const site of sites) results.push(await verifySite(site, { source, get, now, concurrency }));
  if (shortLink) results.push(await verifyShortLink(shortLink, results, { source, get, now }));
  const result = results.reduce((worst, site) => (RANK[site.status] > RANK[worst] ? site.status : worst), "equal");
  const lines = results.flatMap((site) => site.problems.map((found) => `${site.url} ${found.kind} ${found.message}`)).sort();
  const pending = results.filter((site) => site.status === "pending").map((site) => Date.parse(site.built_at) + GRACE_MS);
  const report = {
    result,
    checked_at: new Date(checkedAt).toISOString(),
    source: source.describe(),
    fingerprint: lines.length ? sha256(lines.join("\n")).slice(0, 16) : null,
    settled_at: pending.length ? new Date(Math.max(...pending)).toISOString() : null,
    sites: results,
  };
  report.text = formatReport(report);
  return report;
}

// --- The report ----------------------------------------------------------------------------------

function describeSite(site) {
  const lines = [];
  const name = host(site.url);
  const deployed = site.build_json
    ? `Built from commit ${shortCommit(site.commit)} on main${site.built_at ? ` at ${utc(site.built_at)}` : ""}`
    : null;
  if (site.folder === "github-link") {
    if (site.status === "equal") {
      lines.push(`${name}: the same as the source.`);
      lines.push(`  It leads to the repository as ${site.folder}/worker.js says at commit ${shortCommit(site.commit)}: ${plural(site.redirects, "address", "addresses")} checked.`);
    } else if (site.status === "incomplete") {
      lines.push(`${name}: could not be checked completely; nothing found differs.`);
    } else {
      lines.push(`${name}: ${site.status === "pending" ? "deployed minutes ago, still settling" : "DIFFERENT from the source"}.`);
    }
  } else if (site.status === "equal" && site.build_json) {
    lines.push(`${name}: the same as the source.`);
    lines.push(`  ${deployed}: ${counted(site)} are the same.`);
  } else if (site.status === "equal") {
    lines.push(`${name}: not deployed with a build.json yet, and the same as the source.`);
    const newer = site.newer ? `; main has ${plural(site.newer, "newer change")} to ${site.folder}/ not deployed yet` : `, the latest change to ${site.folder}/ on main`;
    lines.push(`  Its ${counted(site)} are those of commit ${shortCommit(site.commit)}${newer}.`);
  } else if (site.status === "pending") {
    lines.push(`${name}: deployed less than ${GRACE_MS / 60000} minutes ago, still settling.`);
    lines.push(`  ${deployed}. These differences are checked again after ${utc(Date.parse(site.built_at) + GRACE_MS)}:`);
  } else if (site.status === "differs") {
    lines.push(`${name}: DIFFERENT from the source.`);
    if (site.build_json && site.problems.every((found) => found.kind !== "not-on-main")) lines.push(`  ${deployed}:`);
    else if (!site.build_json && site.commit) lines.push(`  Not deployed with a build.json, and none of main's latest commits that changed ${site.folder}/ is what it serves; compared with commit ${shortCommit(site.commit)}:`);
  } else {
    lines.push(`${name}: could not be checked completely; nothing found differs.`);
  }
  for (const found of site.problems) lines.push(`  - ${found.message}`);
  for (const note of site.notes) {
    if (note !== "not deployed with a build.json yet") lines.push(`  (${note})`);
  }
  return lines;
}

export function formatReport(report) {
  const lines = [`Checked ${utc(report.checked_at)} against ${report.source}.`, ""];
  for (const site of report.sites) lines.push(...describeSite(site));
  lines.push("");
  if (report.result === "equal") {
    lines.push("Result: everything served is the same as the public source.");
  } else if (report.result === "differs") {
    lines.push("Result: what is served DIFFERS from the public source (above).");
    lines.push(`If you did not expect this, please report it privately: ${REPORT_TO}`);
  } else if (report.result === "pending") {
    lines.push(`Result: a deploy finished minutes ago and may still be settling. Check again after ${utc(report.settled_at)}.`);
  } else {
    lines.push("Result: not everything could be checked (above); nothing found differs so far. Try again later.");
  }
  return `${lines.join("\n")}\n`;
}

// --- Command line --------------------------------------------------------------------------------

export async function main(argv = process.argv.slice(2), options = {}) {
  const { out = process.stdout, err = process.stderr, env = process.env, root = ROOT, wait = sleep, now = Date.now } = options;
  let args;
  try {
    args = parseArgs({
      args: argv,
      options: {
        wait: { type: "boolean" },
        json: { type: "string" },
        github: { type: "boolean" },
        "no-fetch": { type: "boolean" },
        help: { type: "boolean", short: "h" },
      },
    }).values;
  } catch (error) {
    err.write(`${error.message}\n\n${USAGE}`);
    return 1;
  }
  if (args.help) {
    out.write(USAGE);
    return 0;
  }
  const get = options.get ?? httpClient();
  const source = options.source
    ?? ((!args.github && (await GitSource.detect(root, { fetch: !args["no-fetch"] }))) || new GitHubSource({ get, token: env.GITHUB_TOKEN }));
  const check = () => verify({ source, get, now, sites: options.sites, shortLink: options.shortLink });

  let report = await check();
  for (let round = 0; args.wait && round < 2 && (report.result === "pending" || report.result === "incomplete"); round += 1) {
    const ms = report.result === "pending"
      ? Math.min(Math.max(Date.parse(report.settled_at) - now(), 0) + 30_000, GRACE_MS + 60_000)
      : 60_000;
    err.write(`${report.result === "pending" ? "A deploy finished minutes ago" : "Something could not be reached"}: checking again in ${Math.ceil(ms / 1000)} s.\n`);
    await wait(ms);
    report = await check();
  }
  out.write(report.text);
  if (args.json) writeFileSync(args.json, `${JSON.stringify(report, null, 2)}\n`);
  return report.result === "equal" ? 0 : 1;
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  process.exitCode = await main();
}
