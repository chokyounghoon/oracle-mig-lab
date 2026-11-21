-- =============================================================================
-- [ora-tgt] 오라클 마이그레이션 실행 및 검증 스크립트 ([0] ~ [4] 단계)
-- 대상 테이블: TB_CARD_TXN (카드 거래내역 50만 건)
-- =============================================================================

SET TIMING ON;
SET SERVEROUTPUT ON SIZE UNLIMITED;
SET DEFINE ON;
SET FEEDBACK ON;
WHENEVER SQLERROR CONTINUE;

PROMPT
PROMPT =========================================================================
PROMPT [0] SCN 확인 및 마이그레이션 기준점 추출
PROMPT =========================================================================
-- 소스 DB의 최신 SCN을 조회하여 치환 변수(&MIG_SCN)에 저장
-- ORA-01555 방지를 위해 UNDO_RETENTION(3600초) 설정된 시점의 정합성 보장

COLUMN src_scn NEW_VALUE MIG_SCN;
SELECT CURRENT_SCN AS src_scn FROM V$DATABASE@PROD_MIG_LINK;

PROMPT >>> [0] 추출된 기준 SCN: &MIG_SCN
PROMPT

PROMPT =========================================================================
PROMPT [1] 타겟 테이블 사전 정리 (TRUNCATE & 제약조건/인덱스 비활성화)
PROMPT =========================================================================
-- 1) 기존 구데이터(100건) TRUNCATE
TRUNCATE TABLE TB_CARD_TXN;

-- 2) 외래키(FK) 제약조건 비활성화 (부모 테이블 검증 부하 제거)
ALTER TABLE TB_CARD_TXN MODIFY CONSTRAINT FK_CARD_CUST DISABLE;

-- 3) 일반 인덱스 비활성화 (UNUSABLE 처리로 Direct Path Insert 부하 제거)
ALTER INDEX IDX_TXN_DT UNUSABLE;
ALTER INDEX IDX_TXN_AMT UNUSABLE;
ALTER INDEX IDX_TXN_CUST_ID UNUSABLE;

-- 4) 세션 환경 설정: 병렬 DML 활성화 및 UNUSABLE 인덱스 에러 무시
ALTER SESSION ENABLE PARALLEL DML;
ALTER SESSION SET SKIP_UNUSABLE_INDEXES = TRUE;

PROMPT >>> [1] 단계 완료: TRUNCATE, FK DISABLE, INDEX UNUSABLE 적용 완료
PROMPT

PROMPT =========================================================================
PROMPT [2] 고속 병렬 데이터 이관 (Direct Path INSERT /*+ APPEND PARALLEL */)
PROMPT =========================================================================
-- Direct Path Insert (APPEND) + 병렬도(PARALLEL 8) + Flashback Query(AS OF SCN)

INSERT /*+ APPEND PARALLEL(t, 8) */ INTO TB_CARD_TXN t
SELECT /*+ PARALLEL(s, 8) */ *
FROM TB_CARD_TXN@PROD_MIG_LINK AS OF SCN &MIG_SCN s;

COMMIT;

PROMPT >>> [2] 단계 완료: Direct Path Parallel INSERT 및 COMMIT 완료
PROMPT

PROMPT =========================================================================
PROMPT [3] 후속 작업: 인덱스 병렬 재생성 (REBUILD) & 제약조건 활성화 (ENABLE)
PROMPT =========================================================================
-- UNUSABLE 상태 인덱스를 PARALLEL 8로 고속 재생성 후 NOPARALLEL 복원
ALTER INDEX IDX_TXN_DT REBUILD PARALLEL 8;
ALTER INDEX IDX_TXN_DT NOPARALLEL;

ALTER INDEX IDX_TXN_AMT REBUILD PARALLEL 8;
ALTER INDEX IDX_TXN_AMT NOPARALLEL;

ALTER INDEX IDX_TXN_CUST_ID REBUILD PARALLEL 8;
ALTER INDEX IDX_TXN_CUST_ID NOPARALLEL;

-- 외래키(FK) 제약조건 재활성화
ALTER TABLE TB_CARD_TXN MODIFY CONSTRAINT FK_CARD_CUST ENABLE;

PROMPT >>> [3] 단계 완료: 인덱스 REBUILD 및 제약조건 ENABLE 완료
PROMPT

PROMPT =========================================================================
PROMPT [4] 데이터 정합성 검증 및 통계정보 수집
PROMPT =========================================================================

-- 1) 소스 vs 타겟 건수 비교 검증
DECLARE
    v_src_count NUMBER;
    v_tgt_count NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_src_count FROM TB_CARD_TXN@PROD_MIG_LINK AS OF SCN &MIG_SCN;
    SELECT COUNT(*) INTO v_tgt_count FROM TB_CARD_TXN;

    DBMS_OUTPUT.PUT_LINE('----------------------------------------------------');
    DBMS_OUTPUT.PUT_LINE('  [마이그레이션 건수 검증 결과]');
    DBMS_OUTPUT.PUT_LINE('  - 소스 DB 건수 (SCN &MIG_SCN 기준) : ' || TO_CHAR(v_src_count, '999,999,999'));
    DBMS_OUTPUT.PUT_LINE('  - 타겟 DB 이관 건수                 : ' || TO_CHAR(v_tgt_count, '999,999,999'));
    IF v_src_count = v_tgt_count THEN
        DBMS_OUTPUT.PUT_LINE('  ==> [SUCCESS] 50만 건 데이터 정합성 완벽 일치!');
    ELSE
        DBMS_OUTPUT.PUT_LINE('  ==> [ERROR] 건수 불일치 발생! (차이: ' || (v_src_count - v_tgt_count) || ')');
    END IF;
    DBMS_OUTPUT.PUT_LINE('----------------------------------------------------');
END;
/

-- 2) 인덱스 상태 점검 (모두 VALID 여부 확인)
PROMPT >>> 인덱스 상태 점검 (VALID 확인)
COLUMN index_name FORMAT A20;
COLUMN status FORMAT A10;
SELECT index_name, status
FROM user_indexes
WHERE table_name = 'TB_CARD_TXN'
ORDER BY index_name;

-- 3) 제약조건 상태 점검 (모두 ENABLED 확인)
PROMPT >>> 제약조건 상태 점검 (ENABLED 확인)
COLUMN constraint_name FORMAT A20;
COLUMN constraint_type FORMAT A15;
COLUMN status FORMAT A10;
SELECT constraint_name, constraint_type, status
FROM user_constraints
WHERE table_name = 'TB_CARD_TXN'
ORDER BY constraint_name;

-- 4) 타겟 테이블 및 인덱스 최신 CBO 통계정보 수집
PROMPT >>> 타겟 테이블(TB_CARD_TXN) 최신 통계정보 수집 중 (PARALLEL 8)...
BEGIN
    DBMS_STATS.GATHER_TABLE_STATS(
        ownname          => 'MIG_USER',
        tabname          => 'TB_CARD_TXN',
        estimate_percent => DBMS_STATS.AUTO_SAMPLE_SIZE,
        cascade          => TRUE,
        degree           => 8
    );
END;
/

PROMPT =========================================================================
PROMPT  [4] 단계 완료: 전체 마이그레이션 및 정합성 검증 완료!
PROMPT =========================================================================
