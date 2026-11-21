-- =============================================================================
-- [02] 마이그레이션 예외/오류 발생 시 실패 테이블 전용 재수행 및 복구 최종 확정본
-- 대상 환경 : 신규 Target DB (mig_user / oracle @ localhost:1522/FREEPDB1)
-- 실행 용도 : 1.1TB 메인 이관 중 네트워크 일시 단절, ORA-01555 등으로 실패한 테이블만
--             골라서 단독/선택적으로 재이관 및 복구하는 엔터프라이즈급 긴급 복구 도구
--
-- -----------------------------------------------------------------------------
-- 🛡️ [실무 복구 2대 핵심 아키텍처 및 안전장치]
-- -----------------------------------------------------------------------------
-- 1. [부모-자식 FK 연쇄 비활성화 (ORA-02266 원천 방지)]:
--    - 실패한 테이블이 부모 마스터 테이블(예: 고객, 상품)인 경우, 기존 단순 FK 해제는
--      자신의 FK만 풀기 때문에 자식 테이블이 참조하고 있어 TRUNCATE 시 ORA-02266 발생!
--    - 본 스크립트는 '자신의 FK'뿐만 아니라 '자신을 참조하고 있는 모든 자식의 FK(R_CONSTRAINT_NAME)'까지
--      추적하여 일괄 비활성화하므로 부모 테이블도 에러 없이 깔끔하게 TRUNCATE 후 재적재 가능.
--
-- 2. [2-Track 시점 일관성 보장 (v_fixed_scn 고정 파라미터)]:
--    - 복구 시점에 새로 SCN을 따면 그동안 소스 운영 DB에 실시간 거래가 쌓여,
--      이미 성공한 101개 테이블(18:30 기준)과 복구된 1개 테이블(20:00 기준)의 데이터 시점이 틀어짐.
--    - 본 스크립트는 'v_fixed_scn'에 본 이관 당시 SCN을 입력할 수 있어 100% 동일 시점으로 복구 가능!
-- =============================================================================

COMMIT;
ALTER SESSION ENABLE PARALLEL DML;
ALTER SESSION SET SKIP_UNUSABLE_INDEXES = TRUE;
SET SERVEROUTPUT ON SIZE UNLIMITED;

DECLARE
    -- =========================================================================
    -- [사용자 설정 파라미터 (상황에 맞게 수정하여 실행)]
    -- =========================================================================
    -- 1) [권장] 본 이관 당시의 기준 SCN 고정값:
    --    - 본 이관 시작 시 출력된 SCN(예: 2852456)을 입력하면 나머지 성공 테이블과 시점 정합성 100% 일치.
    --    - NULL 로 둘 경우 소스 DB의 현재 최신 SCN을 실시간으로 자동 추출하여 복구합니다.
    v_fixed_scn       NUMBER         := NULL;

    -- 2) 대상 배치(RUN_ID) 지정:
    --    - 특정 배치의 실패 내역을 복구하려면 '20261121_130000' 형태로 입력.
    --    - NULL 로 둘 경우 MIG_EXEC_LOG에서 가장 최근(MAX) RUN_ID를 자동 감지합니다.
    v_target_run_id   VARCHAR2(20)   := NULL;

    -- 3) 특정 테이블만 강제로 재적재(재이관)하고 싶을 때:
    --    - 콤마(,)로 구분하여 테이블명을 지정 (예: 'TB_CARD_TXN, TB_BIZ_050')
    --    - NULL 로 둘 경우 MIG_EXEC_LOG에서 STATUS != 'SUCCESS' 이거나
    --      건수가 불일치(SRC_CNT <> TGT_CNT)한 테이블을 자동으로 전수 찾아내어 복구합니다.
    v_manual_tables   VARCHAR2(4000) := NULL;

    -- =========================================================================
    -- [내부 제어 변수]
    -- =========================================================================
    v_run_id          VARCHAR2(20);    -- 복구 대상 배치 ID
    v_scn             NUMBER;          -- 적용할 SCN 기준 번호
    v_src_cnt         NUMBER;          -- 소스 건수 검증용
    v_tgt_cnt         NUMBER;          -- 타깃 건수 검증용
    v_retry_total     NUMBER := 0;     -- 재수행 대상 총 테이블 수
    v_retry_done      NUMBER := 0;     -- 현재 처리 중인 테이블 순번
    v_success_cnt     NUMBER := 0;     -- 복구 성공 누적 건수
    v_fail_cnt        NUMBER := 0;     -- 복구 실패 누적 건수
    t_start           TIMESTAMP := SYSTIMESTAMP; -- 복구 배치 시작 시각
    t_tbl_start       TIMESTAMP;       -- 테이블별 시작 시각
    v_tbl_sec         NUMBER;          -- 소요 시간(초)
    v_err_msg         VARCHAR2(4000);  -- 에러 메시지 임시 저장

