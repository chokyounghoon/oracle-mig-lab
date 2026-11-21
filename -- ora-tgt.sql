-- ora-tgt
-- =============================================================================
-- [ora-tgt] 오라클 마이그레이션 실행 및 단계별 상태확인 워크플로우
-- 대상 환경: localhost:1522/FREEPDB1 (사용자: mig_user / 암호: oracle)
--
-- ※ 테이블명을 건건이 입력하거나 복사할 필요 없이,
--   위에서부터 각 단계별로 커서를 두고 [Ctrl + Enter] 또는 [Cmd + Enter]로 바로 실행하세요!
-- =============================================================================


-- =============================================================================
-- [STEP 0] 세션 병렬 DML 활성화 (최초 1회 실행)
-- =============================================================================
ALTER SESSION ENABLE PARALLEL DML;
ALTER SESSION SET SKIP_UNUSABLE_INDEXES = TRUE;

-- 🔍 [확인 0] 세션 병렬 DML 활성화 상태 확인 (PDML_STATUS = 'ENABLED' 확인)
SELECT SID,
       SERIAL#,
       PDML_STATUS,       -- ★ ENABLED 확인
       PDDL_STATUS,
       PQ_STATUS
  FROM V$SESSION
 WHERE SID = SYS_CONTEXT('USERENV', 'SID');


-- =============================================================================
-- [STEP 1] 18:30 정각: 기준 SCN 조회 및 사전 정리 (FK해제 -> TRUNCATE -> UNUSABLE)
-- =============================================================================

-- 1) 기준 SCN 조회 (이관 시점 정합성 기준점)
SELECT CURRENT_SCN FROM V$DATABASE@PROD_MIG_LINK;


-- 2) FK 제약조건 비활성화 (부모 테이블 검증 부하 제거)
ALTER TABLE TB_CARD_TXN DISABLE CONSTRAINT FK_CARD_CUST;

-- 🔍 [확인 1-2] FK 비활성화 상태 확인 (STATUS = 'DISABLED' 확인)
SELECT TABLE_NAME,
       CONSTRAINT_NAME,
       CONSTRAINT_TYPE,
       STATUS,             -- ★ DISABLED 확인
       VALIDATED
  FROM USER_CONSTRAINTS
 WHERE CONSTRAINT_TYPE = 'R';


-- 3) 테이블 NOLOGGING 전환 및 TRUNCATE (구데이터 정리)
-- ⚠️ [순서 중요] 반드시 아래 4번(인덱스 UNUSABLE) 전에 TRUNCATE를 먼저 실행해야 합니다!
--    (TRUNCATE는 UNUSABLE된 인덱스를 자동으로 빈 상태의 VALID로 리셋해버리기 때문)
ALTER TABLE TB_CARD_TXN NOLOGGING;
TRUNCATE TABLE TB_CARD_TXN;

ALTER TABLE TB_CUST_MST NOLOGGING;
TRUNCATE TABLE TB_CUST_MST;

-- 🔍 [확인 1-3] 테이블 NOLOGGING 적용 및 0건 초기화 확인
SELECT TABLE_NAME,
       LOGGING             -- ★ NO 확인
  FROM USER_TABLES;

SELECT 'TB_CUST_MST' AS TABLE_NAME, COUNT(*) AS ROW_CNT FROM TB_CUST_MST
UNION ALL
SELECT 'TB_CARD_TXN' AS TABLE_NAME, COUNT(*) AS ROW_CNT FROM TB_CARD_TXN;


-- 4) 일반 인덱스 비활성화 (UNUSABLE 처리로 적재 부하 제거, PK는 유지)
ALTER INDEX IDX_TXN_DT UNUSABLE;
ALTER INDEX IDX_TXN_AMT UNUSABLE;
ALTER INDEX IDX_TXN_CUST_ID UNUSABLE;

-- 🔍 [확인 1-4] 인덱스 상태 확인 (일반 인덱스: UNUSABLE / PK 인덱스: VALID 확인)
SELECT TABLE_NAME,
       INDEX_NAME,
       UNIQUENESS,
       STATUS              -- ★ IDX_...는 UNUSABLE / PK_...는 VALID 확인
  FROM USER_INDEXES
 ORDER BY TABLE_NAME, INDEX_NAME;


