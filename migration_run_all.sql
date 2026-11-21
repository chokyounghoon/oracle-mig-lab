-- =============================================================================
-- [ora-tgt] 오라클 마이그레이션 실행 및 각 단계별 상태확인 통합 스크립트
-- 접속 정보: mig_user / oracle @ localhost:1522/FREEPDB1
-- =============================================================================


-- =============================================================================
-- [STEP 0] 세션 병렬 DML 활성화 및 에러 방지
-- =============================================================================
ALTER SESSION ENABLE PARALLEL DML;
ALTER SESSION SET SKIP_UNUSABLE_INDEXES = TRUE;

-- [상태확인 0] 세션 파라미터 및 세션 정보 확인
SELECT NAME, VALUE 
  FROM V$PARAMETER 
 WHERE NAME = 'skip_unusable_indexes';  -- ★ TRUE 확인

SELECT SID, SERIAL#, USERNAME, STATUS 
  FROM V$SESSION 
 WHERE SID = SYS_CONTEXT('USERENV', 'SID');


-- =============================================================================
-- [STEP 1] 사전 정리: FK 해제 -> TRUNCATE -> 인덱스 UNUSABLE
-- =============================================================================

-- 1) 기준 SCN 조회 (메모 또는 치환변수로 사용)
SELECT CURRENT_SCN FROM V$DATABASE@PROD_MIG_LINK;

-- 2) FK 제약조건 비활성화
ALTER TABLE TB_CARD_TXN DISABLE CONSTRAINT FK_CARD_CUST;

-- [상태확인 1-2] 외래키(FK) 비활성화 상태 확인 (STATUS가 'DISABLED'인지 확인)
SELECT TABLE_NAME, CONSTRAINT_NAME, CONSTRAINT_TYPE, STATUS, VALIDATED
  FROM USER_CONSTRAINTS
 WHERE CONSTRAINT_TYPE = 'R';

-- 3) 테이블 NOLOGGING 및 TRUNCATE
-- ⚠️ 반드시 4번 인덱스 UNUSABLE 전에 실행해야 합니다 (TRUNCATE 시 인덱스가 VALID로 자동 리셋 방지)
ALTER TABLE TB_CARD_TXN NOLOGGING;
TRUNCATE TABLE TB_CARD_TXN;

ALTER TABLE TB_CUST_MST NOLOGGING;
TRUNCATE TABLE TB_CUST_MST;

-- [상태확인 1-3] 테이블 NOLOGGING 및 0건 초기화 확인
SELECT TABLE_NAME, LOGGING FROM USER_TABLES;

SELECT 'TB_CUST_MST' AS TABLE_NAME, COUNT(*) AS ROW_CNT FROM TB_CUST_MST
UNION ALL
SELECT 'TB_CARD_TXN' AS TABLE_NAME, COUNT(*) AS ROW_CNT FROM TB_CARD_TXN;

-- 4) 일반 인덱스 비활성화 (UNUSABLE 처리)
ALTER INDEX IDX_TXN_DT UNUSABLE;
ALTER INDEX IDX_TXN_AMT UNUSABLE;
ALTER INDEX IDX_TXN_CUST_ID UNUSABLE;

-- [상태확인 1-4] 인덱스 상태 확인 (일반 인덱스: UNUSABLE / PK: VALID)
SELECT TABLE_NAME, INDEX_NAME, UNIQUENESS, STATUS
  FROM USER_INDEXES
 ORDER BY TABLE_NAME, INDEX_NAME;


-- =============================================================================
-- [STEP 2] Direct-Path 병렬 고속 적재 (부모 -> 자식 순서 적재)
-- =============================================================================

INSERT /*+ APPEND PARALLEL(4) */ INTO TB_CUST_MST
SELECT /*+ PARALLEL(4) */ * FROM TB_CUST_MST@PROD_MIG_LINK;
COMMIT;

INSERT /*+ APPEND PARALLEL(4) */ INTO TB_CARD_TXN
SELECT /*+ PARALLEL(4) */ * FROM TB_CARD_TXN@PROD_MIG_LINK;
COMMIT;

-- [상태확인 2-1] INSERT 실행 중 실시간 진행률(Progress %) 모니터링
-- (대량 적재 중 다른 세션에서 조회 시 남은 시간 및 완료율 확인 가능)
SELECT OPNAME, TARGET, SOFAR, TOTALWORK,
       ROUND(SOFAR / DECODE(TOTALWORK, 0, 1, TOTALWORK) * 100, 2) AS PCT_DONE,
       TIME_REMAINING AS REMAIN_SEC,
       ELAPSED_SECONDS AS ELAPSED_SEC,
       MESSAGE
  FROM V$SESSION_LONGOPS
 WHERE TIME_REMAINING > 0 OR SOFAR != TOTALWORK
 ORDER BY START_TIME DESC;

