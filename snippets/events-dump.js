// events-dump.js — operator-mediated dump tool for claude.ai/v1/sessions/<id>/events.
//
// Origin: coo-labs/coo-console#28 (events-API discovery during briefing-039 Phase 5).
// v2 revision: real-world ground truth from 2026-06-05 probe (coo-labs/coo-memory#1148).
//
// ## Why the rewrite
//
// The v1 snippet (coo-labs/coo-harness#414) shipped against the briefing-039
// description of the endpoint, which was either stale or never fully matched.
// Three things were wrong:
//   1. Missing CCR beta headers — claude.ai's gateway 404s the route without
//      `anthropic-beta: ccr-byoc-2025-07-29` + `anthropic-client-feature: ccr`.
//   2. Wrong response key — events arrive in `body.data`, not `body.events`.
//   3. Wrong pagination cursor — the API returns `last_id` / `has_more` per
//      Anthropic standard List API; v1 used an invented `after_id` derived from
//      the trailing event's own id, which produced a 400 "Unknown query
//      parameter 'after_id'" on the un-CCR-gated fallback route.
//
// The header gate also means org_uuid is operator-specific (it changes per
// account), so the caller passes it as an argument — auto-detection via
// `/v1/organizations` would work in a logged-in claude.ai context, but
// requiring it explicit keeps the surface auditable.
//
// ## Usage
//
//   1. Open claude.ai in a logged-in browser tab.
//   2. Open DevTools (F12) → Console.
//   3. Paste this entire file's contents.
//   4. Get your org_uuid: open any session in claude.ai, DevTools Network tab,
//      pick any /v1/sessions/<sid>/events request, copy the `x-organization-uuid`
//      request header value.
//   5. Call dumpEvents(['session_01abc...', ...], '<org_uuid>') with the
//      session IDs + your org_uuid.
//   6. Save the returned blob — see dumpEventsToFile() below for the one-call form.
//   7. scp the file to the container for ingestion (per Decision 5 in
//      briefing-039: no pre-signed PUT — leaked URL is a corpus-poisoning
//      attack surface).
//
// ## Batch sizing
//
// Cookie-expiry bounded; plan ~80 sessions per browser invocation. For the
// ~294-session dark-mass backfill, plan on ~4 batches. Throttle 250ms between
// page requests — operator-courtesy, not a rate-limit requirement (claude.ai
// has no documented rate limit on this endpoint at the time of v2).
//
// ## Schema-drift escape hatch
//
// If the gateway returns 4xx for an `after_id` cursor (the standard Anthropic
// List API cursor name), the cursor field name has drifted. Check the response
// body keys after page 0: this snippet expects `last_id` + `has_more`. If
// either is missing or differently named, the API has shifted and a new probe
// is required before re-running the backfill.

const _PARSER_VERSION = 2;  // bumped from 1 — schema changed (data not events,
                            // CCR header gate, after_id cursor format)

const _CCR_HEADERS = {
  'anthropic-beta': 'ccr-byoc-2025-07-29',
  'anthropic-client-feature': 'ccr',
  'anthropic-client-platform': 'web_claude_ai',
  'anthropic-version': '2023-06-01',
};

async function dumpEvents(sessionIds, orgUuid, options = {}) {
  if (!orgUuid || typeof orgUuid !== 'string') {
    throw new Error('orgUuid is required (string); see usage comment in events-dump.js');
  }
  if (!Array.isArray(sessionIds) || sessionIds.length === 0) {
    throw new Error('sessionIds must be a non-empty array of session_01... ids');
  }
  const {pageSize = 500, throttleMs = 250, onProgress = null} = options;
  const headers = {..._CCR_HEADERS, 'x-organization-uuid': orgUuid};
  const out = {
    parser_version: _PARSER_VERSION,
    dumped_at: new Date().toISOString(),
    org_uuid: orgUuid,
    sessions: {},
    errors: [],
  };

  for (let i = 0; i < sessionIds.length; i++) {
    const sid = sessionIds[i];
    if (onProgress) onProgress({sid, index: i, total: sessionIds.length});

    const sessionEvents = [];
    let afterId = null;
    let pageNum = 0;

    while (true) {
      const url = afterId
        ? `/v1/sessions/${sid}/events?limit=${pageSize}&after_id=${afterId}`
        : `/v1/sessions/${sid}/events?limit=${pageSize}`;
      let response;
      try {
        response = await fetch(url, {credentials: 'include', headers});
      } catch (e) {
        out.errors.push({sid, page: pageNum, error: `fetch failed: ${e.message}`});
        break;
      }
      if (!response.ok) {
        const body = await response.text().catch(() => '<no body>');
        out.errors.push({
          sid, page: pageNum,
          error: `HTTP ${response.status} ${response.statusText}: ${body.slice(0, 300)}`,
        });
        break;
      }
      let body;
      try {
        body = await response.json();
      } catch (e) {
        out.errors.push({sid, page: pageNum, error: `JSON parse failed: ${e.message}`});
        break;
      }
      if (!Array.isArray(body.data)) {
        out.errors.push({
          sid, page: pageNum,
          error: `schema drift — expected body.data array, got keys=[${Object.keys(body).join(',')}]`,
        });
        break;
      }
      sessionEvents.push(...body.data);
      if (!body.has_more) break;
      if (!body.last_id) {
        out.errors.push({
          sid, page: pageNum,
          error: 'schema drift — has_more=true but no last_id for next cursor',
        });
        break;
      }
      afterId = body.last_id;
      pageNum += 1;
      if (throttleMs > 0) await new Promise(r => setTimeout(r, throttleMs));
    }

    out.sessions[sid] = sessionEvents;
  }

  return out;
}

// Convenience: dump-and-download in one call. For interactive use.
async function dumpEventsToFile(sessionIds, orgUuid, filename = 'events.json', options = {}) {
  const data = await dumpEvents(sessionIds, orgUuid, {
    ...options,
    onProgress: ({sid, index, total}) => console.log(`[${index + 1}/${total}] ${sid}`),
  });
  const blob = new Blob([JSON.stringify(data, null, 2)], {type: 'application/json'});
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = filename;
  a.click();
  URL.revokeObjectURL(url);
  const sessionTotal = Object.values(data.sessions).reduce((acc, evs) => acc + evs.length, 0);
  console.log(
    `Dumped ${Object.keys(data.sessions).length} sessions, ` +
    `${sessionTotal} events, ${data.errors.length} errors → ${filename}`,
  );
  return data;
}
