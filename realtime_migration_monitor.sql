-- =============================================================================
-- [03] MIG_EXEC_LOG 기반 마이그레이션 실시간 모니터링 대시보드
-- 대상 환경 : 신규 Target DB (mig_user / oracle @ localhost:1522/FREEPDB1)
-- 사용 방법 :
--   [창 1]에서 my_migration_workflow.sql 을 돌려두고,
--   [창 2]에서 아래 5개 쿼리를 실행(Ctrl+Enter)하시면 1.1TB 이관 진행률과
--   초당 적재 속도, 오류 발생 여부를 실시간으로 즉시 확인하실 수 있습니다.
-- =============================================================================


-- =============================================================================
-- 📊 [대시보드 1] 최신 배치(RUN_ID) 전체 진행 요약 종합 현황판
-- -----------------------------------------------------------------------------
-- [용도 및 지표 설명]
--  - TABLES_PROGRESS   : 전체 대상 테이블 중 적재 완료된 테이블 수 (예: 45 / 102)
--  - PROGRESS_PCT      : 백분율 진행률 (예: 44.1%)
--  - FAILED_COUNT      : 실패한 테이블 수 (★ 항상 0 이어야 정상!)
--  - TOTAL_ROWS_LOADED : 현재까지 신규 DB에 성공적으로 적재 완료된 누적 행 수
--  - AVG_SEC_PER_TABLE : 테이블 1개당 평균 적재 소요 시간(초)
-- =============================================================================
WITH LATEST_RUN AS (
    -- 가장 최근에 기동된 마이그레이션 배치 RUN_ID를 자동 감지
    SELECT MAX(RUN_ID) AS RUN_ID FROM MIG_EXEC_LOG
),
TARGET_TBL AS (
    -- 전체 대상 테이블 총 개수 카운트 (임시 테이블 및 로그 테이블 제외)
    SELECT COUNT(*) AS CNT
      FROM USER_TABLES
     WHERE TEMPORARY = 'N' AND SECONDARY = 'N'
       AND (IOT_TYPE IS NULL OR IOT_TYPE NOT LIKE '%OVERFLOW%')
       AND TABLE_NAME != 'MIG_EXEC_LOG'
)
SELECT r.RUN_ID,
       COUNT(CASE WHEN m.STATUS = 'SUCCESS' THEN 1 END) || ' / ' || t.CNT AS TABLES_PROGRESS,
       ROUND(COUNT(CASE WHEN m.STATUS = 'SUCCESS' THEN 1 END) / DECODE(t.CNT, 0, 1, t.CNT) * 100, 1) || '%' AS PROGRESS_PCT,
       COUNT(CASE WHEN m.STATUS = 'FAILED' THEN 1 END) AS FAILED_COUNT,
       TO_CHAR(NVL(SUM(m.TGT_CNT), 0), '999,999,999,999') AS TOTAL_ROWS_LOADED,
       ROUND(NVL(AVG(CASE WHEN m.STATUS = 'SUCCESS' THEN m.ELAPSED_SEC END), 0), 2) || '초' AS AVG_SEC_PER_TABLE
  FROM LATEST_RUN r
 CROSS JOIN TARGET_TBL t
  LEFT JOIN MIG_EXEC_LOG m ON r.RUN_ID = m.RUN_ID
 GROUP BY r.RUN_ID, t.CNT;


-- =============================================================================
-- 🚀 [대시보드 2] 지금 이 순간 적재 작업 중(RUNNING)인 테이블 및 경과 시간
-- -----------------------------------------------------------------------------
-- [용도 및 판독 팁]
--  - 현재 Direct-Path INSERT 중인 테이블명과 시작 시각, 경과 시간(초)을 표시합니다.
--  - 만약 특정 테이블이 30분 이상 계속 RUNNING 상태라면 대용량 테이블이거나,
--    DB Link 네트워크 병목, 혹은 소스 DB Undo 블록 경합이 발생한 것이므로 집중 확인 필요.
-- =============================================================================
SELECT RUN_ID,
       TABLE_NAME,
       STATUS,
       TO_CHAR(START_DT, 'HH24:MI:SS') AS START_TIME,
       ROUND((SYSDATE - START_DT) * 86400, 1) || '초 경과' AS DURATION
  FROM MIG_EXEC_LOG
 WHERE STATUS = 'RUNNING';


