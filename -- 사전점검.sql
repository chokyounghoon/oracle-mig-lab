-- =============================================================================
-- [04] 1.1TB 실전 마이그레이션 D-Day 사전/사후 필수 점검 스크립트 모음
-- 파일명 : -- 사전점검.sql
-- 대상   : 소스 운영 DB (PROD_MIG_LINK) 및 신규 타깃 DB (ora-tgt)
-- 목적   : 12월 4일 실전 본 이관 전, 현장에서 반드시 사전에 돌려보고
--          잠재적 장애 요인(LONG 컬럼, IDENTITY, 파티션 인덱스, UNDO 부족 등)을
--          100% 색출하여 제거하기 위한 종합 점검 세트
-- =============================================================================


-- =============================================================================
-- 🔍 [점검 1] 소스 DB 대용량 테이블 TOP 10 용량 및 비중 확인
-- -----------------------------------------------------------------------------
-- [목적] 1.1TB 데이터 중 어떤 테이블이 가장 큰지 사전에 파악하여
--        초반 적재 예상 시간을 산정하고 병목을 사전에 대비합니다.
-- =============================================================================
SELECT SEGMENT_NAME,
       ROUND(SUM(BYTES) / 1024 / 1024 / 1024, 2) AS SIZE_GB,
       ROUND(SUM(BYTES) / (1.1 * 1024 * 1024 * 1024 * 1024) * 100, 1) || '%' AS RATIO_PCT
  FROM USER_SEGMENTS@PROD_MIG_LINK
 WHERE SEGMENT_TYPE LIKE 'TABLE%'
 GROUP BY SEGMENT_NAME
 ORDER BY SIZE_GB DESC
 FETCH FIRST 10 ROWS ONLY;


-- =============================================================================
-- 🚨 [점검 2] LONG / LONG RAW 컬럼 보유 테이블 색출 (ORA-00997 사전 차단)
-- -----------------------------------------------------------------------------
-- [위험성]
--  - 오라클 DB Link는 CLOB/BLOB은 지원하지만, 구형 LONG/LONG RAW 컬럼이 있는 테이블을
--    'INSERT INTO ... SELECT * FROM @DBLINK'로 읽으면 ORA-00997 에러를 내며 즉시 뻗습니다.
-- [조치]
--  - 아래 쿼리에서 검출된 테이블은 my_migration_workflow.sql 루프에서 제외하고,
--    expdp/impdp 네트워크 모드나 SQL*Plus COPY 명령으로 별도 분리 이관해야 합니다.
-- =============================================================================
SELECT TABLE_NAME,
       COLUMN_NAME,
       DATA_TYPE
  FROM USER_TAB_COLUMNS@PROD_MIG_LINK
 WHERE DATA_TYPE IN ('LONG', 'LONG RAW')
 ORDER BY TABLE_NAME, COLUMN_ID;


-- =============================================================================
-- 🆔 [점검 3] GENERATED ALWAYS AS IDENTITY 컬럼 보유 테이블 확인 (ORA-32795 대비)
-- -----------------------------------------------------------------------------
-- [위험성]
--  - GENERATED ALWAYS 컬럼은 수동 값 INSERT 시 ORA-32795 에러를 유발합니다.
--  - 타깃 DB에 해당 컬럼이 있는지 확인하고, 워크플로우 [STEP 2]의 임시 완화 로직이
--    정상 적용되는지 사전에 검토합니다.
-- =============================================================================
SELECT TABLE_NAME,
       COLUMN_NAME,
       GENERATION_TYPE,
       IDENTITY_OPTIONS
  FROM USER_TAB_IDENTITY_COLS
 ORDER BY TABLE_NAME;


-- =============================================================================
-- 📑 [점검 4] 로컬 파티션 인덱스 보유 테이블 확인 (ORA-14086 대비)
-- -----------------------------------------------------------------------------
-- [위험성]
--  - PARTITIONED = 'YES' 인 인덱스는 단순 ALTER INDEX REBUILD 시 ORA-14086 에러 발생.
--  - 워크플로우 [STEP 5], [STEP 7]의 USER_IND_PARTITIONS 분기 처리 대상 목록을 확인합니다.
-- =============================================================================
SELECT TABLE_NAME,
       INDEX_NAME,
       PARTITIONED,
       STATUS
  FROM USER_INDEXES
 WHERE PARTITIONED = 'YES'
 ORDER BY TABLE_NAME, INDEX_NAME;


-- =============================================================================
-- ⏱️ [점검 5] 소스 운영 DB의 UNDO_RETENTION 및 UNDO 테이블스페이스 점검 (ORA-01555 대비)
-- -----------------------------------------------------------------------------
-- [위험성]
--  - 1.1TB 이관이 2~3시간 소요될 때, 소스 DB의 UNDO_RETENTION이 900초(15분)로 짧으면
--    후반부 테이블을 플래시백(AS OF SCN)으로 읽을 때 ORA-01555(Snapshot too old) 폭발!
-- [권장 조치]
--  - 소스 DB DBA에게 요청하여 이관 시작 전 UNDO_RETENTION을 최소 21600초(6시간)로 상향:
--    ALTER SYSTEM SET UNDO_RETENTION = 21600;
-- =============================================================================
SELECT NAME,
       VALUE AS RETENTION_SECONDS,
       ROUND(TO_NUMBER(VALUE) / 3600, 1) || '시간' AS RETENTION_HOURS
  FROM V$PARAMETER@PROD_MIG_LINK
 WHERE NAME = 'undo_retention';


-- =============================================================================
-- 🔗 [점검 6] DB Link (PROD_MIG_LINK) 연결 상태 및 네트워크 RTT 응답속도 측정
-- -----------------------------------------------------------------------------
-- [목적] 타깃 DB에서 소스 DB로의 DB Link 세션이 정상 개설되는지,
--        네트워크 지연이 심하지 않은지 핑(Ping) 성격으로 1회 확인합니다.
-- =============================================================================
SELECT SYSDATE AS LOCAL_TIME,
       s.SOURCE_TIME,
       s.SOURCE_DB_NAME,
       s.CURRENT_SCN
  FROM (
      SELECT SYSDATE AS SOURCE_TIME,
             NAME    AS SOURCE_DB_NAME,
             CURRENT_SCN
        FROM V$DATABASE@PROD_MIG_LINK
  ) s;


-- =============================================================================
-- ❌ [점검 7] 이관 진행 중/종료 후 실패(FAILED) 테이블 및 오류 원인 즉시 조회
-- -----------------------------------------------------------------------------
-- [목적] 이관 중 에러가 발생했을 때 어느 테이블에서 무슨 ORA 에러로 멈췄는지 즉시 파악
-- =============================================================================
SELECT TABLE_NAME,
       STATUS,
       ELAPSED_SEC || '초' AS DURATION,
       ERR_MSG
  FROM MIG_EXEC_LOG
 WHERE STATUS = 'FAILED'
 ORDER BY TABLE_NAME;
