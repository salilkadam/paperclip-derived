import { createRequire } from "node:module";
import { pathToFileURL } from "node:url";
import fs from "node:fs";
const require = createRequire(import.meta.url);
const Negotiator = require("./node_modules/negotiator/index.js");

const guardPath = process.argv[2];
const mod = await import(pathToFileURL(guardPath).href);
const factory = mod.privateHostnameGuard || Object.values(mod).find(v => typeof v === "function");
if (typeof factory !== "function") { console.log("FAIL: no exported guard factory:", Object.keys(mod)); process.exit(1); }

// Mirror the compiled server wiring defaults: guard enabled, bind 0.0.0.0,
// no extra allowed hostnames (the cluster/pod-IP Host must be guarded).
const middleware = factory({ enabled: true, allowedHostnames: [], bindHost: "0.0.0.0" });

const cases = [
  ["/health", "application/json", "next"],
  ["/api/health", "application/json", "next"],
  ["/api/issues", "application/json", "403"],
  ["/issues", "text/html", "403"],
  ["/dashboard", "*/*", "403"],
];
let fail = 0;
for (const [path, accept, expected] of cases) {
  const headers = { host: "10.42.0.1", accept };
  const req = {
    path,
    headers,
    header(n) { return headers[String(n).toLowerCase()]; },
    accepts(...t) { const n = new Negotiator({ headers }); return t.length ? n.mediaTypes(t)[0] : n.mediaTypes(); },
  };
  let result = "next";
  const res = {
    _c: 0,
    status(c) { this._c = c; return this; },
    json() { result = String(this._c); return this; },
    type() { return this; },
    send() { result = String(this._c); return this; },
    end() { result = String(this._c); return this; },
    setHeader() { return this; },
    getHeader() {},
    redirect() { result = "redirect"; return this; },
  };
  try { middleware(req, res, () => {}); } catch (e) { result = "error:" + e.message; }
  const ok = result === expected;
  if (!ok) fail++;
  console.log(`${ok ? "PASS" : "FAIL"} ${path} (Accept: ${accept}) Host=10.42.0.1 -> ${result} (expect ${expected})`);
}
console.log(fail ? `GUARD: FAIL (${fail})` : "GUARD: PASS");
process.exit(fail ? 1 : 0);
