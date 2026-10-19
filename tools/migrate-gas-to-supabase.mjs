#!/usr/bin/env node
/*
 * 구글시트(GAS) → Supabase 데이터 이관
 * ─────────────────────────────────────────────────────────────────────
 * 기존 Apps Script 엔드포인트에서 직원·연차·공지·변경이력을 읽어
 * Supabase에 넣습니다. 의존성 없음 — node 18 이상이면 그냥 돌아갑니다.
 *
 *   # 1) 먼저 건수만 확인 (아무것도 쓰지 않음)
 *   SUPABASE_URL=https://xxxx.supabase.co \
 *   SUPABASE_SERVICE_ROLE_KEY=eyJ... \
 *   node tools/migrate-gas-to-supabase.mjs --dry-run
 *
 *   # 2) 실제 이관
 *   SUPABASE_URL=... SUPABASE_SERVICE_ROLE_KEY=... \
 *   node tools/migrate-gas-to-supabase.mjs
 *
 * 옵션
 *   --dry-run        읽기만 하고 쓰지 않음
 *   --from=2024-01   연차를 가져올 시작 월 (기본 2024-01)
 *   --to=2027-12     연차를 가져올 끝 월  (기본 올해+1년 12월)
 *   --redo-logs      변경이력을 지우고 다시 넣음 (기본: 이미 있으면 건너뜀)
 *   --gas-url=...    GAS 엔드포인트 직접 지정 (기본: index.html에서 읽음)
 *
 * ⚠️ SUPABASE_SERVICE_ROLE_KEY 는 DB를 전부 열 수 있는 키입니다.
 *    이 스크립트를 당신 PC에서만 실행하고, 키를 코드나 깃에 넣지 마세요.
 * 여러 번 실행해도 안전합니다 (같은 데이터는 덮어쓰기만 함).
 */

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const HERE = dirname(fileURLToPath(import.meta.url));
const argv = process.argv.slice(2);
const flag = (n) => argv.includes('--' + n);
const opt  = (n, d) => {
  const hit = argv.find((a) => a.startsWith('--' + n + '='));
  return hit ? hit.slice(n.length + 3) : d;
};

const DRY = flag('dry-run');
const REDO_LOGS = flag('redo-logs');
const SUPABASE_URL = (process.env.SUPABASE_URL || '').replace(/\/+$/, '');
const SERVICE_KEY  = process.env.SUPABASE_SERVICE_ROLE_KEY || '';

// index.html은 이미 Supabase로 전환돼 GAS_URL이 없다. 이관 전용 값이므로
// 여기에 둔다. 다른 배포본에서 가져오려면 --gas-url=… 로 지정하면 된다.
const DEFAULT_GAS_URL =
  'https://script.google.com/macros/s/AKfycbwl-hvK6QffGot9hRIL_A_3AnT1b0p_lKt2tk6X-EsuJvjBdI5Oc8M_pubrlpPthy2X/exec';
const GAS_URL = opt('gas-url', process.env.GAS_URL || DEFAULT_GAS_URL);

// index.html에 들어 있는 publishable 키 (키 전달 방식 점검용)
function publishableKeyFromIndexHtml() {
  try {
    const html = readFileSync(join(HERE, '..', 'index.html'), 'utf8');
    const m = html.match(/var SUPABASE_KEY = '([^']+)'/);
    return m ? m[1] : '';
  } catch { return ''; }
}

const FROM = opt('from', '2024-01');
const TO   = opt('to', (new Date().getFullYear() + 1) + '-12');

// ── 출력 ──────────────────────────────────────────────────────────────
const C = { g:'\x1b[32m', r:'\x1b[31m', y:'\x1b[33m', d:'\x1b[2m', b:'\x1b[1m', x:'\x1b[0m' };
const say  = (...a) => console.log(...a);
const step = (s) => say('\n' + C.b + s + C.x);
const ok   = (s) => say('  ' + C.g + '✓' + C.x + ' ' + s);
const warn = (s) => say('  ' + C.y + '!' + C.x + ' ' + s);
const die  = (s) => { say('\n' + C.r + '✗ ' + s + C.x + '\n'); process.exit(1); };

// ── 입력 검증 ─────────────────────────────────────────────────────────
if (!GAS_URL)      die('GAS_URL을 찾을 수 없습니다. --gas-url=... 로 지정해주세요.');
if (!SUPABASE_URL) die('SUPABASE_URL 환경변수가 필요합니다.');
if (!SERVICE_KEY)  die('SUPABASE_SERVICE_ROLE_KEY 환경변수가 필요합니다.\n' +
                       '  Supabase 대시보드 → Settings → API → service_role 키');