-- =============================================================================
-- 📋 [대시보드 3] 가장 최근 적재 완료된 최신 15개 테이블 실시간 이력 피드
-- -----------------------------------------------------------------------------
-- [용도]
--  - 방금 어떤 테이블들이 적재를 마치고 지나갔는지, 몇 건이 몇 초 만에 완료되었는지
--    타임라인 형태로 실시간 확인하는 피드 쿼리입니다.
-- =============================================================================
WITH LATEST_RUN AS (
    SELECT MAX(RUN_ID) AS RUN_ID FROM MIG_EXEC_LOG
)
SELECT m.TABLE_NAME,
       m.STATUS,
       TO_CHAR(m.TGT_CNT, '999,999,999,999') AS LOADED_ROWS,
       m.ELAPSED_SEC || 's' AS ELAPSED,
       TO_CHAR(m.START_DT, 'HH24:MI:SS') AS START_TIME,
       TO_CHAR(m.END_DT, 'HH24:MI:SS') AS END_TIME
  FROM MIG_EXEC_LOG m
  JOIN LATEST_RUN r ON m.RUN_ID = r.RUN_ID
 WHERE m.STATUS = 'SUCCESS'
 ORDER BY m.END_DT DESC, m.TABLE_NAME
 FETCH FIRST 15 ROWS ONLY;


-- =============================================================================
-- ⚠️ [대시보드 4] 실패(FAILED) 또는 원본 vs 대상 건수 불일치(MISMATCH) 검출기
-- -----------------------------------------------------------------------------
-- [중요도: ★★★★★]
--  - 조회 결과가 '0건(no rows selected)'이어야 마이그레이션이 100% 무결점으로 완료된 것입니다!
--  - 만약 1건이라도 출력된다면:
--    - FAILED  : ORA 에러 메시지(ERR_MSG)를 보고 권한/타입/네트워크 원인 확인
--    - 건수차이: DIFF_COUNT(원천-타깃)를 확인하여 migration_retry_recovery.sql 로 즉시 복구
-- =============================================================================
WITH LATEST_RUN AS (
    SELECT MAX(RUN_ID) AS RUN_ID FROM MIG_EXEC_LOG
)
SELECT m.TABLE_NAME,
       m.STATUS,
       m.SRC_CNT,
       m.TGT_CNT,
       (m.SRC_CNT - m.TGT_CNT) AS DIFF_COUNT,
       m.ERR_MSG
  FROM MIG_EXEC_LOG m
  JOIN LATEST_RUN r ON m.RUN_ID = r.RUN_ID
 WHERE m.STATUS != 'SUCCESS'
    OR (m.SRC_CNT IS NOT NULL AND m.SRC_CNT <> m.TGT_CNT)
 ORDER BY m.TABLE_NAME;


-- =============================================================================
-- 📡 [대시보드 5] V$SESSION 동적 성능 뷰 실시간 세션 모니터링
-- -----------------------------------------------------------------------------
-- [용도]
--  - my_migration_workflow.sql 의 DBMS_APPLICATION_INFO가 오라클 커널 세션에 직접 방송하는
--    실시간 ACTION 및 진행률(% 및 누적 건수)을 DB 세션 레벨에서 직접 가로채어 모니터링합니다.
--  - 주의: mig_user 계정에 'GRANT SELECT ON V_$SESSION TO mig_user' 권한이 있어야 조회 가능.
-- =============================================================================
SELECT SID,
       SERIAL#,
       ACTION AS CURRENT_ACTION,
       CLIENT_INFO AS STATUS_INFO,
       LAST_CALL_ET AS WORKING_SEC
  FROM V$SESSION
 WHERE MODULE = 'DB_MIGRATION';