-- [상태확인 2-2] 현재 작동 중인 병렬 프로세스(Parallel Execution Server) 확인
SELECT QCSID, SERVER_GROUP, SERVER_SET, SERVER_NUM, DEGREE, REQ_DEGREE
  FROM V$PX_SESSION;

-- [상태확인 2-3] 데이터 적재 완료 건수 확인 (COMMIT 이후)
SELECT 'TB_CUST_MST' AS TABLE_NAME, COUNT(*) AS ROW_CNT FROM TB_CUST_MST
UNION ALL
SELECT 'TB_CARD_TXN' AS TABLE_NAME, COUNT(*) AS ROW_CNT FROM TB_CARD_TXN;


-- =============================================================================
-- [STEP 3] 복구: 인덱스 REBUILD -> LOGGING 원복 -> FK ENABLE -> 시퀀스 점프 -> 통계
-- =============================================================================

-- 1) UNUSABLE 인덱스 병렬 REBUILD 및 원복
ALTER INDEX IDX_TXN_DT REBUILD PARALLEL 8 NOLOGGING;
ALTER INDEX IDX_TXN_DT NOPARALLEL LOGGING;

ALTER INDEX IDX_TXN_AMT REBUILD PARALLEL 8 NOLOGGING;
ALTER INDEX IDX_TXN_AMT NOPARALLEL LOGGING;

ALTER INDEX IDX_TXN_CUST_ID REBUILD PARALLEL 8 NOLOGGING;
ALTER INDEX IDX_TXN_CUST_ID NOPARALLEL LOGGING;

-- [상태확인 3-1] 모든 인덱스가 다시 'VALID' 상태로 복구되었는지 확인
SELECT TABLE_NAME, INDEX_NAME, UNIQUENESS, STATUS, LOGGING
  FROM USER_INDEXES
 ORDER BY TABLE_NAME, INDEX_NAME;

-- 2) 테이블 LOGGING 원복
ALTER TABLE TB_CUST_MST LOGGING;
ALTER TABLE TB_CARD_TXN LOGGING;

-- [상태확인 3-2] 모든 테이블 LOGGING = 'YES' 확인
SELECT TABLE_NAME, LOGGING FROM USER_TABLES;

-- 3) FK 제약조건 복구 (ENABLE NOVALIDATE - 즉시 완료)
ALTER TABLE TB_CARD_TXN ENABLE NOVALIDATE CONSTRAINT FK_CARD_CUST;

-- [상태확인 3-3] FK 복구 상태 확인 (STATUS='ENABLED', VALIDATED='NOT VALIDATED' 확인)
SELECT TABLE_NAME, CONSTRAINT_NAME, CONSTRAINT_TYPE, STATUS, VALIDATED
  FROM USER_CONSTRAINTS
 WHERE CONSTRAINT_TYPE = 'R';

-- 4) 2-Track PK 충돌 방지용 시퀀스 +100,000 점프
ALTER SEQUENCE SEQ_CUST_ID INCREMENT BY 100000;
SELECT SEQ_CUST_ID.NEXTVAL FROM DUAL;
ALTER SEQUENCE SEQ_CUST_ID INCREMENT BY 1;

ALTER SEQUENCE SEQ_TXN_ID INCREMENT BY 100000;
SELECT SEQ_TXN_ID.NEXTVAL FROM DUAL;
ALTER SEQUENCE SEQ_TXN_ID INCREMENT BY 1;

-- [상태확인 3-4] 시퀀스 최종 값 및 INCREMENT_BY(1) 정상 복귀 확인
SELECT SEQUENCE_NAME, LAST_NUMBER, INCREMENT_BY FROM USER_SEQUENCES;

-- 5) 스키마 통계정보 일괄 수집
EXEC DBMS_STATS.GATHER_SCHEMA_STATS(OWNNAME => USER, DEGREE => 8, CASCADE => TRUE);

-- [상태확인 3-5] 통계정보 갱신 시간 및 반영 건수 확인
SELECT TABLE_NAME, NUM_ROWS, BLOCKS, LAST_ANALYZED FROM USER_TABLES;
SELECT TABLE_NAME, INDEX_NAME, BLEVEL, LEAF_BLOCKS, DISTINCT_KEYS, LAST_ANALYZED FROM USER_INDEXES ORDER BY TABLE_NAME, INDEX_NAME;


-- =============================================================================
-- [STEP 4] 원본 vs 대상 1:1 건수 대사 & 무결성 검증
-- =============================================================================

-- [상태확인 4-1] 원천 DB(SCN 기준) vs 신규 DB 테이블 1:1 전수 건수 대사
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

-- [상태확인 4-2] 외래키 무결성 검증 (부모 없는 고아 데이터 0건 확인)
SELECT COUNT(*) AS ORPHAN_TXN_COUNT
  FROM TB_CARD_TXN c
 WHERE NOT EXISTS (SELECT 1 FROM TB_CUST_MST m WHERE m.CUST_ID = c.CUST_ID);