if (!/^\d{4}-\d{2}$/.test(FROM) || !/^\d{4}-\d{2}$/.test(TO)) die('--from / --to 는 YYYY-MM 형식이어야 합니다.');

// ── GAS 호출 ──────────────────────────────────────────────────────────
async function gas(action, data = {}) {
  for (let attempt = 1; attempt <= 4; attempt++) {
    try {
      const r = await fetch(GAS_URL, {
        method: 'POST',
        headers: { 'Content-Type': 'text/plain;charset=utf-8' },
        body: JSON.stringify({ action, ...data }),
      });
      const j = await r.json();
      if (j && j.ok === false) throw new Error(j.error || 'GAS가 ok:false 를 반환');
      return j;
    } catch (e) {
      if (attempt === 4) throw new Error(`GAS ${action} 실패: ${e.message}`);
      await new Promise((res) => setTimeout(res, 500 * 2 ** attempt));
    }
  }
}

// ── Supabase REST ─────────────────────────────────────────────────────
// 구형 키(eyJ…)는 JWT라 Authorization: Bearer 로도 보내지만, 신형 키
// (sb_secret_… / sb_publishable_…)는 JWT가 아니어서 Bearer로 보내면 인증
// 계층이 JWT 파싱에 실패할 수 있다. 추측하지 않고 실제로 찔러보고 정한다.
let USE_BEARER = /^eyJ/.test(SERVICE_KEY);

function headersFor(key, bearer, extra) {
  return {
    apikey: key,
    'Content-Type': 'application/json',
    ...(bearer ? { Authorization: `Bearer ${key}` } : {}),
    ...(extra || {}),
  };
}

// 쓰기 권한까지 확인하는 점검. 조건에 맞는 행이 없어 아무것도 바꾸지 않지만
// UPDATE 권한이 없으면 거부되므로, 키가 "받아들여졌는지"가 아니라
// "쓸 수 있는지"를 가린다.
async function probeWriteKey(key) {
  const order = /^eyJ/.test(key) ? [true, false] : [false, true];
  let detail = '';
  for (const bearer of order) {
    let r;
    try {
      r = await fetch(`${SUPABASE_URL}/rest/v1/settings?key=eq.__migrate_probe__`, {
        method: 'PATCH',
        headers: headersFor(key, bearer, { Prefer: 'return=minimal' }),
        body: JSON.stringify({ value: '' }),
      });
    } catch (e) {
      // 주소 자체에 닿지 못한 경우 — 키 문제가 아니므로 바로 알린다
      die(`Supabase에 접속할 수 없습니다: ${SUPABASE_URL}\n  ${e.message}\n\n` +
          '  · SUPABASE_URL 이 맞는지 확인하세요 (예: https://xxxx.supabase.co)\n' +
          '  · 인터넷 연결과 사내 방화벽을 확인하세요');
    }
    if (r.ok) return { bearer, detail: null };
    detail = `${r.status} ${(await r.text()).slice(0, 200)}`;
  }
  return { bearer: null, detail };
}

// 조회만 되는지 확인 (publishable 키용)
async function probeReadKey(key) {
  for (const bearer of [false, true]) {
    try {
      const r = await fetch(`${SUPABASE_URL}/rest/v1/annual_types?select=key&limit=1`, {
        headers: headersFor(key, bearer),
      });
      if (r.ok) return { bearer };
    } catch { /* 점검용이므로 실패해도 넘어간다 */ }
  }
  return { bearer: null };
}

