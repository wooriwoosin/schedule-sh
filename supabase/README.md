# Supabase 이전 — 작업 순서

구글시트(Apps Script) → Supabase 이전 작업입니다.
**이 폴더의 파일은 전부 로컬 PostgreSQL 16 + 실제 PostgREST로 검증했습니다.**

현재 상태:

| 단계 | 내용 | 담당 | 상태 |
|---|---|---|---|
| 1 | Supabase 프로젝트 생성 | **당신** | ⬜ |
| 2 | 스키마·보안·함수 작성 (`schema.sql`) | Claude | ✅ |
| 3 | SQL 실행 + 관리자 PIN 설정 | **당신** | ⬜ |
| 4 | 이관 스크립트 작성 (`../tools/migrate-gas-to-supabase.mjs`) | Claude | ✅ |
| 5 | 이관 실행 | **당신** | ⬜ |
| 6 | `index.html`을 Supabase로 전환 | Claude | ✅ |
| 7 | 실제 데이터로 검증 | **당신** | ⬜ |
| 8 | main 머지 → GitHub Pages 반영 | **당신** | ⬜ |

---

## 1단계 — 프로젝트 생성 (5분)

1. https://supabase.com 가입 → **New project**
2. **Region은 반드시 `Northeast Asia (Seoul)`** — 이게 속도의 절반입니다.
   다른 리전을 고르면 요청마다 200~300ms가 그냥 붙습니다.
3. Database Password는 아무거나 정해서 **따로 보관**하세요 (이 작업엔 안 씁니다)
4. 생성 후 **Settings → API** 에서 Claude에게 알려줄 두 가지:
   - `Project URL` (예: `https://abcdefgh.supabase.co`)
   - `anon public` 키

> `anon` 키는 공개되어도 되는 키입니다. RLS가 쓰기를 막고 있어서
> `index.html`에 그대로 들어갑니다. 검증 결과는 아래 "보안" 항목 참고.
>
> ⚠️ **`service_role` 키는 누구에게도 주지 마세요.** 그 키는 모든 보안을
> 우회합니다. 5단계에서 당신 PC에서만 씁니다.

## 3단계 — SQL 실행 (5분)

1. 대시보드 → **SQL Editor** → **New query**
2. `schema.sql` **전체**를 붙여넣고 **Run**
   → 마지막에 표가 하나 나옵니다. 여기서 `설정된PIN`이 `0`이면 다음 단계가 필요합니다.
3. **PIN은 schema.sql을 실행해도 설정되지 않습니다.** 파일에는 함수만 들어 있습니다.
   다시 **New query** 를 열고, 아래 두 줄을 원하는 PIN으로 바꿔서 실행하세요:

   ```sql
   select private.set_pin('super', '여기에_슈퍼관리자_PIN');
   select private.set_pin('admin', '여기에_관리자_PIN');
   ```

   `super PIN이 설정되었습니다.` 가 나오면 성공입니다.
4. 제대로 됐는지 확인하려면 `schema.sql` 을 한 번 더 Run 하세요 (여러 번 실행해도
   안전합니다). 마지막 표의 `설정된PIN` 이 `2` 가 되고
   "PIN까지 준비됐습니다" 가 보이면 3단계 완료입니다.

   - **8자 이상 권장** (4자 미만은 거부됩니다)
   - bcrypt 해시만 저장되므로 나중에 PIN을 다시 볼 수 없습니다.
     잊으면 이 두 줄을 새 PIN으로 다시 실행하면 됩니다.
   - PIN을 설정하지 않으면 관리자모드로 로그인할 수 없습니다.

`schema.sql`은 여러 번 실행해도 안전합니다.

## 5단계 — 데이터 이관 (10분)

브라우저에서 버튼으로 하는 방법과, 터미널에서 하는 방법 두 가지가 있습니다.
**브라우저 방법을 권합니다** — 설치할 것도, 다룰 키도 없습니다.

### 방법 A — 브라우저 (권장)

**A-1. SQL을 한 번 더 실행**

이관용 함수가 추가됐습니다. SQL Editor에서 `schema.sql` 전체를 **다시 한 번**
붙여넣고 Run 하세요 (여러 번 실행해도 안전합니다). 맨 아래 표가 다시 나오면
완료입니다.

**A-2. 이관 페이지 열기**

아래 주소를 브라우저에서 열고 `Ctrl+S`(Mac은 `⌘+S`)로 저장한 뒤,
저장된 `migrate.html` 파일을 더블클릭하세요.

```
https://raw.githubusercontent.com/wooriwoosin/schedule-sh/claude/gas-url-performance-ccmabu/migrate.html
```

**A-3. 화면에서 순서대로**

1. 슈퍼관리자 PIN 입력 → **로그인**
2. **확인해보기 (저장 안 함)** → 건수가 시트와 맞는지 확인
3. **이관 실행** → 끝