-- =============================================================================
-- [STEP 2] 18:45 실행: Direct-Path 병렬 고속 적재 (INSERT /*+ APPEND */)
-- =============================================================================
-- 부모 테이블(TB_CUST_MST: 1만건) 먼저 적재 후 자식 테이블(TB_CARD_TXN: 50만건) 적재

-- 1) 고객 마스터 적재
INSERT /*+ APPEND PARALLEL(4) */ INTO TB_CUST_MST
SELECT /*+ PARALLEL(4) */ * FROM TB_CUST_MST@PROD_MIG_LINK;
COMMIT;

-- 2) 카드 거래내역 적재
INSERT /*+ APPEND PARALLEL(4) */ INTO TB_CARD_TXN
SELECT /*+ PARALLEL(4) */ * FROM TB_CARD_TXN@PROD_MIG_LINK;
COMMIT;

-- -----------------------------------------------------------------------------
-- 🔍 [확인 2-1] INSERT 실행 중 실시간 진행률(Progress %) 모니터링 (다른 탭에서 조회)
-- -----------------------------------------------------------------------------
SELECT OPNAME,
       TARGET,
       SOFAR,
       TOTALWORK,
       ROUND(SOFAR / DECODE(TOTALWORK, 0, 1, TOTALWORK) * 100, 2) AS PCT_DONE,  -- 진행률(%)
       TIME_REMAINING AS REMAIN_SEC,                                            -- 남은 시간(초)
       ELAPSED_SECONDS AS ELAPSED_SEC,                                          -- 경과 시간(초)
       MESSAGE
  FROM V$SESSION_LONGOPS
 WHERE TIME_REMAINING > 0 OR SOFAR != TOTALWORK
 ORDER BY START_TIME DESC;

-- 🔍 [확인 2-2] 현재 작동 중인 병렬 프로세스(PX Server) 확인
SELECT QCSID,
       SERVER_GROUP,
       SERVER_SET,
       SERVER_NUM,
       DEGREE,
       REQ_DEGREE
  FROM V$PX_SESSION;

-- 🔍 [확인 2-3] 데이터 적재 완료 건수 즉시 확인 (1만 건 / 50만 건)
SELECT 'TB_CUST_MST' AS TABLE_NAME, COUNT(*) AS ROW_CNT FROM TB_CUST_MST
UNION ALL
SELECT 'TB_CARD_TXN' AS TABLE_NAME, COUNT(*) AS ROW_CNT FROM TB_CARD_TXN;


-- =============================================================================
-- [STEP 3] 19:45 실행: 인덱스 REBUILD · 제약조건 복구 · 시퀀스 상향 · 통계수집
-- =============================================================================

-- 1) UNUSABLE 인덱스 고속 병렬 REBUILD 및 LOGGING 원복
ALTER INDEX IDX_TXN_DT REBUILD PARALLEL 8 NOLOGGING;
ALTER INDEX IDX_TXN_DT NOPARALLEL LOGGING;

ALTER INDEX IDX_TXN_AMT REBUILD PARALLEL 8 NOLOGGING;
ALTER INDEX IDX_TXN_AMT NOPARALLEL LOGGING;

ALTER INDEX IDX_TXN_CUST_ID REBUILD PARALLEL 8 NOLOGGING;
ALTER INDEX IDX_TXN_CUST_ID NOPARALLEL LOGGING;

-- 🔍 [확인 3-1] 모든 인덱스가 다시 'VALID' 상태로 복구되었는지 확인
SELECT TABLE_NAME,
       INDEX_NAME,
       UNIQUENESS,
       STATUS,             -- ★ 5개 인덱스 모두 'VALID' 확인
       LOGGING             -- ★ 'YES' 확인
  FROM USER_INDEXES
 ORDER BY TABLE_NAME, INDEX_NAME;


-- 2) 테이블 LOGGING 원복
ALTER TABLE TB_CUST_MST LOGGING;
ALTER TABLE TB_CARD_TXN LOGGING;

-- 🔍 [확인 3-2] 모든 테이블 LOGGING = 'YES' 확인
SELECT TABLE_NAME,
       LOGGING             -- ★ YES 확인
  FROM USER_TABLES;


-- 3) FK 제약조건 복구 (ENABLE NOVALIDATE -> 기존 50만 건 전수 검증 생략하여 0초 완료)
ALTER TABLE TB_CARD_TXN ENABLE NOVALIDATE CONSTRAINT FK_CARD_CUST;