async function rest(method, path, { body, prefer } = {}) {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/${path}`, {
    method,
    headers: headersFor(SERVICE_KEY, USE_BEARER, prefer ? { Prefer: prefer } : null),
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await r.text();
  if (!r.ok) {
    throw new Error(`Supabase ${method} ${path} → ${r.status}\n  ${text.slice(0, 500)}`);
  }
  return text ? JSON.parse(text) : null;
}
const select = (path) => rest('GET', path);
const upsert = (table, rows, onConflict) =>
  rest('POST', `${table}?on_conflict=${onConflict}`, {
    body: rows, prefer: 'resolution=merge-duplicates,return=minimal',
  });
const insert = (table, rows) =>
  rest('POST', table, { body: rows, prefer: 'return=minimal' });

const chunk = (arr, n) => Array.from({ length: Math.ceil(arr.length / n) }, (_, i) => arr.slice(i * n, i * n + n));

function monthRange(from, to) {
  const out = [];
  let [y, m] = from.split('-').map(Number);
  const [ty, tm] = to.split('-').map(Number);
  while (y < ty || (y === ty && m <= tm)) {
    out.push(`${y}-${String(m).padStart(2, '0')}`);
    if (++m > 12) { m = 1; y++; }
  }
  return out;
}
// 동시 실행 수 제한 (GAS 실행 할당량 보호)
async function pool(items, limit, fn) {
  const out = [];
  let i = 0;
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, async () => {
    while (i < items.length) {
      const idx = i++;
      out[idx] = await fn(items[idx], idx);
    }
  }));
  return out;
}

// ═══════════════════════════════════════════════════════════════════════
(async () => {
  say(C.b + '\n구글시트 → Supabase 이관' + C.x);
  say(C.d + `  GAS      ${GAS_URL.slice(0, 60)}…` + C.x);
  say(C.d + `  Supabase ${SUPABASE_URL}` + C.x);
  say(C.d + `  연차 범위 ${FROM} ~ ${TO}` + C.x);
  if (DRY) say(C.y + '  [--dry-run] 읽기만 합니다. 아무것도 쓰지 않습니다.' + C.x);

  // ── 스키마가 적용됐는지 먼저 확인 ─────────────────────────────────
  step('0. Supabase 연결 및 키 확인');

  // 어떤 방식으로 키를 보내야 하는지 추측하지 않고 실제로 확인한다
  const probe = await probeWriteKey(SERVICE_KEY);
  if (probe.bearer === null) {
    die('이 키로는 쓰기를 할 수 없습니다.\n  마지막 응답: ' + probe.detail + '\n\n' +
        '  · Settings → API 의 secret 키인지 확인하세요\n' +
        '    (신형이면 sb_secret_… / 구형이면 service_role 의 eyJ… 로 시작)\n' +
        '  · publishable(anon) 키로는 쓸 수 없습니다. 그게 정상입니다.\n' +
        '  · supabase/schema.sql 을 SQL Editor에서 먼저 실행했는지 확인하세요');
  }
  USE_BEARER = probe.bearer;
  ok(`쓰기 키 확인 (Authorization 헤더 ${USE_BEARER ? '사용' : '미사용'} · ` +
     `${/^eyJ/.test(SERVICE_KEY) ? '구형 JWT' : '신형'} 키)`);

  let knownTypes;
  try {
    const types = await select('annual_types?select=key');
    if (!types.length) die('annual_types 가 비어 있습니다. supabase/schema.sql 을 먼저 실행해주세요.');
    ok(`스키마 확인 · 연차 종류 ${types.length}개`);
    knownTypes = new Set(types.map((t) => t.key));
  } catch (e) {
    die(`스키마를 읽을 수 없습니다.\n  ${e.message}\n` +
        '  supabase/schema.sql 을 SQL Editor에서 먼저 실행했는지 확인하세요.');
  }

  // index.html이 쓰는 publishable 키도 같이 점검한다.
  // (이 컨테이너에서는 Supabase에 접속할 수 없어 확인하지 못한 부분)
  const pub = publishableKeyFromIndexHtml();
  if (pub && pub !== SERVICE_KEY) {
    const pr = await probeReadKey(pub);
    if (pr.bearer === null) {
      warn('index.html 의 publishable 키로는 조회가 되지 않습니다. 이 줄을 Claude에게 알려주세요.');
    } else {
      ok(`index.html publishable 키 정상 (Authorization 헤더 ${pr.bearer ? '필요' : '불필요'})`);
      if (pr.bearer && !/^eyJ/.test(pub)) {
        warn('index.html 이 Authorization 헤더를 보내지 않도록 돼 있습니다. 이 줄을 Claude에게 알려주세요.');
      }
    }
  }

  // ── 1. 직원 ───────────────────────────────────────────────────────
  step('1. 직원');
  const empRes = await gas('getEmployees');
  const srcEmps = empRes.employees || [];
  ok(`시트에서 ${srcEmps.length}명 읽음`);

  const empRows = srcEmps.map((e) => {
    const retired = !!e.retired;
    // 기존 데이터는 이름에 "(퇴)"가 붙어 있다. 이름은 깨끗하게 저장하고
    // 화면에서 retired 플래그로 붙인다.
    const name = String(e.name || '').replace(/^\(퇴\)\s*/, '').trim();
    const color = /^#[0-9A-Fa-f]{6}$/.test(e.color || '') ? e.color : '#3B6FE8';
    let retiredAt = null;
    if (retired) {
      const m = String(e.retiredAt || '').match(/\d{4}-\d{2}-\d{2}/);
      retiredAt = m ? m[0] : null;
    }
    return { legacy_id: String(e.id), name, team: String(e.team || '').trim(), color, retired, retired_at: retiredAt };
  }).filter((r) => r.name);

  const dropped = srcEmps.length - empRows.length;
  if (dropped) warn(`이름이 비어 있어 건너뛴 직원 ${dropped}명`);
  const renamed = srcEmps.filter((e) => /^\(퇴\)/.test(String(e.name || ''))).length;
  if (renamed) ok(`이름 앞의 "(퇴)" 접두어 ${renamed}건 제거 (retired 플래그로 대체)`);

  if (!DRY && empRows.length) {
    await upsert('employees', empRows, 'legacy_id');
    ok(`직원 ${empRows.length}명 반영`);
  }

  // legacy_id → uuid 맵.
  // --dry-run 에서는 아직 쓰지 않았으므로 "넣었다면 생길" 매핑을 가정한다.
  // (그러지 않으면 모든 연차가 주인 없는 기록으로 잘못 집계된다)
  const idMap = new Map();
  if (DRY) {
    empRows.forEach((r) => idMap.set(r.legacy_id, 'dry-run'));
  } else {
    for (const row of await select('employees?select=id,legacy_id&legacy_id=not.is.null')) {
      idMap.set(row.legacy_id, row.id);
    }
    ok(`id 매핑 ${idMap.size}건 확보`);
  }

  // ── 2. 연차 ───────────────────────────────────────────────────────
  step('2. 연차 / 휴일근무');
  const months = monthRange(FROM, TO);
  say(C.d + `  ${months.length}개월 조회 중… (GAS가 느려 1~2분 걸릴 수 있습니다)` + C.x);

  let done = 0;
  const perMonth = await pool(months, 5, async (ym) => {
    const r = await gas('getAnnuals', { ym });
    done++;
    if (done % 12 === 0) say(C.d + `    ${done}/${months.length}개월` + C.x);
    return r.annuals || [];
  });
  const srcAnnuals = perMonth.flat();
  ok(`시트에서 연차 ${srcAnnuals.length}건 읽음`);

  // 알 수 없는 종류는 버리지 않고 종류 테이블에 추가한다 (데이터 유실 방지)
  const unknown = [...new Set(srcAnnuals.map((a) => a.type).filter((t) => t && !knownTypes.has(t)))];
  if (unknown.length) {
    warn(`종류 테이블에 없는 유형 ${unknown.length}종 발견: ${unknown.join(', ')}`);
    warn('버리지 않고 추가합니다. 나중에 annual_types 에서 색상(css_class)을 조정하세요.');
    if (!DRY) {
      await upsert('annual_types',
        unknown.map((k, i) => ({ key: k, label: k, css_class: 'cc-an', weekend_only: false, sort_order: 90 + i })),
        'key');
      unknown.forEach((k) => knownTypes.add(k));
    }
  }

  const linked = [], orphans = [];
  let noType = 0;
  for (const a of srcAnnuals) {
    if (!a.type) { noType++; continue; }
    const uuid = idMap.get(String(a.empId));
    const row = {
      emp_id: uuid || null,
      emp_name: String(a.empName || '').replace(/^\(퇴\)\s*/, '').trim(),
      date: a.date,
      type: a.type,
    };
    (uuid ? linked : orphans).push(row);
  }
  if (noType) warn(`종류가 비어 있어 건너뛴 연차 ${noType}건`);
  ok(`직원과 연결됨 ${linked.length}건` +
     (orphans.length ? ` / 삭제된 직원의 기록 ${orphans.length}건 (이름만 보존)` : ''));

  // 같은 직원·같은 날짜는 1건만 (시트에 중복이 있으면 마지막 것이 남음)
  const dedup = new Map();
  for (const r of linked) dedup.set(`${r.emp_id}|${r.date}`, r);
  if (dedup.size !== linked.length) warn(`같은 직원·날짜 중복 ${linked.length - dedup.size}건을 1건으로 정리`);

  if (!DRY) {
    for (const part of chunk([...dedup.values()], 500)) await upsert('annuals', part, 'emp_id,date');
    ok(`연차 ${dedup.size}건 반영`);

    // 주인 없는 기록은 (emp_id가 null이라) 유니크 제약이 안 걸린다 → 직접 중복 확인
    if (orphans.length) {
      const existing = new Set(
        (await select('annuals?select=emp_name,date,type&emp_id=is.null'))
          .map((r) => `${r.emp_name}|${r.date}|${r.type}`));
      const fresh = orphans.filter((r) => !existing.has(`${r.emp_name}|${r.date}|${r.type}`));
      if (fresh.length) {
        for (const part of chunk(fresh, 500)) await insert('annuals', part);
        ok(`삭제된 직원의 연차 ${fresh.length}건 반영`);
      } else {
        ok('삭제된 직원의 연차는 이미 반영돼 있음');
      }
    }
  }

  // ── 3. 공지 ───────────────────────────────────────────────────────
  step('3. 연차 공지');
  const noticeRes = await gas('getCalNotice');
  const notice = noticeRes.notice || '';
  ok(notice.trim() ? `"${notice.slice(0, 40).replace(/\n/g, ' ')}…"` : '(비어 있음)');
  if (!DRY) {
    await upsert('settings', [{ key: 'cal_notice', value: notice }], 'key');
    ok('공지 반영');
  }

  // ── 4. 변경이력 ───────────────────────────────────────────────────
  step('4. 변경이력');
  const logRes = await gas('getChangeLogs', { days: 36500 });
  const srcLogs = (logRes.logs || []).filter((l) => l && l.desc);
  ok(`시트에서 ${srcLogs.length}건 읽음`);

  if (!DRY) {
    const have = await select('change_logs?select=id&limit=1');
    if (have.length && !REDO_LOGS) {
      warn('이미 변경이력이 있어 건너뜁니다. 다시 넣으려면 --redo-logs 를 쓰세요.');
    } else {
      if (have.length) {
        await rest('DELETE', 'change_logs?id=gt.0', { prefer: 'return=minimal' });
        ok('기존 변경이력 삭제');
      }
      const rows = srcLogs.map((l) => {
        // "2026-09-19 10:00:00" → UTC 아님. 한국 시간으로 해석한다.
        const m = String(l.dt || '').match(/(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2}):(\d{2})/);
        const at = m ? `${m[1]}-${m[2]}-${m[3]}T${m[4]}:${m[5]}:${m[6]}+09:00` : new Date().toISOString();
        return { at, actor: String(l.by || ''), description: String(l.desc) };
      });
      for (const part of chunk(rows, 500)) await insert('change_logs', part);
      ok(`변경이력 ${rows.length}건 반영`);
    }
  }

  // ── 5. 대조 ───────────────────────────────────────────────────────
  step('5. 대조 확인');
  if (DRY) {
    say(`  넣을 예정: 직원 ${empRows.length}명 · 연차 ${dedup.size + orphans.length}건 · 변경이력 ${srcLogs.length}건`);
    say(C.y + '\n  --dry-run 이라 쓰지 않았습니다. 위 건수가 맞으면 --dry-run 없이 다시 실행하세요.' + C.x + '\n');
    return;
  }
  const count = async (t) => {
    const r = await fetch(`${SUPABASE_URL}/rest/v1/${t}?select=*`, {
      method: 'HEAD',
      headers: headersFor(SERVICE_KEY, USE_BEARER, { Prefer: 'count=exact' }),
    });
    return Number((r.headers.get('content-range') || '/0').split('/')[1]) || 0;
  };
  const [dbEmp, dbAnn, dbLog] = await Promise.all([count('employees'), count('annuals'), count('change_logs')]);
  const line = (label, src, db) =>
    say(`  ${label.padEnd(10)} 시트 ${String(src).padStart(6)}  →  DB ${String(db).padStart(6)}  ` +
        (db >= src ? C.g + '일치' : C.y + '확인 필요') + C.x);
  line('직원', empRows.length, dbEmp);
  line('연차', dedup.size + orphans.length, dbAnn);
  line('변경이력', srcLogs.length, dbLog);

  say(C.g + C.b + '\n이관 완료.' + C.x + ' 건수가 맞지 않으면 그대로 알려주세요.\n');
})().catch((e) => die(e.stack || e.message));
