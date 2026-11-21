-- =============================================================================
-- [ora-src] Source Database Initialization Script
-- =============================================================================
SET SERVEROUTPUT ON SIZE UNLIMITED;
SET DEFINE OFF;
SET FEEDBACK ON;

-- 1. PDB(FREEPDB1)로 전환
ALTER SESSION SET CONTAINER = FREEPDB1;

-- 2. mig_user 생성 및 비밀번호/잠금해제 보장
DECLARE
    v_cnt NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_cnt FROM dba_users WHERE username = 'MIG_USER';
    IF v_cnt = 0 THEN
        EXECUTE IMMEDIATE 'CREATE USER mig_user IDENTIFIED BY oracle DEFAULT TABLESPACE USERS TEMPORARY TABLESPACE TEMP QUOTA UNLIMITED ON USERS';
        EXECUTE IMMEDIATE 'GRANT CONNECT, RESOURCE TO mig_user';
    ELSE
        EXECUTE IMMEDIATE 'ALTER USER mig_user IDENTIFIED BY oracle ACCOUNT UNLOCK';
        EXECUTE IMMEDIATE 'ALTER USER mig_user QUOTA UNLIMITED ON USERS';
    END IF;
    EXECUTE IMMEDIATE 'ALTER USER sys IDENTIFIED BY oracle';
    EXECUTE IMMEDIATE 'ALTER USER system IDENTIFIED BY oracle';
END;
/

-- 3. 시스템 파라미터 및 권한 설정 (SYS)
-- UNDO_RETENTION 3600초 (1시간) 설정: AS OF SCN Flashback Query 시 ORA-01555 방지
ALTER SYSTEM SET UNDO_RETENTION = 3600 SCOPE = BOTH;

-- PARALLEL_MAX_SERVERS 16 설정: PARALLEL 8 마이그레이션 세션 대응
ALTER SYSTEM SET PARALLEL_MAX_SERVERS = 16 SCOPE = BOTH;

-- mig_user에게 V$DATABASE 조회 권한 및 FLASHBACK ANY TABLE 권한 부여
GRANT SELECT ON V_$DATABASE TO mig_user;
GRANT FLASHBACK ANY TABLE TO mig_user;
GRANT SELECT ANY TABLE TO mig_user;
GRANT ALTER SESSION TO mig_user;
GRANT SELECT_CATALOG_ROLE, SELECT ANY DICTIONARY TO mig_user;
GRANT SELECT ON V_$SESSION TO mig_user;
GRANT SELECT ON V_$SESSION_LONGOPS TO mig_user;
GRANT SELECT ON V_$PX_SESSION TO mig_user;
ALTER USER mig_user QUOTA UNLIMITED ON USERS;

-- 4. 테이블 및 인덱스 생성 (mig_user 스키마)
-- 부모 테이블: TB_CUST_MST (고객 마스터)
BEGIN
    EXECUTE IMMEDIATE 'DROP TABLE mig_user.TB_CARD_TXN CASCADE CONSTRAINTS PURGE';
EXCEPTION WHEN OTHERS THEN NULL; END;
/
BEGIN
    EXECUTE IMMEDIATE 'DROP TABLE mig_user.TB_CUST_MST CASCADE CONSTRAINTS PURGE';
EXCEPTION WHEN OTHERS THEN NULL; END;
/

CREATE TABLE mig_user.TB_CUST_MST (
    CUST_ID     NUMBER(10)      CONSTRAINT PK_TB_CUST_MST PRIMARY KEY,
    CUST_NM     VARCHAR2(50)    NOT NULL,
    BIRTH_DT    VARCHAR2(8),
    GENDER      CHAR(1),
    GRADE       VARCHAR2(10)    DEFAULT 'SILVER' NOT NULL,
    JOIN_DT     DATE            DEFAULT SYSDATE  NOT NULL,
    STATUS      VARCHAR2(10)    DEFAULT 'ACTIVE' NOT NULL
);

-- 자식 테이블: TB_CARD_TXN (카드 거래내역)
CREATE TABLE mig_user.TB_CARD_TXN (
    TXN_ID       NUMBER(14)      CONSTRAINT PK_TB_CARD_TXN PRIMARY KEY,
    CUST_ID      NUMBER(10)      NOT NULL CONSTRAINT FK_CARD_CUST REFERENCES mig_user.TB_CUST_MST(CUST_ID),
    CARD_NO      VARCHAR2(16)    NOT NULL,
    TXN_DT       DATE            NOT NULL,
    TXN_AMT      NUMBER(12, 2)   NOT NULL,
    MERCHANT_NM  VARCHAR2(100)   NOT NULL,
    TXN_TYPE     VARCHAR2(20)    DEFAULT 'PAYMENT' NOT NULL,
    APPROVAL_NO  VARCHAR2(20),
    STATUS       VARCHAR2(10)    DEFAULT 'APPROVED' NOT NULL
);

-- 일반 인덱스 및 외래키 인덱스 생성
CREATE INDEX mig_user.IDX_TXN_DT ON mig_user.TB_CARD_TXN(TXN_DT);
CREATE INDEX mig_user.IDX_TXN_AMT ON mig_user.TB_CARD_TXN(TXN_AMT);
CREATE INDEX mig_user.IDX_TXN_CUST_ID ON mig_user.TB_CARD_TXN(CUST_ID);

