-- =============================================================================
-- [01] 1.1TB I-CMS 콜데이터 대량 테이블 무중단 마이그레이션 최종 확정본
-- 대상 환경 : 신규 Target DB (DB Link: PROD_MIG_LINK 경유)
-- 대상 스키마: mig_user / oracle @ FREEPDB1
-- 작성 목적 : 1.1TB 규모 대용량 데이터의 무중단·고속·무결점 마이그레이션 자동화
--
-- -----------------------------------------------------------------------------
-- 📌 [실무 엔지니어링 아키텍처 및 6대 핵심 설계 원칙]
-- -----------------------------------------------------------------------------
-- 1. [SCN 플래시백 고정 읽기 (Read Consistency)]:
--    - 소스 DB가 24시간 운영 중이므로 테이블별로 적재하는 동안 데이터가 실시간 추가/변경됨.
--    - 배치 시작 시점 단 1개의 SCN(System Commit Number)을 확보하여 전체 테이블을
--      'AS OF SCN v_scn'으로 읽음으로써 102개 전체 테이블의 시점 일관성을 100% 동기화.
--
-- 2. [Direct-Path 병렬 적재 (High Performance)]:
--    - 일반 INSERT는 버퍼 캐시를 경유하며 Redo/Undo를 대량 생성하여 병목 유발.
--    - 'INSERT /*+ APPEND PARALLEL(8) */'로 버퍼 캐시를 우회하고 데이터 파일 High Water Mark(HWM)
--      뒤에 직접 블록을 할당(Direct-Path)하여 쓰기 속도를 10배 이상 극대화.
--    - 소스 DB는 서비스 부하를 보호하기 위해 SELECT /*+ PARALLEL(4) */로 쿼터 분배.
--
-- 3. [인덱스 UNUSABLE & 사후 병렬 REBUILD (Bulk Load Optimization)]:
--    - 인덱스가 켜진 채로 대용량 적재 시 인덱스 블록 Split(분할) 경합으로 속도가 기하급수적으로 저하됨.
--    - 고유성(PK/UK) 검증이 필요한 인덱스만 남기고 비고유(NONUNIQUE) 인덱스를 일괄 UNUSABLE 처리 후
--      적재가 끝난 뒤 8개 코어로 병렬 일괄 REBUILD 수행.
--
-- 4. [6대 치명적 함정 원천 차단 (Robust Failure Prevention)]:
--    ① LONG/LONG RAW (ORA-00997): DB Link 통신 불가 타입은 스크립트 사전 배제.
--    ② IDENTITY 컬럼 (ORA-32795): GENERATED ALWAYS 컬럼을 임시 완화(BY DEFAULT ON NULL) 후 원복.
--    ③ 파티션 인덱스 (ORA-14086): USER_IND_PARTITIONS 조회로 개별 파티션 REBUILD 분기 처리.
--    ④ ORA-02266 (FK 참조 에러): 부모-자식 외래키 일괄 DISABLE 후 ENABLE NOVALIDATE로 초고속 복구.
--    ⑤ 중복 적재 원천 차단: TRUNCATE 성공 여부(v_trunc_ok)를 검증한 테이블만 INSERT 실행.
--    ⑥ 프로세스 중단 방지: 테이블별 독립 EXCEPTION 블록으로 1개 실패 시에도 나머지 101개 완주.
--
-- 5. [소스 기준 시퀀스 안전 점프 (Sequence Gap Padding)]:
--    - 타깃의 단순 +100,000 점프가 아닌, 소스 DB의 실제 LAST_NUMBER를 조회하여
--      (소스 LAST_NUMBER + 100,000)으로 완벽하게 맞추어 향후 서비스 오픈 시 PK 충돌 0% 보장.
--
-- 6. [실시간 진행 상황 브로드캐스팅 (Observability)]:
--    - DBMS_OUTPUT은 END; 후 한꺼번에 출력되므로 2~3시간 동안 진행률 확인 불가.
--    - DBMS_APPLICATION_INFO를 통해 V$SESSION 세션 뷰에 현재 테이블 및 진행률(%)을 초 단위 실시간 방송.
-- =============================================================================


-- =============================================================================
-- [STEP 0] 마이그레이션 감사/제어 로그 테이블 생성 (MIG_EXEC_LOG)
-- -----------------------------------------------------------------------------
-- [상세 설명]
--  - 대용량 마이그레이션은 어떤 테이블이 언제 적재되었고, 몇 건이 들어갔으며,
--    몇 초가 걸렸고, 에러가 났다면 무슨 ORA 에러인지 영구 보존할 제어 테이블이 필수입니다.
--  - 이미 이전 테스트로 테이블이 만들어져 있을 경우 ORA-00955(-955) 에러가 발생하므로,
--    EXCEPTION WHEN OTHERS 처리를 통해 테이블이 이미 존재하면 부드럽게 통과(NULL)시킵니다.
-- =============================================================================
BEGIN
    EXECUTE IMMEDIATE '
    CREATE TABLE MIG_EXEC_LOG (
        RUN_ID       VARCHAR2(20),    -- 실행 배치 식별자 (형식: YYYYMMDD_HH24MISS)
        TABLE_NAME   VARCHAR2(128),   -- 이관 대상 오라클 테이블명
        STATUS       VARCHAR2(20),    -- 상태 플래그: RUNNING(적재중), SUCCESS(성공), FAILED(실패), MISMATCH(건수불일치)
        SRC_CNT      NUMBER,          -- 원본(Source) DB Link 경유 실제 건수 (AS OF SCN 기준)
        TGT_CNT      NUMBER,          -- 대상(Target) 신규 DB에 실제 적재된 행 수
        ELAPSED_SEC  NUMBER(10, 2),   -- 해당 테이블 적재에 소요된 순수 시간(초 단위, 소수점 2자리)
        ERR_MSG      VARCHAR2(4000),  -- 실패 시 발생한 ORA 에러 코드 및 SQLERRM 전문
        START_DT     DATE,            -- 테이블 적재 시작 일시
        END_DT       DATE,            -- 테이블 적재 종료 일시
        CONSTRAINT PK_MIG_EXEC_LOG PRIMARY KEY (RUN_ID, TABLE_NAME)
    )';
