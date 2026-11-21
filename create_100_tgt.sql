-- Create 100 empty tables on ora-tgt
SET TIMING ON
SET SERVEROUTPUT ON SIZE UNLIMITED

PROMPT >>> Creating 100 empty tables (TB_BIZ_001 ~ TB_BIZ_100)...
DECLARE
    v_tbl VARCHAR2(30);
BEGIN
    FOR i IN 1..100 LOOP
        v_tbl := 'TB_BIZ_' || LPAD(i, 3, '0');
        BEGIN
            EXECUTE IMMEDIATE 'DROP TABLE ' || v_tbl || ' CASCADE CONSTRAINTS PURGE';
        EXCEPTION WHEN OTHERS THEN NULL;
        END;
        EXECUTE IMMEDIATE 'CREATE TABLE ' || v_tbl || ' (
            ID NUMBER(10) CONSTRAINT PK_' || v_tbl || ' PRIMARY KEY,
            CODE VARCHAR2(20),
            AMOUNT NUMBER(10,2),
            STATUS CHAR(1),
            CREATE_DT DATE
        )';
        EXECUTE IMMEDIATE 'CREATE INDEX IDX_' || v_tbl || '_DT ON ' || v_tbl || '(CREATE_DT)';
        IF MOD(i, 20) = 0 THEN
            DBMS_OUTPUT.PUT_LINE('  -> ' || i || '/100 empty tables created...');
        END IF;
    END LOOP;
    DBMS_OUTPUT.PUT_LINE('>>> 100 empty tables created successfully.');
END;
/

SELECT COUNT(*) AS TOTAL_TABLES FROM USER_TABLES;
EOF