-- 5. 현실적인 더미 데이터 적재
-- (1) TB_CUST_MST 1만 건 적재
INSERT /*+ APPEND */ INTO mig_user.TB_CUST_MST (
    CUST_ID, CUST_NM, BIRTH_DT, GENDER, GRADE, JOIN_DT, STATUS
)
SELECT
    LEVEL AS CUST_ID,
    '고객_' || LPAD(LEVEL, 6, '0') AS CUST_NM,
    TO_CHAR(TO_DATE('1970-01-01', 'YYYY-MM-DD') + MOD(LEVEL * 37, 14610), 'YYYYMMDD') AS BIRTH_DT,
    CASE MOD(LEVEL, 2) WHEN 0 THEN 'M' ELSE 'F' END AS GENDER,
    CASE MOD(LEVEL, 10)
        WHEN 0 THEN 'DIAMOND'
        WHEN 1 THEN 'VIP'
        WHEN 2 THEN 'GOLD'
        ELSE 'SILVER'
    END AS GRADE,
    TRUNC(SYSDATE - DBMS_RANDOM.VALUE(100, 1500)) AS JOIN_DT,
    CASE MOD(LEVEL, 20) WHEN 0 THEN 'DORMANT' ELSE 'ACTIVE' END AS STATUS
FROM dual
CONNECT BY LEVEL <= 10000;
COMMIT;

-- (2) TB_CARD_TXN 약 50만 건 (1,000 x 500 = 500,000건) 고속 직렬 적재
INSERT /*+ APPEND */ INTO mig_user.TB_CARD_TXN (
    TXN_ID, CUST_ID, CARD_NO, TXN_DT, TXN_AMT, MERCHANT_NM, TXN_TYPE, APPROVAL_NO, STATUS
)
SELECT
    (b.n - 1) * 1000 + a.n AS TXN_ID,
    MOD((b.n - 1) * 1000 + a.n - 1, 10000) + 1 AS CUST_ID,
    '9410' || LPAD(MOD((b.n - 1) * 1000 + a.n, 10000), 4, '0') || LPAD(MOD((b.n - 1) * 1000 + a.n * 7, 9000) + 1000, 4, '0') || LPAD(MOD(b.n * 13, 9000) + 1000, 4, '0') AS CARD_NO,
    TRUNC(SYSDATE - 180) + NUMTODSINTERVAL(MOD((b.n - 1) * 1000 + a.n, 15552000), 'SECOND') AS TXN_DT,
    ROUND(MOD((b.n - 1) * 1000 + a.n * 17, 495000) + 5000, -2) AS TXN_AMT,
    CASE MOD((b.n - 1) * 1000 + a.n, 10)
        WHEN 0 THEN '스타벅스 강남점'
        WHEN 1 THEN '쿠팡(주) 결제'
        WHEN 2 THEN '이마트 역삼점'
        WHEN 3 THEN '우아한형제들(배민)'
        WHEN 4 THEN 'GS25 편의점'
        WHEN 5 THEN '올리브영 신촌점'
        WHEN 6 THEN '네이버페이 온라인'
        WHEN 7 THEN '카카오T 택시'
        WHEN 8 THEN 'CGV 영화관'
        ELSE '파리바게뜨 역삼역점'
    END AS MERCHANT_NM,
    CASE MOD((b.n - 1) * 1000 + a.n, 20)
        WHEN 0 THEN 'CANCEL'
        ELSE 'PAYMENT'
    END AS TXN_TYPE,
    LPAD(MOD((b.n - 1) * 1000 + a.n * 31, 90000000) + 10000000, 8, '0') AS APPROVAL_NO,
    CASE MOD((b.n - 1) * 1000 + a.n, 20)
        WHEN 0 THEN 'CANCELLED'
        ELSE 'APPROVED'
    END AS STATUS
FROM
    (SELECT LEVEL AS n FROM dual CONNECT BY LEVEL <= 1000) a,
    (SELECT LEVEL AS n FROM dual CONNECT BY LEVEL <= 500) b;
COMMIT;

-- 6. 통계정보 수집
EXEC DBMS_STATS.GATHER_TABLE_STATS(ownname => 'MIG_USER', tabname => 'TB_CUST_MST', cascade => TRUE);
EXEC DBMS_STATS.GATHER_TABLE_STATS(ownname => 'MIG_USER', tabname => 'TB_CARD_TXN', cascade => TRUE, degree => 8);

-- 7. 준비 완료 메시지
DECLARE
    v_cust_cnt NUMBER;
    v_txn_cnt  NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_cust_cnt FROM mig_user.TB_CUST_MST;
    SELECT COUNT(*) INTO v_txn_cnt  FROM mig_user.TB_CARD_TXN;
    DBMS_OUTPUT.PUT_LINE('================================================================');
    DBMS_OUTPUT.PUT_LINE('  [ora-src 초기화 완료]');
    DBMS_OUTPUT.PUT_LINE('  - TB_CUST_MST 건수 : ' || v_cust_cnt);
    DBMS_OUTPUT.PUT_LINE('  - TB_CARD_TXN 건수 : ' || v_txn_cnt);
    DBMS_OUTPUT.PUT_LINE('  - UNDO_RETENTION   : 3600 sec');
    DBMS_OUTPUT.PUT_LINE('  - PARALLEL_SERVERS : 16');
    DBMS_OUTPUT.PUT_LINE('================================================================');
END;
/