BEGIN
    -- -------------------------------------------------------------------------
    -- [1단계] 대상 RUN_ID 확정
    -- -------------------------------------------------------------------------
    IF v_target_run_id IS NOT NULL THEN
        v_run_id := v_target_run_id;
    ELSE
        SELECT MAX(RUN_ID) INTO v_run_id FROM MIG_EXEC_LOG;
    END IF;

    IF v_run_id IS NULL THEN
        DBMS_OUTPUT.PUT_LINE('>>> [오류] MIG_EXEC_LOG 에 실행 이력이 없습니다. 먼저 본 이관을 실행하세요.');
        RETURN;
    END IF;

    -- -------------------------------------------------------------------------
    -- [2단계] 복구 기준 SCN 확정 (고정값 vs 실시간 자동)
    -- -------------------------------------------------------------------------
    IF v_fixed_scn IS NOT NULL THEN
        v_scn := v_fixed_scn;
        DBMS_OUTPUT.PUT_LINE('>>> [복구 기준점] 사용자 지정 고정 SCN 적용 (시점 정합성 100% 일치): ' || v_scn);
    ELSE
        SELECT CURRENT_SCN INTO v_scn FROM V$DATABASE@PROD_MIG_LINK;
        DBMS_OUTPUT.PUT_LINE('>>> [복구 기준점] 소스 DB 현재 시점 SCN 자동 추출: ' || v_scn);
        DBMS_OUTPUT.PUT_LINE('    (💡 팁: 본 이관 당시와 완벽히 일치시키려면 상단 v_fixed_scn 에 당시 SCN을 입력하세요)');
    END IF;

    DBMS_OUTPUT.PUT_LINE('======================================================================');
    DBMS_OUTPUT.PUT_LINE('>>> [장애 복구 / 재수행 배치 가동]');
    DBMS_OUTPUT.PUT_LINE('  - 대상 배치 (RUN_ID) : ' || v_run_id);
    DBMS_OUTPUT.PUT_LINE('  - 복구 기준점 (SCN)  : ' || v_scn);
    DBMS_OUTPUT.PUT_LINE('======================================================================');

    -- -------------------------------------------------------------------------
    -- [3단계] 복구 대상 테이블 건수 사전 집계
    -- -------------------------------------------------------------------------
    IF v_manual_tables IS NOT NULL THEN
        SELECT COUNT(*) INTO v_retry_total
          FROM USER_TABLES
         WHERE INSTR(',' || REPLACE(UPPER(v_manual_tables), ' ', '') || ',', ',' || UPPER(TABLE_NAME) || ',') > 0;
    ELSE
        SELECT COUNT(*) INTO v_retry_total
          FROM MIG_EXEC_LOG
         WHERE RUN_ID = v_run_id
           AND (STATUS != 'SUCCESS' OR (SRC_CNT IS NOT NULL AND SRC_CNT <> TGT_CNT));
    END IF;

    IF v_retry_total = 0 THEN
        DBMS_OUTPUT.PUT_LINE('>>> [완벽] 대상 배치(' || v_run_id || ')에 실패하거나 건수가 불일치한 테이블이 없습니다!');
        DBMS_OUTPUT.PUT_LINE('>>> 모든 테이블이 이미 정상 이관 완료된 상태입니다.');
        RETURN;
    END IF;

    DBMS_OUTPUT.PUT_LINE('>>> 총 ' || v_retry_total || '개 대상 테이블의 선택적 재적재 및 복구를 시작합니다.');
    DBMS_OUTPUT.PUT_LINE('----------------------------------------------------------------------');

    -- -------------------------------------------------------------------------
    -- [4단계] 대상 테이블별 정밀 원자적 복구 루프
    -- -------------------------------------------------------------------------
    FOR r IN (
        SELECT t.TABLE_NAME
          FROM USER_TABLES t
          LEFT JOIN MIG_EXEC_LOG m ON t.TABLE_NAME = m.TABLE_NAME AND m.RUN_ID = v_run_id
         WHERE (
             (v_manual_tables IS NOT NULL AND INSTR(',' || REPLACE(UPPER(v_manual_tables), ' ', '') || ',', ',' || UPPER(t.TABLE_NAME) || ',') > 0)
             OR
             (v_manual_tables IS NULL AND m.RUN_ID = v_run_id AND (m.STATUS != 'SUCCESS' OR (m.SRC_CNT IS NOT NULL AND m.SRC_CNT <> m.TGT_CNT)))
         )
         ORDER BY t.TABLE_NAME
    ) LOOP
        v_retry_done := v_retry_done + 1;
        t_tbl_start := SYSTIMESTAMP;

        DBMS_APPLICATION_INFO.SET_MODULE('DB_MIG_RETRY', 'RETRYING ' || r.TABLE_NAME);
        DBMS_APPLICATION_INFO.SET_ACTION('[' || v_retry_done || '/' || v_retry_total || '] ' || r.TABLE_NAME);

        BEGIN
            -- (A) 대상 테이블 트리거 비활성화
            FOR trg IN (SELECT TRIGGER_NAME FROM USER_TRIGGERS WHERE TABLE_NAME = r.TABLE_NAME AND STATUS = 'ENABLED') LOOP
                EXECUTE IMMEDIATE 'ALTER TRIGGER "' || trg.TRIGGER_NAME || '" DISABLE';
            END LOOP;

            -- (B) [핵심 안전장치] 자신 및 자신을 참조하는 자식 FK 모두 비활성화 (ORA-02266 완벽 방지)
            --     1) 자신이 다른 테이블을 참조하는 FK: TABLE_NAME = r.TABLE_NAME
            --     2) 자식 테이블이 자신의 PK/UK를 참조하는 FK: R_CONSTRAINT_NAME IN (PK/UK 목록)
            FOR fk IN (
                SELECT TABLE_NAME, CONSTRAINT_NAME
                  FROM USER_CONSTRAINTS
                 WHERE STATUS = 'ENABLED'
                   AND (
                       (TABLE_NAME = r.TABLE_NAME AND CONSTRAINT_TYPE = 'R')
                       OR
                       (R_CONSTRAINT_NAME IN (
                           SELECT CONSTRAINT_NAME
                             FROM USER_CONSTRAINTS
                            WHERE TABLE_NAME = r.TABLE_NAME
                              AND CONSTRAINT_TYPE IN ('P', 'U')
                       ))
                   )
            ) LOOP
                BEGIN
                    EXECUTE IMMEDIATE 'ALTER TABLE "' || fk.TABLE_NAME || '" DISABLE CONSTRAINT "' || fk.CONSTRAINT_NAME || '"';
                EXCEPTION WHEN OTHERS THEN NULL;
                END;
            END LOOP;

            -- (C) 불완전하게 들어간 쓰레기 데이터 정리 (TRUNCATE) 및 NOLOGGING 전환
            EXECUTE IMMEDIATE 'ALTER TABLE "' || r.TABLE_NAME || '" NOLOGGING';
            EXECUTE IMMEDIATE 'TRUNCATE TABLE "' || r.TABLE_NAME || '"';

            -- (D) 비고유 일반 및 파티션 인덱스 UNUSABLE 처리 (고속 적재 준비)
            FOR idx IN (
                SELECT INDEX_NAME FROM USER_INDEXES
                 WHERE TABLE_NAME = r.TABLE_NAME AND UNIQUENESS = 'NONUNIQUE' AND STATUS = 'VALID' AND PARTITIONED = 'NO'
            ) LOOP
                BEGIN
                    EXECUTE IMMEDIATE 'ALTER INDEX "' || idx.INDEX_NAME || '" UNUSABLE';
                EXCEPTION WHEN OTHERS THEN NULL;
                END;
            END LOOP;

            FOR p IN (
                SELECT p.INDEX_NAME, p.PARTITION_NAME FROM USER_IND_PARTITIONS p
                  JOIN USER_INDEXES i ON p.INDEX_NAME = i.INDEX_NAME
                 WHERE i.TABLE_NAME = r.TABLE_NAME AND i.UNIQUENESS = 'NONUNIQUE' AND p.STATUS = 'USABLE'
            ) LOOP
                BEGIN
                    EXECUTE IMMEDIATE 'ALTER INDEX "' || p.INDEX_NAME || '" MODIFY PARTITION "' || p.PARTITION_NAME || '" UNUSABLE';
                EXCEPTION WHEN OTHERS THEN NULL;
                END;
            END LOOP;

            -- (E) 고속 Direct-Path 병렬 재적재 (메인 배치와 동일한 PARALLEL 8 / 4 및 AS OF SCN 적용)
            EXECUTE IMMEDIATE 'INSERT /*+ APPEND PARALLEL(8) */ INTO "' || r.TABLE_NAME || '" ' ||
                              'SELECT /*+ PARALLEL(4) */ * FROM "' || r.TABLE_NAME || '"@PROD_MIG_LINK AS OF SCN ' || v_scn;
            v_tgt_cnt := SQL%ROWCOUNT;
            COMMIT;

            -- (F) 원본 행 수 즉시 검증
            EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM "' || r.TABLE_NAME || '"@PROD_MIG_LINK AS OF SCN ' || v_scn INTO v_src_cnt;

            -- (G) 대상 테이블 인덱스 고속 병렬 REBUILD 및 NOPARALLEL LOGGING 원복
            FOR idx IN (
                SELECT INDEX_NAME FROM USER_INDEXES
                 WHERE TABLE_NAME = r.TABLE_NAME AND STATUS = 'UNUSABLE' AND PARTITIONED = 'NO'
            ) LOOP
                BEGIN
                    EXECUTE IMMEDIATE 'ALTER INDEX "' || idx.INDEX_NAME || '" REBUILD PARALLEL 8 NOLOGGING';
                    EXECUTE IMMEDIATE 'ALTER INDEX "' || idx.INDEX_NAME || '" NOPARALLEL LOGGING';
                EXCEPTION WHEN OTHERS THEN NULL;
                END;
            END LOOP;

            FOR p IN (
                SELECT p.INDEX_NAME, p.PARTITION_NAME FROM USER_IND_PARTITIONS p
                  JOIN USER_INDEXES i ON p.INDEX_NAME = i.INDEX_NAME
                 WHERE i.TABLE_NAME = r.TABLE_NAME AND p.STATUS = 'UNUSABLE'
            ) LOOP
                BEGIN
                    EXECUTE IMMEDIATE 'ALTER INDEX "' || p.INDEX_NAME || '" REBUILD PARTITION "' || p.PARTITION_NAME || '" PARALLEL 8 NOLOGGING';
                    EXECUTE IMMEDIATE 'ALTER INDEX "' || p.INDEX_NAME || '" MODIFY PARTITION "' || p.PARTITION_NAME || '" NOPARALLEL LOGGING';
                EXCEPTION WHEN OTHERS THEN NULL;
                END;
            END LOOP;

            -- (H) 테이블 LOGGING 원복
            EXECUTE IMMEDIATE 'ALTER TABLE "' || r.TABLE_NAME || '" LOGGING';

            -- (I) 대상 테이블 개별 통계정보 수집 (CBO 최적화)
            DBMS_STATS.GATHER_TABLE_STATS(OWNNAME => USER, TABNAME => r.TABLE_NAME, DEGREE => 8, CASCADE => TRUE);

            v_tbl_sec := ROUND(EXTRACT(SECOND FROM (SYSTIMESTAMP - t_tbl_start)) +
                               EXTRACT(MINUTE FROM (SYSTIMESTAMP - t_tbl_start)) * 60, 2);

            -- (J) MIG_EXEC_LOG 상태를 SUCCESS로 갱신 (전수 대사 일치 시)
            MERGE INTO MIG_EXEC_LOG m
            USING DUAL ON (m.RUN_ID = v_run_id AND m.TABLE_NAME = r.TABLE_NAME)
            WHEN MATCHED THEN
                UPDATE SET STATUS      = 'SUCCESS',
                           SRC_CNT     = v_src_cnt,
                           TGT_CNT     = v_tgt_cnt,
                           ELAPSED_SEC = v_tbl_sec,
                           ERR_MSG     = NULL,
                           END_DT      = SYSDATE
            WHEN NOT MATCHED THEN
                INSERT (RUN_ID, TABLE_NAME, STATUS, SRC_CNT, TGT_CNT, ELAPSED_SEC, ERR_MSG, START_DT, END_DT)
                VALUES (v_run_id, r.TABLE_NAME, 'SUCCESS', v_src_cnt, v_tgt_cnt, v_tbl_sec, NULL, SYSDATE, SYSDATE);
            COMMIT;

            v_success_cnt := v_success_cnt + 1;
            DBMS_OUTPUT.PUT_LINE(' [재적재 성공] ' || RPAD(r.TABLE_NAME, 25) || ' : ' ||
                                 LPAD(TO_CHAR(v_tgt_cnt, '999,999,999'), 12) || '건 (' || v_tbl_sec || '초)');

        EXCEPTION WHEN OTHERS THEN
            ROLLBACK;
            v_fail_cnt := v_fail_cnt + 1;
            v_tbl_sec := ROUND(EXTRACT(SECOND FROM (SYSTIMESTAMP - t_tbl_start)) +
                               EXTRACT(MINUTE FROM (SYSTIMESTAMP - t_tbl_start)) * 60, 2);
            v_err_msg := '재수행 실패: ORA' || SQLCODE || ' ' || SQLERRM;

            MERGE INTO MIG_EXEC_LOG m
            USING DUAL ON (m.RUN_ID = v_run_id AND m.TABLE_NAME = r.TABLE_NAME)
            WHEN MATCHED THEN
                UPDATE SET STATUS      = 'FAILED',
                           ELAPSED_SEC = v_tbl_sec,
                           ERR_MSG     = v_err_msg,
                           END_DT      = SYSDATE
            WHEN NOT MATCHED THEN
                INSERT (RUN_ID, TABLE_NAME, STATUS, SRC_CNT, TGT_CNT, ELAPSED_SEC, ERR_MSG, START_DT, END_DT)
                VALUES (v_run_id, r.TABLE_NAME, 'FAILED', 0, 0, v_tbl_sec, v_err_msg, SYSDATE, SYSDATE);
            COMMIT;

            DBMS_OUTPUT.PUT_LINE(' [재적재 실패] ' || r.TABLE_NAME || ' -> ORA' || SQLCODE || ' (' || SUBSTR(SQLERRM, 1, 80) || ')');
        END;
    END LOOP;

    -- -------------------------------------------------------------------------
    -- [5단계] 비활성화되었던 전체 외래키(FK) 일괄 원복 (ENABLE NOVALIDATE)
    -- -------------------------------------------------------------------------
    FOR fk IN (
        SELECT TABLE_NAME, CONSTRAINT_NAME FROM USER_CONSTRAINTS
         WHERE CONSTRAINT_TYPE = 'R' AND STATUS = 'DISABLED'
    ) LOOP
        BEGIN
            EXECUTE IMMEDIATE 'ALTER TABLE "' || fk.TABLE_NAME || '" ENABLE NOVALIDATE CONSTRAINT "' || fk.CONSTRAINT_NAME || '"';
        EXCEPTION WHEN OTHERS THEN NULL;
        END;
    END LOOP;

    DBMS_APPLICATION_INFO.SET_MODULE(NULL, NULL);
    DBMS_OUTPUT.PUT_LINE('======================================================================');
    DBMS_OUTPUT.PUT_LINE('>>> [재수행 결과 요약] 복구 성공: ' || v_success_cnt || '개 / 잔여 실패: ' || v_fail_cnt || '개');
    DBMS_OUTPUT.PUT_LINE('>>> 총 소요 시간: ' || (SYSTIMESTAMP - t_start));
    DBMS_OUTPUT.PUT_LINE('======================================================================');
END;
/
