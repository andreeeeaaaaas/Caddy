// Files a report from Caddy's Help › Report an Issue… as a GitHub issue, so
// people without GitHub accounts can report problems. The token stays here.
//
// Environment:
//   GITHUB_TOKEN  fine-grained token, this repository only, Issues: read and write
//   GITHUB_REPO   owner/name, e.g. andreeeeaaaaas/Caddy
//   CADDY_KEY     optional; when set, requests must send it as X-Caddy-Key

const limits = { title: 120, description: 8000, contact: 200, field: 200 };

export default async (request) => {
    if (request.method !== "POST") return reply(405, "Use POST.");

    const key = process.env.CADDY_KEY;
    if (key && request.headers.get("x-caddy-key") !== key) return reply(401, "Not allowed.");

    const token = process.env.GITHUB_TOKEN;
    const repo = process.env.GITHUB_REPO;
    if (!token || !repo) return reply(500, "The relay isn't set up.");

    let report;
    try {
        report = await request.json();
    } catch {
        return reply(400, "Send JSON.");
    }

    const title = text(report.title, limits.title);
    const description = text(report.description, limits.description);
    if (!title || !description) return reply(400, "A title and a description are needed.");

    const system = report.system ?? {};
    const lines = [
        description,
        "",
        "### Reported by",
        text(report.contact, limits.contact) || "Not given",
        "",
        "### System",
        `- Caddy ${text(system.version, limits.field) || "?"} (${text(system.build, limits.field) || "?"})`,
        `- ${text(system.os, limits.field) || "macOS ?"}`,
        `- ${text(system.model, limits.field) || "Mac ?"}`,
        "",
        "_Sent from Caddy's Report an Issue._",
    ];

    const response = await fetch(`https://api.github.com/repos/${repo}/issues`, {
        method: "POST",
        headers: {
            Accept: "application/vnd.github+json",
            Authorization: `Bearer ${token}`,
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "caddy-issue-relay",
        },
        body: JSON.stringify({ title, body: lines.join("\n"), labels: ["reported in app"] }),
    });

    if (!response.ok) {
        console.error("GitHub refused the issue", response.status, await response.text());
        return reply(502, "GitHub didn't take the report.");
    }
    const issue = await response.json();
    return Response.json({ number: issue.number });
};

/// A string trimmed and cut to a length, or "" for anything else.
function text(value, length) {
    return typeof value === "string" ? value.trim().slice(0, length) : "";
}

function reply(status, message) {
    return Response.json({ error: message }, { status });
}

export const config = {
    path: "/api/report",
    // A few reports a minute from one address is plenty.
    rateLimit: { windowLimit: 5, windowSize: 60, aggregateBy: ["ip", "domain"] },
};