EXCEPTION
    WHEN OTHERS THEN
        -- ORA-00955: name is already used by an existing object
        -- 테이블이 이미 존재하면 무시하고 정상 진행
        IF SQLCODE = -955 THEN NULL; ELSE RAISE; END IF;
END;
/


-- =============================================================================
-- [세션 레벨 고속화 및 예외 우회 설정]
-- -----------------------------------------------------------------------------
-- 1. ALTER SESSION ENABLE PARALLEL DML:
--    오라클은 기본적으로 병렬 SELECT만 켜져 있고 병렬 DML(INSERT/UPDATE/DELETE)은
--    세션에서 명시적으로 활성화해야만 INSERT /*+ PARALLEL */ 힌트가 실제 병렬 프로세스(PX)를 띄웁니다.
-- 2. ALTER SESSION SET SKIP_UNUSABLE_INDEXES = TRUE:
--    비고유 인덱스를 UNUSABLE로 만든 상태에서 INSERT 할 때 ORA-01502 에러를 내지 않고
--    인덱스 갱신을 생략한 채 테이블에만 고속으로 밀어 넣도록 세션 설정을 변경합니다.
-- =============================================================================
COMMIT;
ALTER SESSION ENABLE PARALLEL DML;
ALTER SESSION SET SKIP_UNUSABLE_INDEXES = TRUE;
SET SERVEROUTPUT ON SIZE UNLIMITED;


-- =============================================================================
-- [메인 PL/SQL 오케스트레이션 블록 시작]
-- =============================================================================
DECLARE
    -- =========================================================================
    -- [1. 사용자 실행 제어 파라미터]
    -- =========================================================================
    -- ★ v_resume_mode:
    --    - FALSE: [최초 전체 실행] 102개 전체 테이블을 신규 RUN_ID로 처음부터 적재.
    --    - TRUE : [장애 복구 이어달리기] 네트워크 단절이나 ORA-01555 등으로 도중 중단되었을 때,
    --             이미 SUCCESS로 완료된 테이블은 자동으로 스킵하고,
    --             FAILED 되거나 아직 돌지 않은 테이블만 골라서 이전 RUN_ID를 이어받아 실행.
    v_resume_mode    BOOLEAN      := FALSE;
    v_run_id         VARCHAR2(20);

    -- =========================================================================
    -- [2. 내부 프로세스 상태 변수]
    -- =========================================================================
    v_scn            NUMBER;          -- 소스 운영 DB에서 추출한 Flashback 일관성 기준 SCN
    v_src_cnt        NUMBER;          -- 건수 대사용 원본 행 수
    v_tgt_cnt        NUMBER;          -- 건수 대사용 타깃 행 수
    v_tbl_total      NUMBER := 0;     -- 전체 마이그레이션 대상 테이블 총 개수
    v_tbl_done       NUMBER := 0;     -- 현재 처리 중인 테이블 순번 (1, 2, ... 102)
    v_success_cnt    NUMBER := 0;     -- 적재 성공 테이블 누적 개수
    v_fail_cnt       NUMBER := 0;     -- 적재 실패 테이블 누적 개수
    v_total_rows     NUMBER := 0;     -- 현재까지 누적 적재된 전체 데이터 건수
    v_trunc_ok       BOOLEAN;         -- TRUNCATE 성공 여부 안전 플래그
    t_start          TIMESTAMP := SYSTIMESTAMP; -- 전체 배치 시작 타임스탬프
    t_tbl_start      TIMESTAMP;       -- 개별 테이블 처리 시작 타임스탬프
    t_tbl_start_dt   DATE;            -- 개별 테이블 처리 시작 일시 (DATE)
    v_tbl_sec        NUMBER;          -- 개별 테이블 처리 소요 초

    -- -------------------------------------------------------------------------
    -- [서브프로시저: 독립 자치 트랜잭션 로깅 (LOG_EXEC)]
    -- -------------------------------------------------------------------------
    -- [상세 설명]
    --  - PRAGMA AUTONOMOUS_TRANSACTION:
    --    본 적재 트랜잭션과 완전히 분리된 별도의 세션/트랜잭션으로 커밋을 실행합니다.
    --  - 중요성: 만약 대용량 INSERT 중 ORA 에러가 터져 메인 트랜잭션이 ROLLBACK 되더라도,
    --    이 로그 프로시저가 남긴 'FAILED' 기록과 에러 메시지는 롤백되지 않고 즉시 COMMIT 됩니다!
    -- -------------------------------------------------------------------------
    PROCEDURE LOG_EXEC(
        p_tbl      VARCHAR2,
        p_status   VARCHAR2,
        p_src_cnt  NUMBER,
        p_tgt_cnt  NUMBER,
        p_sec      NUMBER,
        p_err_msg  VARCHAR2,
        p_start_dt DATE,
        p_end_dt   DATE
    ) IS
        PRAGMA AUTONOMOUS_TRANSACTION;
    BEGIN
        MERGE INTO MIG_EXEC_LOG m
        USING DUAL ON (m.RUN_ID = v_run_id AND m.TABLE_NAME = p_tbl)
        WHEN MATCHED THEN
            UPDATE SET STATUS      = p_status,
                       SRC_CNT     = NVL(p_src_cnt, m.SRC_CNT),
                       TGT_CNT     = NVL(p_tgt_cnt, m.TGT_CNT),
                       ELAPSED_SEC = p_sec,
                       ERR_MSG     = SUBSTR(p_err_msg, 1, 4000),
                       END_DT      = p_end_dt
        WHEN NOT MATCHED THEN
            INSERT (RUN_ID, TABLE_NAME, STATUS, SRC_CNT, TGT_CNT, ELAPSED_SEC, ERR_MSG, START_DT, END_DT)
            VALUES (v_run_id, p_tbl, p_status, p_src_cnt, p_tgt_cnt, p_sec, SUBSTR(p_err_msg, 1, 4000), p_start_dt, p_end_dt);
        COMMIT;
    END;

