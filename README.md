# Oracle 23ai Free 마이그레이션 테스트 랩 ([0] ~ [4] 단계 실습)

8GB RAM 로컬 환경(macOS / Docker Desktop)에서 **DB Link + Direct Path Parallel INSERT + SCN 일관성 마이그레이션([0]~[4] 단계)**을 즉시 검증할 수 있는 환경입니다.

---

## 1. 아키텍처 및 구성

```
+-----------------------------------------------------------------------------------------+
| mig-net (Docker Bridge Network)                                                         |
|                                                                                         |
|   [ora-src]                                              [ora-tgt]                      |
|   - Image: gvenzl/oracle-free:23-slim-faststart         - Image: gvenzl/oracle-free...  |
|   - Port: 1521:1521                                      - Port: 1522:1521              |
|   - Memory: 2.5G                                         - Memory: 2.5G                 |
|   - PDB: FREEPDB1                                        - PDB: FREEPDB1                |
|   - User: mig_user / oracle                              - User: mig_user / oracle      |
|   - Parameters:                                          - Parameters:                  |
|     * UNDO_RETENTION = 3600 (1시간)                        * PARALLEL_MAX_SERVERS = 16  |
|     * PARALLEL_MAX_SERVERS = 16                          - DB Link:                     |
|   - Privileges:                                            * PROD_MIG_LINK              |
|     * SELECT ON V_$DATABASE                                  -> //ora-src:1521/FREEPDB1 |
|     * FLASHBACK ANY TABLE                                - Tables:                      |
|   - Tables:                                                * TB_CUST_MST (1만 건)        |
|     * TB_CUST_MST (1만 건)                                 * TB_CARD_TXN (구데이터 100건)|
|     * TB_CARD_TXN (50만 건)                              - Mount:                       |
|   - Mount:                                                 * ./init/tgt                 |
|     * ./init/src                                           * ./test_migration.sql       |
+-----------------------------------------------------------------------------------------+
```

---

## 2. 프로젝트 폴더 구조

```
oracle-mig-lab/
├── docker-compose.yml          # 컨테이너 2대, 2.5G 제한, mig-net, init/src 및 init/tgt 분리 마운트
├── init/
│   ├── src/
│   │   └── 01_setup_src.sql    # ora-src 기동 시: UNDO_RETENTION 3600, 50만 건 적재, 권한 설정
│   └── tgt/
│       └── 01_setup_tgt.sql    # ora-tgt 기동 시: PROD_MIG_LINK 생성, 스키마 및 구데이터 100건 적재
├── test_migration.sql          # [0]~[4] 마이그레이션 전체 자동 실행 및 타이밍 측정 스크립트
└── README.md                   # 실행 가이드
```

---

## 3. 실행 및 검증 절차

### Step 1. 컨테이너 기동
```bash
docker compose up -d
```

### Step 2. 초기화 완료 확인 (약 20~30초 소요)
```bash
# ora-src 및 ora-tgt에서 "DATABASE IS READY TO USE!" 메시지 확인
docker compose logs -f | grep "DATABASE IS READY TO USE"
```

### Step 3. 마이그레이션 검증 스크립트 실행 ([0] ~ [4] 단계)
`ora-tgt` 컨테이너 내부에서 `test_migration.sql`을 실행합니다:

```bash
docker exec -it ora-tgt sqlplus mig_user/oracle@FREEPDB1 @/test_migration.sql
```

---

## 4. [0] ~ [4] 단계 스크립트 세부 동작

| 단계 | 작업 내용 | 주요 특징 |
| :--- | :--- | :--- |
| **[0]** | SCN 추출 | `SELECT CURRENT_SCN FROM V$DATABASE@PROD_MIG_LINK`로 정합성 기준점 확보 (`&MIG_SCN`) |
| **[1]** | 타겟 정리 | `TRUNCATE TABLE TB_CARD_TXN`, `DISABLE CONSTRAINT FK_CARD_CUST`, `UNUSABLE INDEX` 처리, `PARALLEL DML` 활성화 |
| **[2]** | 병렬 이관 | `INSERT /*+ APPEND PARALLEL(t, 8) */ INTO ... SELECT /*+ PARALLEL(s, 8) */ FROM ...@PROD_MIG_LINK AS OF SCN &MIG_SCN` (50만 건 초고속 적재) |
| **[3]** | 후속 복구 | `ALTER INDEX ... REBUILD PARALLEL 8` -> `NOPARALLEL`, `ENABLE CONSTRAINT FK_CARD_CUST` |
| **[4]** | 검증 및 수집 | 소스 vs 타겟 건수 50만 건 일치 확인, 인덱스/제약조건 상태 점검, `DBMS_STATS.GATHER_TABLE_STATS` 수행 |

---

## 5. 환경 종료 및 리셋

```bash
# 컨테이너 중지
docker compose down

# 볼륨까지 완전히 삭제하고 처음부터 다시 테스트하려면:
docker compose down -v
```