마지막에 나오는 대조표를 그대로 알려주세요. 여러 번 눌러도 중복이 생기지
않으니 마음 놓고 하셔도 됩니다.

### 방법 B — 터미널

Node.js 18 이상이 필요합니다.

```bash
curl -L -o migrate.mjs "https://raw.githubusercontent.com/wooriwoosin/schedule-sh/claude/gas-url-performance-ccmabu/tools/migrate-gas-to-supabase.mjs"

# 건수만 확인
node migrate.mjs --url=https://iwfiilgjiqkdsuybqwwk.supabase.co --key=sb_secret_... --dry-run

# 실제 실행
node migrate.mjs --url=https://iwfiilgjiqkdsuybqwwk.supabase.co --key=sb_secret_...
```

Windows PowerShell에서는 `curl.exe` 를 쓰고, 한글이 깨지면 먼저
`[Console]::OutputEncoding=[System.Text.Encoding]::UTF8` 를 실행하세요.

키는 **Settings → API 의 secret 키**입니다 (`sb_secret_…`).
publishable 키를 넣으면 시작하자마자 멈추고 알려줍니다.

### 두 방법이 똑같이 처리하는 것들

- 이름 앞의 `(퇴)` 제거 → 퇴사 표시로 대체 (화면에는 똑같이 보입니다)
- 색상 형식이 깨진 값 → 기본 파란색으로 보정
- 같은 직원·같은 날짜 중복 → 1건으로 정리 (마지막 값이 남음)
- 삭제된 직원의 연차 기록 → 이름만 보존해서 유지
- 종류 목록에 없는 유형 → **버리지 않고** 추가하고 경고 표시
- 변경이력 시각 → 한국시간으로 해석. 날짜를 읽을 수 없으면 1970-01-01로
  기록합니다 (실행할 때마다 값이 달라져 같은 줄이 또 쌓이는 것을 막기 위함)
- **여러 번 실행해도 중복이 생기지 않습니다**

### 이관이 끝난 뒤 (선택)

이관용 함수를 남겨두고 싶지 않으면 SQL Editor에서 지울 수 있습니다.
슈퍼관리자만 호출할 수 있어 그대로 둬도 위험하지는 않습니다.

```sql
drop function if exists public.import_employees(text,jsonb);
drop function if exists public.import_annual_types(text,jsonb);
drop function if exists public.import_annuals(text,jsonb);
drop function if exists public.import_orphan_annuals(text,jsonb);
drop function if exists public.import_change_logs(text,jsonb,boolean);
drop function if exists public.import_notice(text,text);
```

---

## 설계 요약

```
index.html (정적, 빌드 없음, 외부 라이브러리 없음)
   ├─ 조회  → PostgREST 직접 (RLS: 읽기만 허용)
   ├─ 쓰기  → RPC 함수 (세션 토큰 검증 + 변경이력 기록을 한 번에)
   └─ 갱신  → 화면으로 돌아오면 즉시, 보고 있는 동안 30초 주기
```

### 갱신 방식에 대해 — 당초 계획과 달라진 점

처음엔 Supabase Realtime(웹소켓 푸시)을 쓸 계획이었습니다. 실제로는
**화면 복귀 시 즉시 갱신 + 보이는 동안 30초 주기 확인**으로 만들었습니다.

이유는 Realtime을 여기서 테스트할 수 없기 때문입니다. Realtime은 PostgREST와
별개의 서비스라 로컬에 띄울 수 없고, 지금 이 환경에서는 당신 프로젝트로
직접 요청을 보낼 수도 없습니다(네트워크 정책 차단). 테스트하지 못한 코드를
넣고 "됩니다"라고 할 수는 없어서, 검증 가능한 방식으로 만들었습니다.

실무상 차이는 거의 없습니다. 다른 탭/앱을 보다가 돌아오면 그 순간 갱신되고,
계속 띄워둔 화면은 30초 안에 반영됩니다. 요청 1건이 수 ms라 부담도 없습니다.

진짜 푸시가 필요하면 나중에 추가할 수 있습니다. `schema.sql`이 이미
`employees`/`annuals`/`settings`를 realtime publication에 넣어두었으므로
**DB는 건드릴 필요가 없고** 클라이언트만 고치면 됩니다.

### 왜 빨라지는가

| | 기존 (GAS) | Supabase |
|---|---|---|
| 첫 화면 | 4회 요청 | **1회** (`get_bootstrap`) |
| 쓰기 1건 | 2회 (저장 + 변경이력) | **1회** (RPC가 둘 다 처리) |
| 월 이동 | 1회 | **0회** (3개월을 미리 받아둠) |
| 호출당 서버 처리 | 500~2000ms | 로컬 측정 **1~3ms** |
| 등록 후 화면 반영 | 800ms+ | **50ms** (낙관적 반영) |

브라우저 자동 테스트로 확인한 값 (로컬):

