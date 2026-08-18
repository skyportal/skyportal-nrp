// SkyPortal load test — realistic hot-path mix, ramping concurrency.
// Env: BASE_URL, TOKEN, VUS_LOW, VUS_HIGH, RAMP, HOLD. Run the SAME script
// against fritz.science (with a Fritz token) for the GCP baseline.
import http from 'k6/http';
import { check } from 'k6';
import { Trend } from 'k6/metrics';

const BASE = __ENV.BASE_URL;
const HEADERS = { headers: { Authorization: `token ${__ENV.TOKEN}` } };

// per-endpoint latency so we can compare the heavy photometry path separately
const T = {
  sources: new Trend('lat_sources', true),
  candidates: new Trend('lat_candidates', true),
  source_detail: new Trend('lat_source_detail', true),
  photometry: new Trend('lat_photometry', true),
};

export const options = {
  stages: [
    { duration: __ENV.RAMP || '30s', target: Number(__ENV.VUS_LOW || 10) },
    { duration: __ENV.HOLD || '1m', target: Number(__ENV.VUS_LOW || 10) },
    { duration: '30s', target: Number(__ENV.VUS_HIGH || 50) },
    { duration: __ENV.HOLD || '1m', target: Number(__ENV.VUS_HIGH || 50) },
    { duration: '20s', target: 0 },
  ],
  thresholds: {
    http_req_failed: ['rate<0.05'],
    http_req_duration: ['p(95)<3000'],
    lat_photometry: ['p(95)<8000'],
  },
};

// Pull a pool of real object IDs to query (one call, reused by all VUs).
export function setup() {
  const res = http.get(`${BASE}/api/sources?numPerPage=100&pageNumber=1`, HEADERS);
  let ids = [];
  try {
    const arr = (res.json().data || {}).sources || [];
    ids = arr.map((s) => s.id || s.obj_id).filter(Boolean);
  } catch (e) { /* fall through */ }
  if (!ids.length) ids = ['ZTF18acdymkx'];
  return { ids };
}

function get(url, ep) {
  const res = http.get(url, { ...HEADERS, tags: { ep } });
  T[ep].add(res.timings.duration);
  check(res, { [`${ep} 200`]: (r) => r.status === 200 });
  return res;
}

export default function (data) {
  const oid = data.ids[Math.floor(Math.random() * data.ids.length)];
  const r = Math.random();
  if (r < 0.35) {
    get(`${BASE}/api/sources?numPerPage=25&pageNumber=${1 + Math.floor(Math.random() * 20)}`, 'sources');
  } else if (r < 0.55) {
    get(`${BASE}/api/candidates?numPerPage=25&groupIDs=1`, 'candidates');
  } else if (r < 0.75) {
    get(`${BASE}/api/sources/${oid}?includeThumbnails=true&includeComments=true&includeDetectionStats=true`, 'source_detail');
  } else {
    get(`${BASE}/api/sources/${oid}/photometry?magsys=ab`, 'photometry');
  }
}
