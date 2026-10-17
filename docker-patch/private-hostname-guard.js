function isLoopbackHostname(hostname) {
    const normalized = hostname.trim().toLowerCase();
    return normalized === "localhost" || normalized === "127.0.0.1" || normalized === "::1";
}
function extractHostname(req) {
    const forwardedHost = req.header("x-forwarded-host")?.split(",")[0]?.trim();
    const hostHeader = req.header("host")?.trim();
    const raw = forwardedHost || hostHeader;
    if (!raw)
        return null;
    try {
        return new URL(`http://${raw}`).hostname.trim().toLowerCase();
    }
    catch {
        return raw.trim().toLowerCase();
    }
}
function normalizeAllowedHostnames(values) {
    const unique = new Set();
    for (const value of values) {
        const trimmed = value.trim().toLowerCase();
        if (!trimmed)
            continue;
        unique.add(trimmed);
    }
    return Array.from(unique);
}
export function resolvePrivateHostnameAllowSet(opts) {
    const configuredAllow = normalizeAllowedHostnames(opts.allowedHostnames);
    const bindHost = opts.bindHost.trim().toLowerCase();
    const allowSet = new Set(configuredAllow);
    if (bindHost && bindHost !== "0.0.0.0") {
        allowSet.add(bindHost);
    }
    allowSet.add("localhost");
    allowSet.add("127.0.0.1");
    allowSet.add("::1");
    return allowSet;
}
// The hostname comes from the request Host header, so an unauthenticated
// requester controls it. Never put that value into the guidance command. An
// operator or an agent can paste the guidance into a shell, and that outer
// shell evaluates a backtick, `$( )`, or `$NAME` span in the host before any
// CLI receives argv. A direct-exec form such as `npx` does not stop the
// outer shell. Emit a static `<host>` placeholder and do not echo the raw request
// value. The operator supplies the real hostname.
const BLOCKED_HOSTNAME_MESSAGE = "This hostname is not allowed for this Paperclip instance. " +
    "If you want to allow a hostname, run npx paperclipai allowed-hostname <host>.";
export function privateHostnameGuard(opts) {
    if (!opts.enabled) {
        return (_req, _res, next) => next();
    }
    const allowSet = resolvePrivateHostnameAllowSet({
        allowedHostnames: opts.allowedHostnames,
        bindHost: opts.bindHost,
    });
    return (req, res, next) => {
        // Skip the hostname guard for health check endpoints so Kubernetes
        // liveness/readiness probes (which hit the pod's cluster IP) can pass.
        if (req.path === "/health" || req.path === "/api/health") {
            return next();
        }
        const hostname = extractHostname(req);
        const wantsJson = req.path.startsWith("/api") || req.accepts(["json", "html", "text"]) === "json";
        if (!hostname) {
            const error = "Missing Host header. If you want to allow a hostname, run npx paperclipai allowed-hostname <host>.";
            if (wantsJson) {
                res.status(403).json({ error });
            }
            else {
                res.status(403).type("text/plain").send(error);
            }
            return;
        }
        if (isLoopbackHostname(hostname) || allowSet.has(hostname)) {
            next();
            return;
        }
        const error = BLOCKED_HOSTNAME_MESSAGE;
        if (wantsJson) {
            res.status(403).json({ error });
        }
        else {
            res.status(403).type("text/plain").send(error);
        }
    };
}
//# sourceMappingURL=private-hostname-guard.js.map