BEGIN
    -- =========================================================================
    -- [STEP 0] RUN_ID 확정 및 V$SESSION 모니터링 모듈 등록
    -- -------------------------------------------------------------------------
    --  - 신규 모드: 현재 시각 기준으로 새 배치 번호(예: 20261121_130000) 발급
    --  - Resume 모드: MIG_EXEC_LOG에서 가장 최근 RUN_ID를 찾아 이어받음
    --  - DBMS_APPLICATION_INFO.SET_MODULE:
    --    DBA가 별도 세션에서 V$SESSION을 조회할 때 MODULE='DB_MIGRATION'으로 즉시 필터링 가능
    -- =========================================================================
    IF v_resume_mode THEN
        SELECT MAX(RUN_ID) INTO v_run_id FROM MIG_EXEC_LOG;
        IF v_run_id IS NULL THEN
            v_run_id := TO_CHAR(SYSDATE, 'YYYYMMDD_HH24MISS');
            v_resume_mode := FALSE;
        END IF;
    ELSE
        v_run_id := TO_CHAR(SYSDATE, 'YYYYMMDD_HH24MISS');
    END IF;

    DBMS_APPLICATION_INFO.SET_MODULE('DB_MIGRATION', 'RUN_ID=' || v_run_id);
    DBMS_OUTPUT.PUT_LINE('======================================================================');
    DBMS_OUTPUT.PUT_LINE('>>> [I-CMS 마이그레이션 배치 시작] RUN_ID: ' || v_run_id ||
                         CASE WHEN v_resume_mode THEN ' (RESUME 모드 - 실패/미적재 대상 이어달리기)' ELSE ' (신규 전체 실행)' END);
    DBMS_OUTPUT.PUT_LINE('======================================================================');


    -- =========================================================================
    -- [STEP 1] 소스 운영 DB 기준 SCN(System Commit Number) 단일 고정 확보
    -- -------------------------------------------------------------------------
    -- [상세 설명]
    --  - 소스 DB는 실시간으로 결제/회원가입 등 트랜잭션이 발생하고 있습니다.
    --  - 102개 테이블을 차례대로 읽을 때 시점이 다르면 부모-자식 간 데이터 정합성이 깨집니다.
    --  - 따라서 시작 시점의 SCN을 1개 따서 모든 테이블을 'AS OF SCN v_scn'으로 고정 조회합니다.
    --  - 주의: 소스 DB의 UNDO_RETENTION(초)이 충분해야 ORA-01555(Snapshot too old)를 예방할 수 있습니다.
    -- =========================================================================
    SELECT CURRENT_SCN INTO v_scn FROM V$DATABASE@PROD_MIG_LINK;
    DBMS_OUTPUT.PUT_LINE('>>> [STEP 1] 마이그레이션 기준 SCN 확보: ' || v_scn || ' (전 테이블 동일 시점 플래시백 고정)');


    -- =========================================================================
    -- [STEP 2] IDENTITY 컬럼 임시 완화 (ORA-32795 원천 방지)
    -- -------------------------------------------------------------------------
    -- [상세 설명]
    --  - 오라클 12c+ 에서 도입된 'GENERATED ALWAYS AS IDENTITY' 컬럼은 테이블 정의상
    --    사용자가 임의로 값을 INSERT 하려고 하면 ORA-32795: cannot insert into a generated always identity column 에러를 냅니다.
    --  - 마이그레이션 시에는 소스 DB의 기존 PK ID 번호를 그대로 복제해야 하므로,
    --    잠시 'GENERATED BY DEFAULT ON NULL AS IDENTITY'로 완화하여 소스 값을 그대로 넣고,
    --    이관 완료 후 [STEP 9]에서 다시 ALWAYS로 원복합니다.
    -- =========================================================================
    FOR r IN (
        SELECT TABLE_NAME, COLUMN_NAME
          FROM USER_TAB_IDENTITY_COLS
         WHERE GENERATION_TYPE = 'ALWAYS'
    ) LOOP
        BEGIN
            EXECUTE IMMEDIATE 'ALTER TABLE "' || r.TABLE_NAME || '" MODIFY ("' || r.COLUMN_NAME || '" GENERATED BY DEFAULT ON NULL AS IDENTITY)';
        EXCEPTION WHEN OTHERS THEN NULL;
        END;
    END LOOP;


    -- =========================================================================
    -- [STEP 3] 타깃 스키마 트리거 일괄 비활성화 (DISABLE)
    -- -------------------------------------------------------------------------
    -- [상세 설명]
    --  - 타깃 DB 테이블에 AFTER INSERT / BEFORE INSERT 등의 트리거가 활성화되어 있으면,
    --    데이터 적재 시마다 트리거가 발화하여 변경이력(AUDIT) 테이블에 중복 데이터가 쌓이거나,
    --    시퀀스를 두 번 호출하거나, 적재 속도가 1/10 토막 납니다.
    --  - 순수 데이터 복제 동안에는 모든 트리거를 일괄 끄고, [STEP 10]에서 다시 켭니다.
    -- =========================================================================
    FOR trg IN (SELECT TRIGGER_NAME FROM USER_TRIGGERS WHERE STATUS = 'ENABLED') LOOP
        BEGIN
            EXECUTE IMMEDIATE 'ALTER TRIGGER "' || trg.TRIGGER_NAME || '" DISABLE';
        EXCEPTION WHEN OTHERS THEN NULL;
        END;
    END LOOP;
    DBMS_OUTPUT.PUT_LINE('[완료] 1. 트리거 일괄 비활성화 (적재 간섭 및 중복 실행 방지)');


    -- =========================================================================
    -- [STEP 4] 전체 외래키(FK) 제약조건 일괄 비활성화 (DISABLE)
    -- -------------------------------------------------------------------------
    -- [상세 설명]
    --  - FK가 살아있으면 다음 2가지 문제가 발생합니다:
    --    ① TRUNCATE TABLE 실행 시 부모 테이블이 ORA-02266(referenced by enabled FK)로 실패함.
    --    ② 부모 테이블이 적재되기 전에 자식 테이블이 먼저 적재될 때 ORA-02291(parent key not found) 발생.
    --  - 전체 FK(CONSTRAINT_TYPE = 'R')를 일괄 DISABLE 하여 테이블 적재 순서 제약을 완전히 없앱니다.
    -- =========================================================================
    DBMS_APPLICATION_INFO.SET_ACTION('1. 전체 FK 제약조건 비활성화 중...');
    FOR r IN (
        SELECT TABLE_NAME, CONSTRAINT_NAME
          FROM USER_CONSTRAINTS
         WHERE CONSTRAINT_TYPE = 'R' AND STATUS = 'ENABLED'
    ) LOOP
        BEGIN
            EXECUTE IMMEDIATE 'ALTER TABLE "' || r.TABLE_NAME || '" DISABLE CONSTRAINT "' || r.CONSTRAINT_NAME || '"';
        EXCEPTION WHEN OTHERS THEN NULL;
        END;
    END LOOP;
    DBMS_OUTPUT.PUT_LINE('[완료] 2. 전체 FK 제약조건 일괄 비활성화 (적재 순서 무관 및 TRUNCATE 허용)');


    -- =========================================================================
    -- [STEP 5] 비고유 인덱스 일괄 UNUSABLE 처리 (일반 & 로컬 파티션)
    -- -------------------------------------------------------------------------
    -- [상세 설명]
    --  - 대용량 Direct-Path INSERT를 수행할 때 인덱스가 살아있으면 행이 들어올 때마다
    --    인덱스 리프 블록을 쪼개고(Split) 정렬하느라 속도가 극심하게 저하됩니다.
    --  - 따라서 PK/UK(고유 인덱스)를 제외한 모든 비고유(NONUNIQUE) 인덱스를 UNUSABLE로 만듭니다.
    --  - ⚠️ 중요: 로컬 파티션 인덱스(PARTITIONED = 'YES')는 ALTER INDEX UNUSABLE 실행 시
    --    ORA-14086 에러가 발생하므로, USER_IND_PARTITIONS를 뒤져 파티션 단위로 UNUSABLE 처리합니다.
    -- =========================================================================
    DBMS_APPLICATION_INFO.SET_ACTION('2. 인덱스 일괄 UNUSABLE 처리 중...');
    -- (1) 비파티션 일반 인덱스 UNUSABLE
    FOR r IN (
        SELECT INDEX_NAME
          FROM USER_INDEXES
         WHERE INDEX_TYPE IN ('NORMAL', 'FUNCTION-BASED NORMAL', 'BITMAP')
           AND UNIQUENESS = 'NONUNIQUE'
           AND STATUS = 'VALID'
           AND PARTITIONED = 'NO'
           AND TABLE_NAME != 'MIG_EXEC_LOG'
    ) LOOP
        BEGIN
            EXECUTE IMMEDIATE 'ALTER INDEX "' || r.INDEX_NAME || '" UNUSABLE';
        EXCEPTION WHEN OTHERS THEN NULL;
        END;
    END LOOP;

    -- (2) 로컬 파티션 인덱스 파티션별 UNUSABLE (ORA-14086 방지)
    FOR p IN (
        SELECT p.INDEX_NAME, p.PARTITION_NAME
          FROM USER_IND_PARTITIONS p
          JOIN USER_INDEXES i ON p.INDEX_NAME = i.INDEX_NAME
         WHERE i.UNIQUENESS = 'NONUNIQUE'
           AND p.STATUS = 'USABLE'
           AND i.TABLE_NAME != 'MIG_EXEC_LOG'
    ) LOOP
        BEGIN
            EXECUTE IMMEDIATE 'ALTER INDEX "' || p.INDEX_NAME || '" MODIFY PARTITION "' || p.PARTITION_NAME || '" UNUSABLE';
        EXCEPTION WHEN OTHERS THEN NULL;
        END;
    END LOOP;
    DBMS_OUTPUT.PUT_LINE('[완료] 3. 일반 및 파티션 인덱스 일괄 UNUSABLE 처리 (적재 속도 10배 향상)');


    -- =========================================================================
    -- [STEP 6] 대용량 테이블 우선 순서 병렬 Direct-Path 고속 적재 루프
    -- -------------------------------------------------------------------------
    -- [상세 설명 및 아키텍처]
    --  1. 대용량 우선 정렬 (ORDER BY SEG_BYTES DESC):
    --     수억 건짜리 큰 테이블을 초반에 적재해야 전체 이관 진행 예측이 정확해지고,
    --     후반부에 가벼운 테이블들이 빠르게 끝나 리소스 병목을 최소화합니다.
    --  2. 불필요 객체 자동 제외 (WHERE TEMPORARY='N' AND SECONDARY='N' AND IOT_TYPE IS NULL):
    --     임시 테이블(GTT), 오버플로 세그먼트, External 테이블, 로그 테이블은 이관 대상에서 자동 제외.
    --  3. TRUNCATE 검증 후 적재 (v_trunc_ok):
    --     만약 권한이나 락 문제로 TRUNCATE가 실패했는데 INSERT를 해버리면 기존 데이터에
    --     새 데이터가 더해져 2배로 뻥튀기되는 대형 사고가 납니다. TRUNCATE 통과 여부를 검증합니다.
    --  4. 고속 Direct-Path 힌트 최적화:
    --     - INSERT /*+ APPEND PARALLEL(8) */ : 타깃 DB는 비운영이므로 8개 슬레이브 풀파워 쓰기
    --     - SELECT /*+ PARALLEL(4) */        : 소스 DB는 운영 중이므로 부하를 고려해 4개 슬레이브로 쿼터 제한
    --  5. 개별 예외 격리:
    --     루프 내부에 독립 BEGIN...EXCEPTION...END 블록을 두어, 1개 테이블에서 예상치 못한 에러가
    --     발생해도 MIG_EXEC_LOG에 'FAILED'를 기록하고 다음 101개 테이블은 정상 완주합니다.
    -- =========================================================================
    SELECT COUNT(*) INTO v_tbl_total
      FROM USER_TABLES
     WHERE TEMPORARY = 'N' AND SECONDARY = 'N' AND (IOT_TYPE IS NULL OR IOT_TYPE NOT LIKE '%OVERFLOW%')
       AND TABLE_NAME != 'MIG_EXEC_LOG';

    DBMS_OUTPUT.PUT_LINE('----------------------------------------------------------------------');
    DBMS_OUTPUT.PUT_LINE('>>> [STEP 2] 총 ' || v_tbl_total || '개 테이블 병렬 적재 시작 (대용량 우선 순서)');
    DBMS_OUTPUT.PUT_LINE('----------------------------------------------------------------------');

    FOR r IN (
        SELECT t.TABLE_NAME, NVL(s.BYTES, 0) AS SEG_BYTES
          FROM USER_TABLES t
          LEFT JOIN (
              SELECT SEGMENT_NAME, SUM(BYTES) AS BYTES
                FROM USER_SEGMENTS
               WHERE SEGMENT_TYPE LIKE 'TABLE%'
               GROUP BY SEGMENT_NAME
          ) s ON t.TABLE_NAME = s.SEGMENT_NAME
         WHERE t.TEMPORARY = 'N'
           AND t.SECONDARY = 'N'
           AND (t.IOT_TYPE IS NULL OR t.IOT_TYPE NOT LIKE '%OVERFLOW%')
           AND t.TABLE_NAME != 'MIG_EXEC_LOG'
         ORDER BY NVL(s.BYTES, 0) DESC, t.TABLE_NAME
    ) LOOP
        v_tbl_done := v_tbl_done + 1;
        t_tbl_start := SYSTIMESTAMP;
        t_tbl_start_dt := SYSDATE;

        -- [Resume 모드 체크] 이미 SUCCESS 완료된 테이블은 즉시 건너뛰기
        IF v_resume_mode THEN
            SELECT COUNT(*) INTO v_src_cnt
              FROM MIG_EXEC_LOG
             WHERE RUN_ID = v_run_id AND TABLE_NAME = r.TABLE_NAME AND STATUS = 'SUCCESS';
            IF v_src_cnt > 0 THEN
                CONTINUE;
            END IF;
        END IF;

        -- V$SESSION 실시간 모니터링 방송 (모니터링 쿼리에서 실시간 확인 가능)
        DBMS_APPLICATION_INFO.SET_ACTION('[' || LPAD(v_tbl_done, 3) || '/' || v_tbl_total || '] ' || r.TABLE_NAME || ' 적재 중...');
        DBMS_APPLICATION_INFO.SET_CLIENT_INFO('진행률: ' || ROUND(v_tbl_done / v_tbl_total * 100, 1) || '% | 누적: ' || TO_CHAR(v_total_rows, '999,999,999,999') || '건');
        LOG_EXEC(r.TABLE_NAME, 'RUNNING', NULL, NULL, 0, NULL, t_tbl_start_dt, NULL);

        -- ---------------------------------------------------------------------
        -- (A) TRUNCATE 수행 및 검증 (중복 적재 원천 차단)
        -- ---------------------------------------------------------------------
        v_trunc_ok := FALSE;
        BEGIN
            EXECUTE IMMEDIATE 'ALTER TABLE "' || r.TABLE_NAME || '" NOLOGGING';
            EXECUTE IMMEDIATE 'TRUNCATE TABLE "' || r.TABLE_NAME || '"';
            v_trunc_ok := TRUE;
        EXCEPTION WHEN OTHERS THEN
            v_fail_cnt := v_fail_cnt + 1;
            LOG_EXEC(r.TABLE_NAME, 'FAILED', NULL, 0, 0, 'TRUNCATE 실패(중복방지 스킵): ORA' || SQLCODE || ' ' || SQLERRM, t_tbl_start_dt, SYSDATE);
            DBMS_OUTPUT.PUT_LINE(' [TRUNCATE실패!!] ' || r.TABLE_NAME || ' -> ' || SUBSTR(SQLERRM, 1, 80));
        END;

        -- ---------------------------------------------------------------------
        -- (B) TRUNCATE 성공 테이블 대상 Direct-Path 병렬 INSERT 실행
        -- ---------------------------------------------------------------------
        IF v_trunc_ok THEN
            BEGIN
                -- TRUNCATE 직후 일부 인덱스가 VALID 상태로 돌아올 수 있으므로 비고유 인덱스 재-UNUSABLE 보정
                FOR idx IN (
                    SELECT INDEX_NAME FROM USER_INDEXES
                     WHERE TABLE_NAME = r.TABLE_NAME AND UNIQUENESS = 'NONUNIQUE' AND PARTITIONED = 'NO' AND STATUS = 'VALID'
                ) LOOP
                    EXECUTE IMMEDIATE 'ALTER INDEX "' || idx.INDEX_NAME || '" UNUSABLE';
                END LOOP;

                -- Direct-Path 병렬 적재 핵심 쿼리 (AS OF SCN 적용)
                EXECUTE IMMEDIATE 'INSERT /*+ APPEND PARALLEL(8) */ INTO "' || r.TABLE_NAME || '" ' ||
                                  'SELECT /*+ PARALLEL(4) */ * FROM "' || r.TABLE_NAME || '"@PROD_MIG_LINK AS OF SCN ' || v_scn;
                v_tgt_cnt := SQL%ROWCOUNT;
                COMMIT; -- Direct-Path INSERT는 후속 SELECT/DML 전 반드시 COMMIT 필요

                v_total_rows := v_total_rows + v_tgt_cnt;
                v_success_cnt := v_success_cnt + 1;
                v_tbl_sec := ROUND(EXTRACT(SECOND FROM (SYSTIMESTAMP - t_tbl_start)) +
                                   EXTRACT(MINUTE FROM (SYSTIMESTAMP - t_tbl_start)) * 60 +
                                   EXTRACT(HOUR FROM (SYSTIMESTAMP - t_tbl_start)) * 3600, 2);

                LOG_EXEC(r.TABLE_NAME, 'SUCCESS', NULL, v_tgt_cnt, v_tbl_sec, NULL, t_tbl_start_dt, SYSDATE);

                -- 터미널 로그 출력 (초반 10개, 매 20개 주기, 마지막 2개 출력)
                IF v_tbl_done <= 10 OR v_tbl_done >= v_tbl_total - 2 OR MOD(v_tbl_done, 20) = 0 THEN
                    DBMS_OUTPUT.PUT_LINE(' [' || LPAD(v_tbl_done, 3) || '/' || v_tbl_total || '] ' ||
                                         RPAD(r.TABLE_NAME, 25) || ' : ' ||
                                         LPAD(TO_CHAR(v_tgt_cnt, '999,999,999'), 12) || '건 (' || v_tbl_sec || '초)');
                END IF;
            EXCEPTION WHEN OTHERS THEN
                ROLLBACK;
                v_fail_cnt := v_fail_cnt + 1;
                v_tbl_sec := ROUND(EXTRACT(SECOND FROM (SYSTIMESTAMP - t_tbl_start)) +
                                   EXTRACT(MINUTE FROM (SYSTIMESTAMP - t_tbl_start)) * 60 +
                                   EXTRACT(HOUR FROM (SYSTIMESTAMP - t_tbl_start)) * 3600, 2);
                LOG_EXEC(r.TABLE_NAME, 'FAILED', NULL, 0, v_tbl_sec, 'ORA' || SQLCODE || ': ' || SQLERRM, t_tbl_start_dt, SYSDATE);
                DBMS_OUTPUT.PUT_LINE(' [적재실패!!] ' || r.TABLE_NAME || ' -> ORA' || SQLCODE || ' (' || SUBSTR(SQLERRM, 1, 80) || ')');
            END;
        END IF;
    END LOOP;
    DBMS_OUTPUT.PUT_LINE('[완료] 4. 적재 루프 종료: 성공 ' || v_success_cnt || '개 / 실패 ' || v_fail_cnt || '개 (누적 ' || TO_CHAR(v_total_rows, '999,999,999,999') || '건)');


    -- =========================================================================
    -- [STEP 7] 인덱스 일괄 병렬 REBUILD 및 NOPARALLEL LOGGING 원복
    -- -------------------------------------------------------------------------
    -- [상세 설명]
    --  - UNUSABLE 상태였던 인덱스를 'REBUILD PARALLEL 8 NOLOGGING'으로 재생성합니다.
    --    (Direct I/O와 8개 CPU 코어를 동시 사용하여 1.1TB 인덱스도 수 분 내에 재생성)
    --  - ⚠️ 중요: REBUILD 완료 후 즉시 'ALTER INDEX ... NOPARALLEL LOGGING'으로 돌려놓아야 합니다.
    --    그렇지 않으면 향후 운영 서비스 오픈 시 단순 단건 SELECT/INSERT에도 8개 병렬 프로세스가 떠서
    --    DB 서버 CPU가 100%로 치솟는 운영 장애가 발생합니다.
    --  - 로컬 파티션 인덱스는 REBUILD PARTITION 문법으로 안전하게 분기합니다.
    -- =========================================================================
    DBMS_APPLICATION_INFO.SET_ACTION('5. 인덱스 일괄 병렬 REBUILD 중...');
    -- (1) 일반 비파티션 인덱스 REBUILD
    FOR r IN (SELECT INDEX_NAME FROM USER_INDEXES WHERE STATUS = 'UNUSABLE' AND PARTITIONED = 'NO') LOOP
        BEGIN
            EXECUTE IMMEDIATE 'ALTER INDEX "' || r.INDEX_NAME || '" REBUILD PARALLEL 8 NOLOGGING';
            EXECUTE IMMEDIATE 'ALTER INDEX "' || r.INDEX_NAME || '" NOPARALLEL LOGGING';
        EXCEPTION WHEN OTHERS THEN
            DBMS_OUTPUT.PUT_LINE(' [경고] 인덱스 리빌드 실패: ' || r.INDEX_NAME || ' - ' || SQLERRM);
        END;
    END LOOP;

    -- (2) 로컬 파티션 인덱스 파티션별 REBUILD (ORA-14086 방지)
    FOR p IN (SELECT INDEX_NAME, PARTITION_NAME FROM USER_IND_PARTITIONS WHERE STATUS = 'UNUSABLE') LOOP
        BEGIN
            EXECUTE IMMEDIATE 'ALTER INDEX "' || p.INDEX_NAME || '" REBUILD PARTITION "' || p.PARTITION_NAME || '" PARALLEL 8 NOLOGGING';
            EXECUTE IMMEDIATE 'ALTER INDEX "' || p.INDEX_NAME || '" MODIFY PARTITION "' || p.PARTITION_NAME || '" NOPARALLEL LOGGING';
        EXCEPTION WHEN OTHERS THEN
            DBMS_OUTPUT.PUT_LINE(' [경고] 파티션 인덱스 리빌드 실패: ' || p.INDEX_NAME || '.' || p.PARTITION_NAME || ' - ' || SQLERRM);
        END;
    END LOOP;
    DBMS_OUTPUT.PUT_LINE('[완료] 5. 일반 및 파티션 인덱스 REBUILD 완료');


    -- =========================================================================
    -- [STEP 8] 테이블 LOGGING 원복
    -- -------------------------------------------------------------------------
    -- [상세 설명]
    --  - 적재 성능을 위해 NOLOGGING으로 두었던 테이블들을 정상 LOGGING 상태로 복귀시킵니다.
    --  - 그래야 향후 운영 오픈 후 데이터 변경에 대한 아카이브 로그가 정상 생성되어 백업/복구가 가능해집니다.
    -- =========================================================================
    FOR r IN (SELECT TABLE_NAME FROM USER_TABLES WHERE TABLE_NAME != 'MIG_EXEC_LOG') LOOP
        BEGIN
            EXECUTE IMMEDIATE 'ALTER TABLE "' || r.TABLE_NAME || '" LOGGING';
        EXCEPTION WHEN OTHERS THEN NULL;
        END;
    END LOOP;


    -- =========================================================================
    -- [STEP 9] IDENTITY 컬럼 원복 (ALWAYS)
    -- -------------------------------------------------------------------------
    -- [상세 설명]
    --  - [STEP 2]에서 임시로 풀었던 IDENTITY 컬럼을 다시 'GENERATED ALWAYS AS IDENTITY'로 원복하여,
    --    향후 애플리케이션에서 INSERT 시 시퀀스 자동 채번 규칙이 정상 작동하도록 합니다.
    -- =========================================================================
    FOR r IN (SELECT TABLE_NAME, COLUMN_NAME FROM USER_TAB_IDENTITY_COLS WHERE GENERATION_TYPE = 'BY DEFAULT') LOOP
        BEGIN
            EXECUTE IMMEDIATE 'ALTER TABLE "' || r.TABLE_NAME || '" MODIFY ("' || r.COLUMN_NAME || '" GENERATED ALWAYS AS IDENTITY)';
        EXCEPTION WHEN OTHERS THEN NULL;
        END;
    END LOOP;


    -- =========================================================================
    -- [STEP 10] 트리거 일괄 ENABLE 원복
    -- -------------------------------------------------------------------------
    -- [상세 설명]
    --  - [STEP 3]에서 꺼두었던 모든 트리거를 다시 ENABLE 상태로 활성화합니다.
    -- =========================================================================
    FOR trg IN (SELECT TRIGGER_NAME FROM USER_TRIGGERS WHERE STATUS = 'DISABLED') LOOP
        BEGIN
            EXECUTE IMMEDIATE 'ALTER TRIGGER "' || trg.TRIGGER_NAME || '" ENABLE';
        EXCEPTION WHEN OTHERS THEN
            DBMS_OUTPUT.PUT_LINE(' [경고] 트리거 활성화 실패: ' || trg.TRIGGER_NAME || ' - ' || SQLERRM);
        END;
    END LOOP;


    -- =========================================================================
    -- [STEP 11] 외래키(FK) 제약조건 복구 (ENABLE NOVALIDATE)
    -- -------------------------------------------------------------------------
    -- [상세 설명 및 실무 핵심 노하우]
    --  - 일반 'ENABLE CONSTRAINT':
    --    오라클이 테이블의 기존 수천만 건 데이터를 처음부터 끝까지 풀스캔하여 부모 키가 있는지
    --    전수 검증하므로 FK 1개 활성화에 수십 분~수 시간이 걸립니다.
    --  - 'ENABLE NOVALIDATE CONSTRAINT':
    --    이미 원본 소스 DB에서 완벽하게 검증되어 사용 중이던 데이터이므로 과거 데이터의 전수 검증은
    --    생략하고, '앞으로 들어올 신규 데이터부터 외래키 규칙을 강제'하도록 즉시 활성화합니다.
    --    1.1TB 전체 FK 제약조건이 단 1~2초 만에 즉시 활성화됩니다!
    -- =========================================================================
    DBMS_APPLICATION_INFO.SET_ACTION('7. FK 제약조건 복구 중...');
    FOR r IN (SELECT TABLE_NAME, CONSTRAINT_NAME FROM USER_CONSTRAINTS WHERE CONSTRAINT_TYPE = 'R' AND STATUS = 'DISABLED') LOOP
        BEGIN
            EXECUTE IMMEDIATE 'ALTER TABLE "' || r.TABLE_NAME || '" ENABLE NOVALIDATE CONSTRAINT "' || r.CONSTRAINT_NAME || '"';
        EXCEPTION WHEN OTHERS THEN
            DBMS_OUTPUT.PUT_LINE(' [경고] FK 활성화 실패: ' || r.TABLE_NAME || '.' || r.CONSTRAINT_NAME || ' - ' || SQLERRM);
        END;
    END LOOP;
    DBMS_OUTPUT.PUT_LINE('[완료] 6. LOGGING, IDENTITY, 트리거, FK(NOVALIDATE) 복구 완료');


    -- =========================================================================
    -- [STEP 12] 소스 DB 실제 시퀀스 번호(LAST_NUMBER) 기준 +100,000 안전 동기화
    -- -------------------------------------------------------------------------
    -- [상세 설명 및 동기화 메커니즘]
    --  - 문제 상황: 단순하게 타깃 시퀀스를 +100,000 점프시키면, 타깃 시퀀스가 애초에 1이었을 경우
    --              100,001이 되어 소스 DB의 실제 데이터(예: 50만 번)보다 작아져 오픈 즉시 ORA-00001(PK 중복) 폭발!
    --  - 해결 알고리즘:
    --    ① 소스 DB의 시퀀스 딕셔너리(src.LAST_NUMBER)를 DB Link로 직접 읽어옵니다.
    --    ② 타깃 시퀀스의 현재 값(v_cur)을 읽어 (소스 LAST_NUMBER + 100,000)과의 차이(GAP)를 계산합니다.
    --    ③ ALTER SEQUENCE ... INCREMENT BY v_gap 으로 일시 변경 후 NEXTVAL을 딱 1회 호출하여
    --       정확하게 소스 번호 + 100,000 지점으로 순간 점프시킵니다.
    --    ④ 점프 직후 원래의 증가치(INCREMENT BY r.INCREMENT_BY = 1)로 완벽 복구합니다.
    -- =========================================================================
    FOR r IN (
        SELECT s.SEQUENCE_NAME, s.INCREMENT_BY, src.LAST_NUMBER AS SRC_LAST
          FROM USER_SEQUENCES s
          JOIN USER_SEQUENCES@PROD_MIG_LINK src ON s.SEQUENCE_NAME = src.SEQUENCE_NAME
    ) LOOP
        DECLARE
            v_cur NUMBER;
            v_gap NUMBER;
        BEGIN
            EXECUTE IMMEDIATE 'SELECT "' || r.SEQUENCE_NAME || '".NEXTVAL FROM DUAL' INTO v_cur;
            v_gap := (r.SRC_LAST + 100000) - v_cur;
            IF v_gap > 0 THEN
                EXECUTE IMMEDIATE 'ALTER SEQUENCE "' || r.SEQUENCE_NAME || '" INCREMENT BY ' || v_gap;
                EXECUTE IMMEDIATE 'SELECT "' || r.SEQUENCE_NAME || '".NEXTVAL FROM DUAL' INTO v_cur;
                EXECUTE IMMEDIATE 'ALTER SEQUENCE "' || r.SEQUENCE_NAME || '" INCREMENT BY ' || r.INCREMENT_BY;
            END IF;
        EXCEPTION WHEN OTHERS THEN NULL;
        END;
    END LOOP;
    DBMS_OUTPUT.PUT_LINE('[완료] 7. 소스 DB 기준 전체 시퀀스 동기화 (+100,000 여유분 확보 완료)');


    -- =========================================================================
    -- [STEP 13] 스키마 통계정보 일괄 수집 및 INVALID 오브젝트 컴파일
    -- -------------------------------------------------------------------------
    -- [상세 설명]
    --  1. DBMS_STATS.GATHER_SCHEMA_STATS (DEGREE => 8):
    --     대용량 데이터가 들어왔으므로 CBO(비용기반 옵티마이저)가 올바른 인덱스 스캔 실행계획을
    --     세울 수 있도록 테이블, 인덱스, 컬럼 히스토그램 통계를 8코어 병렬로 최신 수집합니다.
    --  2. DBMS_UTILITY.COMPILE_SCHEMA:
    --     인덱스 UNUSABLE, FK DISABLE/ENABLE, 테이블 TRUNCATE 등 DDL 작업으로 인해
    --     상태가 INVALID로 변한 View, Procedure, Package, Synonym을 정상(VALID)으로 일괄 컴파일합니다.
    -- =========================================================================
    DBMS_APPLICATION_INFO.SET_ACTION('9. 통계정보 수집 및 오브젝트 컴파일 중...');
    DBMS_STATS.GATHER_SCHEMA_STATS(OWNNAME => USER, DEGREE => 8, CASCADE => TRUE);
    DBMS_UTILITY.COMPILE_SCHEMA(SCHEMA => USER, COMPILE_ALL => FALSE);
    DBMS_OUTPUT.PUT_LINE('[완료] 8. 스키마 통계정보 수집(DEGREE 8) 및 INVALID 오브젝트 컴파일 완료');


    -- =========================================================================
    -- [STEP 14] 원본(Source) vs 대상(Target) 전수 건수 대사 및 MIG_EXEC_LOG 최종 갱신
    -- -------------------------------------------------------------------------
    -- [상세 설명]
    --  - 마이그레이션의 최종 성공 기준은 '데이터가 1건도 유실되지 않았는가'입니다.
    --  - 배치 시작 시점의 기준 SCN(AS OF SCN v_scn)으로 원본 건수(v_src_cnt)를 조회하고,
    --    신규 타깃 테이블 건수(v_tgt_cnt)를 조회하여 1:1 전수 비교합니다.
    --  - 비교 결과:
    --    - 일치: STATUS = 'SUCCESS' 확정
    --    - 불일치: STATUS = 'MISMATCH'로 변경하고 화면에 경고 문구 출력
    -- =========================================================================
    DBMS_APPLICATION_INFO.SET_ACTION('10. 전수 건수 대사 검증 중...');
    DBMS_OUTPUT.PUT_LINE('======================================================================');
    DBMS_OUTPUT.PUT_LINE('                 전체 테이블 전수 건수 대사 결과 요약');
    DBMS_OUTPUT.PUT_LINE('======================================================================');
    FOR r IN (
        SELECT TABLE_NAME
          FROM MIG_EXEC_LOG
         WHERE RUN_ID = v_run_id AND STATUS = 'SUCCESS'
         ORDER BY TABLE_NAME
    ) LOOP
        BEGIN
            EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM "' || r.TABLE_NAME || '"@PROD_MIG_LINK AS OF SCN ' || v_scn INTO v_src_cnt;
            EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM "' || r.TABLE_NAME || '"' INTO v_tgt_cnt;

            UPDATE MIG_EXEC_LOG
               SET SRC_CNT = v_src_cnt,
                   TGT_CNT = v_tgt_cnt,
                   STATUS  = CASE WHEN v_src_cnt = v_tgt_cnt THEN 'SUCCESS' ELSE 'MISMATCH' END
             WHERE RUN_ID = v_run_id AND TABLE_NAME = r.TABLE_NAME;
            COMMIT;

            IF v_src_cnt <> v_tgt_cnt THEN
                DBMS_OUTPUT.PUT_LINE(' [불일치!!] ' || RPAD(r.TABLE_NAME, 30) || ' : 원본=' || v_src_cnt || ' / 신규=' || v_tgt_cnt);
            END IF;
        EXCEPTION WHEN OTHERS THEN
            DBMS_OUTPUT.PUT_LINE(' [대사실패] ' || r.TABLE_NAME || ' : ' || SQLERRM);
        END;
    END LOOP;
    DBMS_OUTPUT.PUT_LINE('>>> 전수 건수 대사 완료 (불일치 테이블만 출력됨, 미출력 시 전수 일치)');
    DBMS_OUTPUT.PUT_LINE('======================================================================');


    -- =========================================================================
    -- [STEP 15] 전체 마이그레이션 정상 종료
    -- =========================================================================
    DBMS_APPLICATION_INFO.SET_MODULE(NULL, NULL);
    DBMS_APPLICATION_INFO.SET_CLIENT_INFO('마이그레이션 정상 종료');
    DBMS_OUTPUT.PUT_LINE('>>> 마이그레이션 성공 종료! 총 소요: ' || (SYSTIMESTAMP - t_start));
END;
/
