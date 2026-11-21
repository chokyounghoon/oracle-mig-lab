-- =============================================================================
-- [ora-tgt] 사용자 작성 [STEP 1]~[STEP 3] 원클릭 자동 실행 스크립트
-- 복사/붙여넣기 없이 PL/SQL 동적 SQL로 전체 마이그레이션을 한 번에 순차 실행합니다.
-- =============================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED;
SET TIMING ON;

DECLARE
    v_scn       NUMBER;
    v_cust_cnt  NUMBER;
    v_txn_cnt   NUMBER;
BEGIN
    DBMS_OUTPUT.PUT_LINE('================================================================');
    DBMS_OUTPUT.PUT_LINE('  [마이그레이션 시작]');
    DBMS_OUTPUT.PUT_LINE('================================================================');

    -- [STEP 1-1] 기준 SCN 조회
    SELECT CURRENT_SCN INTO v_scn FROM V$DATABASE@PROD_MIG_LINK;
    DBMS_OUTPUT.PUT_LINE('>>> [STEP 1-1] 기준 SCN 추출 완료: ' || v_scn);

    -- [STEP 1-2] FK 일괄 DISABLE
    FOR r IN (
        SELECT TABLE_NAME, CONSTRAINT_NAME
          FROM USER_CONSTRAINTS
         WHERE CONSTRAINT_TYPE = 'R' AND STATUS = 'ENABLED'
    ) LOOP
        EXECUTE IMMEDIATE 'ALTER TABLE ' || r.TABLE_NAME || ' DISABLE CONSTRAINT ' || r.CONSTRAINT_NAME;
        DBMS_OUTPUT.PUT_LINE('>>> [FK DISABLE] ' || r.TABLE_NAME || '.' || r.CONSTRAINT_NAME);
    END LOOP;

    -- [STEP 1-3] 일반 인덱스 일괄 UNUSABLE (PK/UK 제외)
    FOR r IN (
        SELECT INDEX_NAME
          FROM USER_INDEXES
         WHERE INDEX_TYPE = 'NORMAL' AND UNIQUENESS = 'NONUNIQUE'
    ) LOOP
        EXECUTE IMMEDIATE 'ALTER INDEX ' || r.INDEX_NAME || ' UNUSABLE';
        DBMS_OUTPUT.PUT_LINE('>>> [INDEX UNUSABLE] ' || r.INDEX_NAME);
    END LOOP;

    -- [STEP 1-4] 테이블 NOLOGGING 전환 및 TRUNCATE
    FOR r IN (
        SELECT TABLE_NAME FROM USER_TABLES ORDER BY TABLE_NAME
    ) LOOP
        EXECUTE IMMEDIATE 'ALTER TABLE ' || r.TABLE_NAME || ' NOLOGGING';
        EXECUTE IMMEDIATE 'TRUNCATE TABLE ' || r.TABLE_NAME;
        DBMS_OUTPUT.PUT_LINE('>>> [NOLOGGING & TRUNCATE] ' || r.TABLE_NAME);
    END LOOP;

    -- [STEP 2] 세션 병렬 DML 활성화 및 INSERT /*+ APPEND PARALLEL(4) */ 이관
    EXECUTE IMMEDIATE 'ALTER SESSION ENABLE PARALLEL DML';
    EXECUTE IMMEDIATE 'ALTER SESSION SET SKIP_UNUSABLE_INDEXES = TRUE';

    FOR r IN (
        SELECT TABLE_NAME FROM USER_TABLES ORDER BY TABLE_NAME
    ) LOOP
        DBMS_OUTPUT.PUT_LINE('>>> [INSERT 실행 중] ' || r.TABLE_NAME || ' (SCN: ' || v_scn || ')...');
        EXECUTE IMMEDIATE 'INSERT /*+ APPEND PARALLEL(4) */ INTO ' || r.TABLE_NAME ||
                          ' SELECT /*+ PARALLEL(4) */ * FROM ' || r.TABLE_NAME || '@PROD_MIG_LINK AS OF SCN ' || v_scn;
        COMMIT;
        DBMS_OUTPUT.PUT_LINE('>>> [INSERT 완료] ' || r.TABLE_NAME);
    END LOOP;

    -- [STEP 3-1] UNUSABLE 인덱스 일괄 REBUILD 및 NOPARALLEL LOGGING 복원
    FOR r IN (
        SELECT INDEX_NAME FROM USER_INDEXES WHERE STATUS = 'UNUSABLE'
    ) LOOP
        EXECUTE IMMEDIATE 'ALTER INDEX ' || r.INDEX_NAME || ' REBUILD PARALLEL 8 NOLOGGING';
        EXECUTE IMMEDIATE 'ALTER INDEX ' || r.INDEX_NAME || ' NOPARALLEL LOGGING';
        DBMS_OUTPUT.PUT_LINE('>>> [INDEX REBUILD] ' || r.INDEX_NAME);
    END LOOP;

    -- [STEP 3-2] 테이블 LOGGING 원복
    FOR r IN (
        SELECT TABLE_NAME FROM USER_TABLES
    ) LOOP
        EXECUTE IMMEDIATE 'ALTER TABLE ' || r.TABLE_NAME || ' LOGGING';
        DBMS_OUTPUT.PUT_LINE('>>> [LOGGING 원복] ' || r.TABLE_NAME);
    END LOOP;

    -- [STEP 3-3] FK 일괄 ENABLE NOVALIDATE
    FOR r IN (
        SELECT TABLE_NAME, CONSTRAINT_NAME
          FROM USER_CONSTRAINTS
         WHERE CONSTRAINT_TYPE = 'R' AND STATUS = 'DISABLED'
    ) LOOP
        EXECUTE IMMEDIATE 'ALTER TABLE ' || r.TABLE_NAME || ' ENABLE NOVALIDATE CONSTRAINT ' || r.CONSTRAINT_NAME;
        DBMS_OUTPUT.PUT_LINE('>>> [FK ENABLE NOVALIDATE] ' || r.TABLE_NAME || '.' || r.CONSTRAINT_NAME);
    END LOOP;

    -- [STEP 3-4] 스키마 통계정보 일괄 수집
    DBMS_OUTPUT.PUT_LINE('>>> [통계정보 수집 중] GATHER_SCHEMA_STATS (DEGREE 8)...');
    DBMS_STATS.GATHER_SCHEMA_STATS(OWNNAME => USER, DEGREE => 8, CASCADE => TRUE);
    DBMS_OUTPUT.PUT_LINE('>>> [통계정보 수집 완료]');

    -- 최종 검증 건수 출력
    SELECT COUNT(*) INTO v_cust_cnt FROM TB_CUST_MST;
    SELECT COUNT(*) INTO v_txn_cnt  FROM TB_CARD_TXN;
    DBMS_OUTPUT.PUT_LINE('================================================================');
    DBMS_OUTPUT.PUT_LINE('  [마이그레이션 전체 완료]');
    DBMS_OUTPUT.PUT_LINE('  - TB_CUST_MST 건수 : ' || v_cust_cnt);
    DBMS_OUTPUT.PUT_LINE('  - TB_CARD_TXN 건수 : ' || v_txn_cnt);
    DBMS_OUTPUT.PUT_LINE('================================================================');
END;
/