```
첫 방문        152ms · REST 요청 1건
재방문(캐시)    70ms
연차 등록 반영   52ms   (서버 응답을 기다리지 않음)
퇴사처리 반영    49ms
월 이동         297ms · REST 요청 0건  (3개월 창 안)
창 밖 월 이동          · REST 요청 1건
```

`get_bootstrap`은 직원·연차종류·연차(앞뒤 1개월 포함 3개월)·공지·권한을
한 번에 돌려줍니다. 월 이동도 추가 요청이 없습니다.

### 로그인

PIN 검증(bcrypt)은 **로그인할 때 한 번만** 하고, 30일짜리 세션 토큰을
발급합니다. 이후 모든 요청은 토큰을 인덱스로 확인합니다.

처음엔 매 요청마다 PIN을 확인하도록 만들었더니 `get_bootstrap`이
**130ms**가 걸렸습니다 (대부분 bcrypt). 토큰 방식으로 바꿔 **2.4ms**가
됐습니다. 쓰기도 ~100ms → 1.2ms.

### 보안 — 실제로 검증한 것

`anon` 키는 공개됩니다. 그 키를 가진 사람이 HTTP로 직접 할 수 있는 일을
실제 PostgREST에 요청해서 확인했습니다.

| 시도 | 결과 |
|---|---|
| 조회 (`GET /employees`) | 200 — 허용 (기존 GAS 웹앱과 같은 수준) |
| 직원 추가/수정/삭제 | **401** 거부 |
| 연차 위조, 변경이력 위조 | **401** 거부 |
| PIN 해시 테이블 조회 | **404** — API에 존재하지 않음 |
| 세션 토큰 테이블 조회 | **404** — API에 존재하지 않음 |
| PIN 변경 함수 호출 | **404** — API에 존재하지 않음 |
| 토큰 없이 쓰기 RPC 호출 | 거부 ("로그인이 필요합니다") |
| 관리자 토큰으로 직원 등록 | 거부 ("슈퍼관리자만...") |
| 올바른 토큰으로 쓰기 | 허용 — 정상 경로 |

PIN 해시와 세션은 `private` 스키마에 있고, Supabase는 `public` 스키마만
API로 공개하므로 네트워크에서 접근 자체가 불가능합니다.

### 키 전달 방식 — 5단계가 대신 확인해 줍니다

신형 키(`sb_publishable_…` / `sb_secret_…`)는 JWT가 아니라서
`Authorization: Bearer` 로 보내면 안 됩니다. 이 환경에서는 Supabase에
접속할 수 없어 확인하지 못했기 때문에, 이관 스크립트가 **두 방식을 모두
시도해서 맞는 쪽을 고르도록** 만들었습니다.

5단계를 실행하면 0번 항목에 이런 줄이 나옵니다:

```
✓ 쓰기 키 확인 (Authorization 헤더 미사용 · 신형 키)
✓ index.html publishable 키 정상 (Authorization 헤더 불필요)
```

두 번째 줄이 `정상`이면 `index.html` 설정이 맞는 것입니다.
`!` 경고가 보이면 그 줄을 그대로 알려주세요. 바로 고치겠습니다.

### 그 밖에 확인하지 못한 것

당신이 준 키는 신형 **publishable 키**(`sb_publishable_…`)입니다. 구형
`anon` 키와 달리 JWT가 아니라서, `Authorization: Bearer`로 보내면 인증
계층이 JWT 파싱에 실패할 수 있습니다. 그래서 클라이언트는 이렇게 보냅니다:

- `apikey` 헤더: **항상** 보냄
- `Authorization: Bearer`: 키가 `eyJ`로 시작하는 JWT일 때만 보냄

로컬 테스트는 JWT 키로 했기 때문에 **publishable 키 경로는 실제로 검증하지
못했습니다.** 7단계에서 페이지를 열었을 때 `401` 오류 배너가 뜨면 이 부분이
원인입니다. 그대로 알려주시면 바로 고치겠습니다.

### 알려진 한계

- **조회는 anon 키를 가진 누구나 가능합니다.** 지금 GAS 웹앱도 URL만
  알면 누구나 조회되는 상태라 보안 수준은 동일합니다. 조회까지 잠그려면
  Supabase Auth(개인 계정) 전환이 필요합니다.
- **PIN 대입 차단이 전체 공용입니다.** 요청자를 식별할 방법이 없어서
  (Supabase를 거치면 모든 요청이 같은 IP로 보임), 누군가 계속 틀린 PIN을
  넣으면 그 1분 동안은 정상 사용자도 로그인이 막힙니다. 이미 로그인한
  관리자는 토큰이 30일 유지되므로 영향받지 않습니다.
- **무료 플랜은 7일간 접속이 없으면 프로젝트가 일시정지**됩니다.
  매일 쓰는 앱이면 해당되지 않습니다.
