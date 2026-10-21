// Small mixed load against petclinic: home, owner search, vets.
// TARGET, VUS and DURATION come from the k6-config ConfigMap.
import http from 'k6/http';
import { check, sleep } from 'k6';

const target = __ENV.TARGET;

export const options = {
  vus: Number(__ENV.VUS || 5),
  duration: __ENV.DURATION || '2m',
};

export default function () {
  const pages = [
    `${target}/`,
    `${target}/owners?lastName=`,
    `${target}/vets.html`,
  ];
  for (const url of pages) {
    const res = http.get(url);
    check(res, { 'status is 200': (r) => r.status === 200 });
    // One line per request: epoch ms, duration ms, status. lab.sh computes
    // percentiles for an exact time window from these.
    console.log(`K6_POINT ${Date.now()} ${res.timings.duration.toFixed(2)} ${res.status}`);
    sleep(0.2);
  }
}

// One marker line with the whole-run numbers. lab.sh parses it from the Job log.
export function handleSummary(data) {
  const d = data.metrics.http_req_duration.values;
  const summary = {
    requests: data.metrics.http_reqs.values.count,
    rate: data.metrics.http_reqs.values.rate,
    failed_ratio: data.metrics.http_req_failed.values.rate,
    p50_ms: d.med,
    p95_ms: d['p(95)'],
    avg_ms: d.avg,
  };
  return { stdout: `K6_SUMMARY ${JSON.stringify(summary)}\n` };
}