-- 🔍 [확인 3-3] FK 복구 상태 확인 (STATUS='ENABLED', VALIDATED='NOT VALIDATED' 확인)
SELECT TABLE_NAME,
       CONSTRAINT_NAME,
       CONSTRAINT_TYPE,
       STATUS,             -- ★ ENABLED 확인
       VALIDATED           -- ★ NOT VALIDATED 확인
  FROM USER_CONSTRAINTS
 WHERE CONSTRAINT_TYPE = 'R';


-- 4) 2-Track PK 충돌 방지용 시퀀스 일괄 상향 (+100,000 점프)
ALTER SEQUENCE SEQ_CUST_ID INCREMENT BY 100000;
SELECT SEQ_CUST_ID.NEXTVAL FROM DUAL;
ALTER SEQUENCE SEQ_CUST_ID INCREMENT BY 1;

ALTER SEQUENCE SEQ_TXN_ID INCREMENT BY 100000;
SELECT SEQ_TXN_ID.NEXTVAL FROM DUAL;
ALTER SEQUENCE SEQ_TXN_ID INCREMENT BY 1;

-- 🔍 [확인 3-4] 시퀀스 최종 값 및 증가폭(INCREMENT_BY = 1) 원복 확인
SELECT SEQUENCE_NAME,
       LAST_NUMBER,        -- ★ 100,000 이상 증가 확인
       INCREMENT_BY        -- ★ 1 확인
  FROM USER_SEQUENCES;


-- 5) 스키마 통계정보 일괄 수집
EXEC DBMS_STATS.GATHER_SCHEMA_STATS(OWNNAME => USER, DEGREE => 8, CASCADE => TRUE);

-- 🔍 [확인 3-5] 통계정보 갱신 시간 및 반영 건수 확인
SELECT TABLE_NAME,
       NUM_ROWS,           -- ★ 10000 / 500000 반영 확인
       BLOCKS,
       LAST_ANALYZED       -- ★ 방금 실행 시간 확인
  FROM USER_TABLES;

SELECT TABLE_NAME,
       INDEX_NAME,
       BLEVEL,
       LEAF_BLOCKS,
       DISTINCT_KEYS,
       LAST_ANALYZED
  FROM USER_INDEXES
 ORDER BY TABLE_NAME, INDEX_NAME;


-- =============================================================================
-- [STEP 4] 20:15 실행: 원본 vs 신규 1:1 전수 건수 대사 & 무결성 검증
-- =============================================================================

-- 🔍 [검증 4-1] 원천 DB(SCN 기준) vs 신규 DB 테이블 1:1 전수 건수 대사
SELECT 'TB_CUST_MST' AS TABLE_NAME,
       (SELECT COUNT(*) FROM TB_CUST_MST@PROD_MIG_LINK) AS SRC_COUNT,
       COUNT(*) AS TGT_COUNT,
       CASE 
           WHEN (SELECT COUNT(*) FROM TB_CUST_MST@PROD_MIG_LINK) = COUNT(*) THEN '일치 (MATCH)' 
           ELSE '불일치 (MISMATCH)' 
       END AS RESULT
  FROM TB_CUST_MST
UNION ALL
SELECT 'TB_CARD_TXN' AS TABLE_NAME,
       (SELECT COUNT(*) FROM TB_CARD_TXN@PROD_MIG_LINK) AS SRC_COUNT,
       COUNT(*) AS TGT_COUNT,
       CASE 
           WHEN (SELECT COUNT(*) FROM TB_CARD_TXN@PROD_MIG_LINK) = COUNT(*) THEN '일치 (MATCH)' 
           ELSE '불일치 (MISMATCH)' 
       END AS RESULT
  FROM TB_CARD_TXN;

-- 🔍 [검증 4-2] 외래키 무결성 검증 (부모 없는 고아 카드거래 건수 = 0건 확인)
SELECT COUNT(*) AS ORPHAN_TXN_COUNT  -- ★ 반드시 0건이어야 정상
  FROM TB_CARD_TXN c
 WHERE NOT EXISTS (
       SELECT 1 
         FROM TB_CUST_MST m 
        WHERE m.CUST_ID = c.CUST_ID
 );
