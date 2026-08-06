-- ============================================================================
--  awr_lite : An Oracle AWR-style workload repository for
--             Amazon RDS for PostgreSQL and Amazon Aurora PostgreSQL
--
--  INSTALLATION
--    1. Make sure pg_stat_statements and pg_cron are in shared_preload_libraries
--       and the instance has been rebooted.
--    2. Create (or choose) the database that will host the repository, and
--       create the pg_stat_statements extension INSIDE that database:
--
--         CREATE DATABASE appdb;                        -- if it does not exist
--         \c appdb
--         CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
--
--    3. While still connected to that database, run this script once:
--
--         \i awr_lite_install.sql
--
--  IMPORTANT: Install this into the database whose workload you want to report
--             on. Table and index statistics are per-database, so a repository
--             sitting in another database cannot see your tables at all.
--
--             Whatever schedules take_snapshot() must therefore run in THIS
--             database. On Amazon RDS for PostgreSQL, cron.schedule_in_database()
--             does that with no parameter change. On Amazon Aurora PostgreSQL
--             that function is restricted to rdsadmin, so you either point the
--             cron.database_name parameter at this database, or drive snapshots
--             from outside the database. See the scheduling notes at the end.
--
--  VERSION SUPPORT: PostgreSQL 12 through 18. The collector detects the server
--  version at run time and adapts, so no manual editing is required.
--    - PG12          : uses pg_stat_statements.total_time
--    - PG13 and up   : uses pg_stat_statements.total_exec_time
--    - PG14 and up   : captures DB time, WAL statistics, and pg_stat_activity.query_id
--    - PG17 and up   : reads checkpoint counters from pg_stat_checkpointer
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS awr_lite;
REVOKE ALL ON SCHEMA awr_lite FROM PUBLIC;

-- Drop any awr_lite functions left over from an earlier run of this script.
-- CREATE OR REPLACE FUNCTION only replaces an exact signature match, so if a
-- newer version of a function gains a parameter, the old one would survive as
-- an overload and calls would fail with "function ... is not unique". Dropping
-- first makes this installer safely re-runnable across versions. Tables and
-- their data are never touched.
DO $drop$
DECLARE r record;
BEGIN
    FOR r IN SELECT p.oid::regprocedure AS sig
               FROM pg_proc p
               JOIN pg_namespace n ON n.oid = p.pronamespace
              WHERE n.nspname = 'awr_lite'
    LOOP
        EXECUTE 'DROP FUNCTION IF EXISTS ' || r.sig || ' CASCADE';
    END LOOP;
END
$drop$;

-- ----------------------------------------------------------------------------
-- 1. REPOSITORY TABLES
--    Columns that only exist on newer servers are always present here; they
--    are simply left NULL when the server does not provide them.
-- ----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS awr_lite.snapshots (
    snap_id   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    snap_time timestamptz NOT NULL DEFAULT now(),
    dbname    text        NOT NULL DEFAULT current_database()
);

CREATE TABLE IF NOT EXISTS awr_lite.stat_statements (
    snap_id           bigint NOT NULL REFERENCES awr_lite.snapshots(snap_id) ON DELETE CASCADE,
    userid            oid,
    queryid           bigint,
    query             text,
    calls             bigint,
    total_exec_time   double precision,
    rows              bigint,
    shared_blks_hit   bigint,
    shared_blks_read  bigint,
    temp_blks_read    bigint,
    temp_blks_written bigint
);
CREATE INDEX IF NOT EXISTS stat_statements_snap_idx
    ON awr_lite.stat_statements (snap_id, queryid);

CREATE TABLE IF NOT EXISTS awr_lite.stat_database (
    snap_id        bigint NOT NULL REFERENCES awr_lite.snapshots(snap_id) ON DELETE CASCADE,
    datname        text,
    xact_commit    bigint,
    xact_rollback  bigint,
    blks_read      bigint,
    blks_hit       bigint,
    tup_returned   bigint,
    tup_fetched    bigint,
    tup_inserted   bigint,
    tup_updated    bigint,
    tup_deleted    bigint,
    temp_files     bigint,
    temp_bytes     bigint,
    deadlocks      bigint,
    blk_read_time  double precision,
    blk_write_time double precision,
    sessions                 bigint,            -- PG14+
    session_time             double precision,  -- PG14+
    active_time              double precision,  -- PG14+
    idle_in_transaction_time double precision   -- PG14+
);

CREATE TABLE IF NOT EXISTS awr_lite.stat_tables (
    snap_id        bigint NOT NULL REFERENCES awr_lite.snapshots(snap_id) ON DELETE CASCADE,
    relid          oid,
    schemaname     text,
    relname        text,
    seq_scan       bigint,
    seq_tup_read   bigint,
    idx_scan       bigint,
    idx_tup_fetch  bigint,
    n_tup_ins      bigint,
    n_tup_upd      bigint,
    n_tup_del      bigint,
    n_live_tup     bigint,
    n_dead_tup     bigint,
    heap_blks_read bigint,
    heap_blks_hit  bigint,
    idx_blks_read  bigint,
    idx_blks_hit   bigint
);
CREATE INDEX IF NOT EXISTS stat_tables_snap_idx
    ON awr_lite.stat_tables (snap_id, relid);

CREATE TABLE IF NOT EXISTS awr_lite.stat_indexes (
    snap_id       bigint NOT NULL REFERENCES awr_lite.snapshots(snap_id) ON DELETE CASCADE,
    indexrelid    oid,
    schemaname    text,
    relname       text,
    indexrelname  text,
    idx_scan      bigint,
    idx_tup_read  bigint,
    idx_tup_fetch bigint,
    idx_blks_read bigint,
    idx_blks_hit  bigint
);
CREATE INDEX IF NOT EXISTS stat_indexes_snap_idx
    ON awr_lite.stat_indexes (snap_id, indexrelid);

CREATE TABLE IF NOT EXISTS awr_lite.stat_bgwriter (
    snap_id            bigint NOT NULL REFERENCES awr_lite.snapshots(snap_id) ON DELETE CASCADE,
    checkpoints_timed  bigint,
    checkpoints_req    bigint,
    buffers_checkpoint bigint,
    buffers_clean      bigint,
    buffers_backend    bigint,   -- NULL on PG17+
    buffers_alloc      bigint
);

CREATE TABLE IF NOT EXISTS awr_lite.stat_wal (
    snap_id     bigint NOT NULL REFERENCES awr_lite.snapshots(snap_id) ON DELETE CASCADE,
    wal_records bigint,
    wal_fpi     bigint,
    wal_bytes   numeric
);

CREATE TABLE IF NOT EXISTS awr_lite.stat_settings (
    snap_id bigint NOT NULL REFERENCES awr_lite.snapshots(snap_id) ON DELETE CASCADE,
    name    text,
    setting text,
    unit    text
);
CREATE INDEX IF NOT EXISTS stat_settings_snap_idx
    ON awr_lite.stat_settings (snap_id, name);

CREATE TABLE IF NOT EXISTS awr_lite.active_session_samples (
    sample_time     timestamptz NOT NULL DEFAULT now(),
    datname         text,
    usename         text,
    client_addr     inet,
    state           text,
    wait_event_type text,
    wait_event      text,
    backend_type    text,
    query_id        bigint,     -- PG14+
    query           text
);
CREATE INDEX IF NOT EXISTS ash_time_idx  ON awr_lite.active_session_samples (sample_time);
CREATE INDEX IF NOT EXISTS ash_query_idx ON awr_lite.active_session_samples (query_id);

-- ----------------------------------------------------------------------------
-- 2. COLLECTORS  (version-aware: no manual editing needed on any version)
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION awr_lite.take_snapshot()
RETURNS bigint AS $fn$
DECLARE
    v_snap_id bigint;
    v_dbid    oid := (SELECT oid FROM pg_database WHERE datname = current_database());
    v_ver     int := current_setting('server_version_num')::int;
BEGIN
    INSERT INTO awr_lite.snapshots DEFAULT VALUES RETURNING snap_id INTO v_snap_id;

    ------------------------------------------------------------------ statements
    -- PG13+ exposes total_exec_time; PG12 exposes total_time.
    EXECUTE format($q$
        INSERT INTO awr_lite.stat_statements
            (snap_id, userid, queryid, query, calls, total_exec_time, rows,
             shared_blks_hit, shared_blks_read, temp_blks_read, temp_blks_written)
        SELECT %s, userid, queryid, left(query, 1000), calls, %I, rows,
               shared_blks_hit, shared_blks_read, temp_blks_read, temp_blks_written
          FROM pg_stat_statements WHERE dbid = %s
    $q$, v_snap_id,
         CASE WHEN v_ver >= 130000 THEN 'total_exec_time' ELSE 'total_time' END,
         v_dbid);

    ------------------------------------------------------------------ database
    -- Session/DB-time columns were added in PG14.
    IF v_ver >= 140000 THEN
        EXECUTE format($q$
            INSERT INTO awr_lite.stat_database
                (snap_id, datname, xact_commit, xact_rollback, blks_read, blks_hit,
                 tup_returned, tup_fetched, tup_inserted, tup_updated, tup_deleted,
                 temp_files, temp_bytes, deadlocks, blk_read_time, blk_write_time,
                 sessions, session_time, active_time, idle_in_transaction_time)
            SELECT %s, datname, xact_commit, xact_rollback, blks_read, blks_hit,
                   tup_returned, tup_fetched, tup_inserted, tup_updated, tup_deleted,
                   temp_files, temp_bytes, deadlocks, blk_read_time, blk_write_time,
                   sessions, session_time, active_time, idle_in_transaction_time
              FROM pg_stat_database WHERE datname = current_database()
        $q$, v_snap_id);
    ELSE
        EXECUTE format($q$
            INSERT INTO awr_lite.stat_database
                (snap_id, datname, xact_commit, xact_rollback, blks_read, blks_hit,
                 tup_returned, tup_fetched, tup_inserted, tup_updated, tup_deleted,
                 temp_files, temp_bytes, deadlocks, blk_read_time, blk_write_time)
            SELECT %s, datname, xact_commit, xact_rollback, blks_read, blks_hit,
                   tup_returned, tup_fetched, tup_inserted, tup_updated, tup_deleted,
                   temp_files, temp_bytes, deadlocks, blk_read_time, blk_write_time
              FROM pg_stat_database WHERE datname = current_database()
        $q$, v_snap_id);
    END IF;

    ------------------------------------------------------------------ tables
    INSERT INTO awr_lite.stat_tables
        (snap_id, relid, schemaname, relname, seq_scan, seq_tup_read, idx_scan,
         idx_tup_fetch, n_tup_ins, n_tup_upd, n_tup_del, n_live_tup, n_dead_tup,
         heap_blks_read, heap_blks_hit, idx_blks_read, idx_blks_hit)
    SELECT v_snap_id, t.relid, t.schemaname, t.relname, t.seq_scan, t.seq_tup_read,
           t.idx_scan, t.idx_tup_fetch, t.n_tup_ins, t.n_tup_upd, t.n_tup_del,
           t.n_live_tup, t.n_dead_tup,
           io.heap_blks_read, io.heap_blks_hit, io.idx_blks_read, io.idx_blks_hit
      FROM pg_stat_user_tables t
      JOIN pg_statio_user_tables io ON io.relid = t.relid;

    ------------------------------------------------------------------ indexes
    INSERT INTO awr_lite.stat_indexes
        (snap_id, indexrelid, schemaname, relname, indexrelname,
         idx_scan, idx_tup_read, idx_tup_fetch, idx_blks_read, idx_blks_hit)
    SELECT v_snap_id, i.indexrelid, i.schemaname, i.relname, i.indexrelname,
           i.idx_scan, i.idx_tup_read, i.idx_tup_fetch, io.idx_blks_read, io.idx_blks_hit
      FROM pg_stat_user_indexes i
      JOIN pg_statio_user_indexes io ON io.indexrelid = i.indexrelid;

    ------------------------------------------------------------------ bgwriter
    -- PG17 moved checkpoint counters to pg_stat_checkpointer and dropped
    -- buffers_backend from pg_stat_bgwriter. Wrapped so that a platform which
    -- restricts these views does not abort the whole snapshot.
    BEGIN
        IF v_ver >= 170000 THEN
            EXECUTE format($q$
                INSERT INTO awr_lite.stat_bgwriter
                    (snap_id, checkpoints_timed, checkpoints_req, buffers_checkpoint,
                     buffers_clean, buffers_backend, buffers_alloc)
                SELECT %s, c.num_timed, c.num_requested, c.buffers_written,
                       b.buffers_clean, NULL, b.buffers_alloc
                  FROM pg_stat_checkpointer c CROSS JOIN pg_stat_bgwriter b
            $q$, v_snap_id);
        ELSE
            EXECUTE format($q$
                INSERT INTO awr_lite.stat_bgwriter
                    (snap_id, checkpoints_timed, checkpoints_req, buffers_checkpoint,
                     buffers_clean, buffers_backend, buffers_alloc)
                SELECT %s, checkpoints_timed, checkpoints_req, buffers_checkpoint,
                       buffers_clean, buffers_backend, buffers_alloc
                  FROM pg_stat_bgwriter
            $q$, v_snap_id);
        END IF;
    EXCEPTION WHEN OTHERS THEN
        NULL;   -- background writer statistics not available on this platform
    END;

    ------------------------------------------------------------------ WAL
    -- pg_stat_wal was added in PG14. Note that Amazon Aurora PostgreSQL does not
    -- support the underlying pg_stat_get_wal() function, so the view exists but
    -- raises an error when read. We therefore attempt the read and ignore any
    -- failure, leaving the WAL section of the report empty on those platforms.
    IF v_ver >= 140000 AND to_regclass('pg_catalog.pg_stat_wal') IS NOT NULL THEN
        BEGIN
            EXECUTE format($q$
                INSERT INTO awr_lite.stat_wal (snap_id, wal_records, wal_fpi, wal_bytes)
                SELECT %s, wal_records, wal_fpi, wal_bytes FROM pg_stat_wal
            $q$, v_snap_id);
        EXCEPTION WHEN OTHERS THEN
            NULL;   -- e.g. Aurora PostgreSQL: pg_stat_get_wal() is not supported
        END;
    END IF;

    ------------------------------------------------------------------ settings
    INSERT INTO awr_lite.stat_settings (snap_id, name, setting, unit)
    SELECT v_snap_id, name, setting, unit FROM pg_settings;

    RETURN v_snap_id;
END;
$fn$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION awr_lite.sample_activity()
RETURNS integer AS $fn$
DECLARE
    v_rows integer;
    v_ver  int := current_setting('server_version_num')::int;
BEGIN
    -- pg_stat_activity.query_id was added in PG14.
    EXECUTE format($q$
        INSERT INTO awr_lite.active_session_samples
            (datname, usename, client_addr, state, wait_event_type, wait_event,
             backend_type, query_id, query)
        SELECT datname, usename, client_addr, state, wait_event_type, wait_event,
               backend_type, %s, left(query, 500)
          FROM pg_stat_activity
         WHERE pid <> pg_backend_pid()
           AND state IS DISTINCT FROM 'idle'
           AND backend_type = 'client backend'
    $q$, CASE WHEN v_ver >= 140000 THEN 'query_id' ELSE 'NULL::bigint' END);
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RETURN v_rows;
END;
$fn$ LANGUAGE plpgsql;

-- ----------------------------------------------------------------------------
-- 3. SECTION FUNCTIONS
--    These read only the awr_lite tables, so they are version independent.
--    awr_lite.report() calls them; you can also call any of them directly
--    when you want native tabular output for a single section.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION awr_lite.list_snapshots(p_days int DEFAULT 2)
RETURNS TABLE (snap_id bigint, snap_time timestamptz, gap_minutes numeric) AS $fn$
    SELECT s.snap_id, s.snap_time,
           round((EXTRACT(EPOCH FROM (s.snap_time -
                 lag(s.snap_time) OVER (ORDER BY s.snap_id))) / 60.0)::numeric, 2)
      FROM awr_lite.snapshots s
     WHERE s.snap_time > now() - (p_days || ' days')::interval
     ORDER BY s.snap_id;
$fn$ LANGUAGE sql;

CREATE OR REPLACE FUNCTION awr_lite.report_header(p_begin bigint, p_end bigint)
RETURNS TABLE (db_name text, db_version text, begin_snap bigint, end_snap bigint,
    begin_time timestamptz, end_time timestamptz, elapsed_minutes numeric,
    avg_active_sessions numeric) AS $fn$
    SELECT current_database(), version(), p_begin, p_end, sb.snap_time, se.snap_time,
           round((EXTRACT(EPOCH FROM (se.snap_time - sb.snap_time)) / 60.0)::numeric, 2),
           round(((e.active_time - b.active_time) /
                 NULLIF(EXTRACT(EPOCH FROM (se.snap_time - sb.snap_time)) * 1000, 0))::numeric, 2)
      FROM awr_lite.snapshots sb
      JOIN awr_lite.snapshots se ON se.snap_id = p_end
      JOIN awr_lite.stat_database b ON b.snap_id = p_begin
      JOIN awr_lite.stat_database e ON e.snap_id = p_end
     WHERE sb.snap_id = p_begin;
$fn$ LANGUAGE sql;

CREATE OR REPLACE FUNCTION awr_lite.report_load_profile(p_begin bigint, p_end bigint)
RETURNS TABLE (metric text, total numeric, per_sec numeric, per_txn numeric) AS $fn$
    WITH s AS (
        SELECT EXTRACT(EPOCH FROM (se.snap_time - sb.snap_time)) AS secs,
               (e.xact_commit - b.xact_commit) AS commits,
               (e.xact_rollback - b.xact_rollback) AS rollbacks,
               (e.blks_read - b.blks_read) AS blks_read,
               (e.blks_hit - b.blks_hit) AS blks_hit,
               (e.tup_inserted - b.tup_inserted) AS ins,
               (e.tup_updated - b.tup_updated) AS upd,
               (e.tup_deleted - b.tup_deleted) AS del,
               (e.tup_returned - b.tup_returned) AS ret,
               (e.tup_fetched - b.tup_fetched) AS fetched,
               (e.temp_files - b.temp_files) AS temp_files,
               (e.temp_bytes - b.temp_bytes) AS temp_bytes,
               (e.deadlocks - b.deadlocks) AS deadlocks,
               (e.blk_read_time - b.blk_read_time) AS blk_read_time,
               (e.blk_write_time - b.blk_write_time) AS blk_write_time,
               (e.active_time - b.active_time) AS active_time
          FROM awr_lite.stat_database b
          JOIN awr_lite.stat_database e ON e.datname = b.datname
          JOIN awr_lite.snapshots sb ON sb.snap_id = b.snap_id
          JOIN awr_lite.snapshots se ON se.snap_id = e.snap_id
         WHERE b.snap_id = p_begin AND e.snap_id = p_end)
    SELECT m.metric, round(m.total, 2),
           round(m.total / NULLIF(s.secs, 0), 2),
           round(m.total / NULLIF(s.commits + s.rollbacks, 0), 2)
      FROM s CROSS JOIN LATERAL (VALUES
          ('Transactions',        (s.commits + s.rollbacks)::numeric),
          ('Commits',             s.commits::numeric),
          ('Rollbacks',           s.rollbacks::numeric),
          ('Block reads (disk)',  s.blks_read::numeric),
          ('Block hits (cache)',  s.blks_hit::numeric),
          ('Tuples returned',     s.ret::numeric),
          ('Tuples fetched',      s.fetched::numeric),
          ('Tuples inserted',     s.ins::numeric),
          ('Tuples updated',      s.upd::numeric),
          ('Tuples deleted',      s.del::numeric),
          ('Temp files',          s.temp_files::numeric),
          ('Temp bytes',          s.temp_bytes::numeric),
          ('Deadlocks',           s.deadlocks::numeric),
          ('Block read time ms',  round(s.blk_read_time::numeric, 2)),
          ('Block write time ms', round(s.blk_write_time::numeric, 2)),
          ('Active (DB) time ms', round(s.active_time::numeric, 2))
      ) AS m(metric, total);
$fn$ LANGUAGE sql;

CREATE OR REPLACE FUNCTION awr_lite.report_db_summary(p_begin bigint, p_end bigint)
RETURNS TABLE (interval_start timestamptz, interval_end timestamptz,
    commits bigint, rollbacks bigint, blks_read bigint, blks_hit bigint,
    cache_hit_pct numeric, tup_inserted bigint, tup_updated bigint,
    tup_deleted bigint, temp_files bigint, temp_bytes bigint, deadlocks bigint) AS $fn$
    SELECT sb.snap_time, se.snap_time,
           (e.xact_commit - b.xact_commit), (e.xact_rollback - b.xact_rollback),
           (e.blks_read - b.blks_read), (e.blks_hit - b.blks_hit),
           round(100.0 * (e.blks_hit - b.blks_hit) /
                 NULLIF((e.blks_hit - b.blks_hit) + (e.blks_read - b.blks_read), 0), 2),
           (e.tup_inserted - b.tup_inserted), (e.tup_updated - b.tup_updated),
           (e.tup_deleted - b.tup_deleted), (e.temp_files - b.temp_files),
           (e.temp_bytes - b.temp_bytes), (e.deadlocks - b.deadlocks)
      FROM awr_lite.stat_database b
      JOIN awr_lite.stat_database e ON e.datname = b.datname
      JOIN awr_lite.snapshots sb ON sb.snap_id = b.snap_id
      JOIN awr_lite.snapshots se ON se.snap_id = e.snap_id
     WHERE b.snap_id = p_begin AND e.snap_id = p_end;
$fn$ LANGUAGE sql;

CREATE OR REPLACE FUNCTION awr_lite.report_top_sql(
    p_begin bigint, p_end bigint, p_limit int DEFAULT 15)
RETURNS TABLE (queryid bigint, username text, calls bigint, total_exec_time_ms numeric,
    mean_exec_time_ms numeric, rows bigint, hit_pct numeric, query text) AS $fn$
    SELECT e.queryid, r.rolname,
           (e.calls - COALESCE(b.calls, 0)),
           round((e.total_exec_time - COALESCE(b.total_exec_time, 0))::numeric, 2),
           round(((e.total_exec_time - COALESCE(b.total_exec_time, 0)) /
                  NULLIF(e.calls - COALESCE(b.calls, 0), 0))::numeric, 3),
           (e.rows - COALESCE(b.rows, 0)),
           round(100.0 * (e.shared_blks_hit - COALESCE(b.shared_blks_hit, 0)) /
                 NULLIF((e.shared_blks_hit - COALESCE(b.shared_blks_hit, 0)) +
                        (e.shared_blks_read - COALESCE(b.shared_blks_read, 0)), 0), 2),
           left(regexp_replace(e.query, '\s+', ' ', 'g'), 200)
      FROM awr_lite.stat_statements e
      LEFT JOIN awr_lite.stat_statements b
        ON b.snap_id = p_begin AND b.queryid = e.queryid AND b.userid = e.userid
      LEFT JOIN pg_roles r ON r.oid = e.userid
     WHERE e.snap_id = p_end
       AND (b.snap_id IS NULL OR e.calls >= b.calls)
       AND (e.total_exec_time - COALESCE(b.total_exec_time, 0)) > 0
       AND e.query NOT LIKE '%awr_lite%'   -- hide the repository's own statements
     ORDER BY (e.total_exec_time - COALESCE(b.total_exec_time, 0)) DESC
     LIMIT p_limit;
$fn$ LANGUAGE sql;

CREATE OR REPLACE FUNCTION awr_lite.report_top_sql_by(
    p_begin bigint, p_end bigint, p_order text DEFAULT 'time', p_limit int DEFAULT 15)
RETURNS TABLE (queryid bigint, username text, calls bigint,
    total_exec_time_ms numeric, rows bigint, shared_blk_reads bigint,
    temp_blks bigint, query text) AS $fn$
    SELECT e.queryid, r.rolname,
           (e.calls - COALESCE(b.calls,0)),
           round((e.total_exec_time - COALESCE(b.total_exec_time,0))::numeric, 2),
           (e.rows - COALESCE(b.rows,0)),
           (e.shared_blks_read - COALESCE(b.shared_blks_read,0)),
           ((e.temp_blks_read - COALESCE(b.temp_blks_read,0)) +
            (e.temp_blks_written - COALESCE(b.temp_blks_written,0))),
           left(regexp_replace(e.query, '\s+', ' ', 'g'), 200)
      FROM awr_lite.stat_statements e
      LEFT JOIN awr_lite.stat_statements b
        ON b.snap_id = p_begin AND b.queryid = e.queryid AND b.userid = e.userid
      LEFT JOIN pg_roles r ON r.oid = e.userid
     WHERE e.snap_id = p_end AND (b.snap_id IS NULL OR e.calls >= b.calls)
       AND e.query NOT LIKE '%awr_lite%'   -- hide the repository's own statements
       -- only rows that actually consumed the metric being ranked
       AND CASE lower(p_order)
             WHEN 'calls' THEN (e.calls - COALESCE(b.calls,0))::double precision
             WHEN 'rows'  THEN (e.rows - COALESCE(b.rows,0))::double precision
             WHEN 'reads' THEN (e.shared_blks_read - COALESCE(b.shared_blks_read,0))::double precision
             WHEN 'temp'  THEN ((e.temp_blks_read - COALESCE(b.temp_blks_read,0)) +
                                (e.temp_blks_written - COALESCE(b.temp_blks_written,0)))::double precision
             ELSE (e.total_exec_time - COALESCE(b.total_exec_time,0))
           END > 0
     ORDER BY CASE lower(p_order)
                WHEN 'calls' THEN (e.calls - COALESCE(b.calls,0))::double precision
                WHEN 'rows'  THEN (e.rows - COALESCE(b.rows,0))::double precision
                WHEN 'reads' THEN (e.shared_blks_read - COALESCE(b.shared_blks_read,0))::double precision
                WHEN 'temp'  THEN ((e.temp_blks_read - COALESCE(b.temp_blks_read,0)) +
                                   (e.temp_blks_written - COALESCE(b.temp_blks_written,0)))::double precision
                ELSE (e.total_exec_time - COALESCE(b.total_exec_time,0))
              END DESC NULLS LAST
     LIMIT p_limit;
$fn$ LANGUAGE sql;

-- Segments by physical reads. Uses a LEFT JOIN from the ending snapshot so that
-- objects created during the interval are included, and excludes the awr_lite
-- schema itself so the repository's own tables do not crowd out your workload.
-- Pass p_include_repo => true if you want to see awr_lite's own objects.
CREATE OR REPLACE FUNCTION awr_lite.report_top_tables(
    p_begin bigint, p_end bigint, p_limit int DEFAULT 15,
    p_include_repo boolean DEFAULT false)
RETURNS TABLE (schemaname text, relname text, phys_blk_reads bigint, blk_hits bigint,
    cache_hit_pct numeric, seq_scans bigint, idx_scans bigint,
    ins bigint, upd bigint, del bigint, dead_tup bigint) AS $fn$
    SELECT e.schemaname, e.relname,
           ((e.heap_blks_read - COALESCE(b.heap_blks_read,0)) +
            (COALESCE(e.idx_blks_read,0) - COALESCE(b.idx_blks_read,0))),
           ((e.heap_blks_hit - COALESCE(b.heap_blks_hit,0)) +
            (COALESCE(e.idx_blks_hit,0) - COALESCE(b.idx_blks_hit,0))),
           round(100.0 * ((e.heap_blks_hit - COALESCE(b.heap_blks_hit,0)) +
                          (COALESCE(e.idx_blks_hit,0) - COALESCE(b.idx_blks_hit,0)))
                 / NULLIF(((e.heap_blks_hit - COALESCE(b.heap_blks_hit,0)) +
                           (COALESCE(e.idx_blks_hit,0) - COALESCE(b.idx_blks_hit,0)) +
                           (e.heap_blks_read - COALESCE(b.heap_blks_read,0)) +
                           (COALESCE(e.idx_blks_read,0) - COALESCE(b.idx_blks_read,0))), 0), 2),
           (COALESCE(e.seq_scan,0) - COALESCE(b.seq_scan,0)),
           (COALESCE(e.idx_scan,0) - COALESCE(b.idx_scan,0)),
           (e.n_tup_ins - COALESCE(b.n_tup_ins,0)),
           (e.n_tup_upd - COALESCE(b.n_tup_upd,0)),
           (e.n_tup_del - COALESCE(b.n_tup_del,0)),
           e.n_dead_tup
      FROM awr_lite.stat_tables e
      LEFT JOIN awr_lite.stat_tables b
        ON b.snap_id = p_begin AND b.relid = e.relid
     WHERE e.snap_id = p_end
       AND (p_include_repo OR e.schemaname <> 'awr_lite')
       -- Only segments that were actually touched in the interval, the way an
       -- Oracle AWR segment section behaves. Without this, every idle table in
       -- the database is listed with all-zero counters.
       AND ((e.heap_blks_read - COALESCE(b.heap_blks_read,0))
          + (COALESCE(e.idx_blks_read,0) - COALESCE(b.idx_blks_read,0))
          + (e.heap_blks_hit  - COALESCE(b.heap_blks_hit,0))
          + (COALESCE(e.idx_blks_hit,0)  - COALESCE(b.idx_blks_hit,0))
          + (e.n_tup_ins - COALESCE(b.n_tup_ins,0))
          + (e.n_tup_upd - COALESCE(b.n_tup_upd,0))
          + (e.n_tup_del - COALESCE(b.n_tup_del,0))
          + (COALESCE(e.seq_scan,0) - COALESCE(b.seq_scan,0))
          + (COALESCE(e.idx_scan,0) - COALESCE(b.idx_scan,0))) > 0
     ORDER BY 3 DESC, 4 DESC LIMIT p_limit;
$fn$ LANGUAGE sql;

CREATE OR REPLACE FUNCTION awr_lite.report_unused_indexes(
    p_begin bigint, p_end bigint, p_include_repo boolean DEFAULT false)
RETURNS TABLE (schemaname text, relname text, indexrelname text, scans_in_interval bigint) AS $fn$
    SELECT e.schemaname, e.relname, e.indexrelname,
           (COALESCE(e.idx_scan,0) - COALESCE(b.idx_scan,0))
      FROM awr_lite.stat_indexes e
      LEFT JOIN awr_lite.stat_indexes b
        ON b.snap_id = p_begin AND b.indexrelid = e.indexrelid
     WHERE e.snap_id = p_end
       AND (p_include_repo OR e.schemaname <> 'awr_lite')
       AND (COALESCE(e.idx_scan,0) - COALESCE(b.idx_scan,0)) = 0
     ORDER BY e.schemaname, e.relname, e.indexrelname;
$fn$ LANGUAGE sql;

CREATE OR REPLACE FUNCTION awr_lite.report_background(p_begin bigint, p_end bigint)
RETURNS TABLE (timed_checkpoints bigint, requested_checkpoints bigint,
    buffers_checkpoint bigint, buffers_clean bigint,
    buffers_backend bigint, buffers_alloc bigint) AS $fn$
    SELECT (e.checkpoints_timed - b.checkpoints_timed),
           (e.checkpoints_req - b.checkpoints_req),
           (e.buffers_checkpoint - b.buffers_checkpoint),
           (e.buffers_clean - b.buffers_clean),
           (e.buffers_backend - b.buffers_backend),
           (e.buffers_alloc - b.buffers_alloc)
      FROM awr_lite.stat_bgwriter b
      JOIN awr_lite.stat_bgwriter e ON true
     WHERE b.snap_id = p_begin AND e.snap_id = p_end;
$fn$ LANGUAGE sql;

CREATE OR REPLACE FUNCTION awr_lite.report_wal(p_begin bigint, p_end bigint)
RETURNS TABLE (wal_records bigint, wal_fpi bigint, wal_bytes numeric) AS $fn$
    SELECT (e.wal_records - b.wal_records), (e.wal_fpi - b.wal_fpi),
           (e.wal_bytes - b.wal_bytes)
      FROM awr_lite.stat_wal b
      JOIN awr_lite.stat_wal e ON true
     WHERE b.snap_id = p_begin AND e.snap_id = p_end;
$fn$ LANGUAGE sql;

CREATE OR REPLACE FUNCTION awr_lite.report_ash(
    p_begin bigint, p_end bigint, p_limit int DEFAULT 15)
RETURNS TABLE (wait_event_type text, wait_event text, samples bigint, pct numeric) AS $fn$
    WITH w AS (
        SELECT (SELECT snap_time FROM awr_lite.snapshots WHERE snap_id = p_begin) AS t0,
               (SELECT snap_time FROM awr_lite.snapshots WHERE snap_id = p_end)   AS t1)
    SELECT COALESCE(s.wait_event_type, 'CPU'), COALESCE(s.wait_event, 'CPU'),
           count(*), round(100.0 * count(*) / NULLIF(sum(count(*)) OVER (), 0), 2)
      FROM awr_lite.active_session_samples s, w
     WHERE s.sample_time >= w.t0 AND s.sample_time < w.t1
     GROUP BY 1, 2 ORDER BY 3 DESC LIMIT p_limit;
$fn$ LANGUAGE sql;

CREATE OR REPLACE FUNCTION awr_lite.report_sql_sources(
    p_begin bigint, p_end bigint, p_limit int DEFAULT 20)
RETURNS TABLE (query_id bigint, usename text, client_addr inet,
    samples bigint, sample_query text) AS $fn$
    WITH w AS (
        SELECT (SELECT snap_time FROM awr_lite.snapshots WHERE snap_id = p_begin) AS t0,
               (SELECT snap_time FROM awr_lite.snapshots WHERE snap_id = p_end)   AS t1)
    SELECT s.query_id, s.usename, s.client_addr, count(*),
           left(regexp_replace(max(s.query), '\s+', ' ', 'g'), 120)
      FROM awr_lite.active_session_samples s, w
     WHERE s.sample_time >= w.t0 AND s.sample_time < w.t1 AND s.query_id IS NOT NULL
     GROUP BY s.query_id, s.usename, s.client_addr
     ORDER BY count(*) DESC LIMIT p_limit;
$fn$ LANGUAGE sql;

CREATE OR REPLACE FUNCTION awr_lite.report_parameters_changed(p_begin bigint, p_end bigint)
RETURNS TABLE (name text, begin_value text, end_value text) AS $fn$
    SELECT b.name, b.setting, e.setting
      FROM awr_lite.stat_settings b
      JOIN awr_lite.stat_settings e ON e.name = b.name
     WHERE b.snap_id = p_begin AND e.snap_id = p_end
       AND b.setting IS DISTINCT FROM e.setting
     ORDER BY b.name;
$fn$ LANGUAGE sql;

-- ----------------------------------------------------------------------------
-- 4. THE REPORT ENTRY POINT  (this is the only function you normally call)
--
--      SELECT * FROM awr_lite.list_snapshots();     -- find your window
--      SELECT awr_lite.report(<begin>, <end>);      -- generate the report
--
--    Sections: ALL (default), HEADER, LOAD, SUMMARY, TOPSQL, SEGMENTS,
--              INDEXES, BGWRITER, WAL, ASH, SOURCES, PARAMS
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION awr_lite.report(
    p_begin   bigint,
    p_end     bigint,
    p_section text DEFAULT 'ALL',
    p_limit   int  DEFAULT 15)
RETURNS SETOF text AS $fn$
DECLARE
    r     record;
    sec   text    := upper(coalesce(p_section, 'ALL'));
    v_all boolean := (sec = 'ALL');
    W     int     := 118;
    n     int     := 0;
BEGIN
    -- Catch a mistyped section name early. Without this the function would
    -- silently return zero rows, which looks like "no data" rather than a typo.
    IF sec NOT IN ('ALL','HEADER','LOAD','SUMMARY','TOPSQL','SEGMENTS','INDEXES',
                   'BGWRITER','WAL','ASH','SOURCES','PARAMS') THEN
        RETURN NEXT format('ERROR: unknown section %L.', p_section);
        RETURN NEXT '  Valid sections: ALL (default), HEADER, LOAD, SUMMARY, TOPSQL,';
        RETURN NEXT '                  SEGMENTS, INDEXES, BGWRITER, WAL, ASH, SOURCES, PARAMS';
        RETURN;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM awr_lite.snapshots WHERE snap_id = p_begin) THEN
        RETURN NEXT format('ERROR: begin snapshot %s not found. Run: SELECT * FROM awr_lite.list_snapshots();', p_begin);
        RETURN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM awr_lite.snapshots WHERE snap_id = p_end) THEN
        RETURN NEXT format('ERROR: end snapshot %s not found. Run: SELECT * FROM awr_lite.list_snapshots();', p_end);
        RETURN;
    END IF;
    IF p_end <= p_begin THEN
        RETURN NEXT 'ERROR: end snapshot must be greater than begin snapshot.';
        RETURN;
    END IF;

    ---------------------------------------------------------------- HEADER
    IF v_all OR sec = 'HEADER' THEN
        RETURN NEXT repeat('=', W);
        RETURN NEXT '  PostgreSQL Workload Report   (awr_lite)';
        RETURN NEXT repeat('=', W);
        FOR r IN SELECT * FROM awr_lite.report_header(p_begin, p_end) LOOP
            RETURN NEXT format('  Database            : %s', r.db_name);
            RETURN NEXT format('  Version             : %s', split_part(r.db_version, ' on ', 1));
            RETURN NEXT format('  Snapshots           : %s  ->  %s', r.begin_snap, r.end_snap);
            RETURN NEXT format('  Interval Start      : %s', r.begin_time);
            RETURN NEXT format('  Interval End        : %s', r.end_time);
            RETURN NEXT format('  Elapsed (minutes)   : %s', r.elapsed_minutes);
            RETURN NEXT format('  Avg Active Sessions : %s',
                               coalesce(r.avg_active_sessions::text, 'n/a (requires PG14+)'));
        END LOOP;
        RETURN NEXT '';
    END IF;

    ---------------------------------------------------------------- LOAD PROFILE
    IF v_all OR sec = 'LOAD' THEN
        RETURN NEXT repeat('-', W);
        RETURN NEXT '  LOAD PROFILE';
        RETURN NEXT repeat('-', W);
        RETURN NEXT format('  %-24s %18s %16s %16s', 'Metric', 'Total', 'Per Second', 'Per Transaction');
        RETURN NEXT format('  %-24s %18s %16s %16s', repeat('-',24), repeat('-',18), repeat('-',16), repeat('-',16));
        FOR r IN SELECT * FROM awr_lite.report_load_profile(p_begin, p_end) LOOP
            RETURN NEXT format('  %-24s %18s %16s %16s',
                r.metric, coalesce(r.total::text,'-'), coalesce(r.per_sec::text,'-'), coalesce(r.per_txn::text,'-'));
        END LOOP;
        RETURN NEXT '';
    END IF;

    ---------------------------------------------------------------- DB SUMMARY
    IF v_all OR sec = 'SUMMARY' THEN
        RETURN NEXT repeat('-', W);
        RETURN NEXT '  DATABASE ACTIVITY SUMMARY';
        RETURN NEXT repeat('-', W);
        FOR r IN SELECT * FROM awr_lite.report_db_summary(p_begin, p_end) LOOP
            RETURN NEXT format('  Commits: %s   Rollbacks: %s   Deadlocks: %s',
                               r.commits, r.rollbacks, r.deadlocks);
            RETURN NEXT format('  Buffer cache hit ratio: %s %%   (hits: %s, disk reads: %s)',
                               coalesce(r.cache_hit_pct::text,'n/a'), r.blks_hit, r.blks_read);
            RETURN NEXT format('  Tuples  inserted: %s   updated: %s   deleted: %s',
                               r.tup_inserted, r.tup_updated, r.tup_deleted);
            RETURN NEXT format('  Temp files: %s   Temp bytes: %s', r.temp_files, r.temp_bytes);
        END LOOP;
        RETURN NEXT '';
    END IF;

    ---------------------------------------------------------------- TOP SQL
    IF v_all OR sec = 'TOPSQL' THEN
        RETURN NEXT repeat('-', W);
        RETURN NEXT '  SQL ORDERED BY ELAPSED TIME';
        RETURN NEXT repeat('-', W);
        RETURN NEXT format('  %14s %10s %12s %12s %7s %-14s %s',
                           'Elapsed(ms)','Calls','Avg(ms)','Rows','Hit%','User','SQL');
        n := 0;
        FOR r IN SELECT * FROM awr_lite.report_top_sql(p_begin, p_end, p_limit) LOOP
            n := n + 1;
            RETURN NEXT format('  %14s %10s %12s %12s %7s %-14s %s',
                r.total_exec_time_ms, r.calls, coalesce(r.mean_exec_time_ms::text,'-'),
                r.rows, coalesce(r.hit_pct::text,'-'),
                left(coalesce(r.username,'?'),14), left(r.query,60));
        END LOOP;
        IF n = 0 THEN RETURN NEXT '  (No statement activity recorded in this interval.)'; END IF;
        RETURN NEXT '';

        RETURN NEXT repeat('-', W);
        RETURN NEXT '  SQL ORDERED BY BLOCK READS';
        RETURN NEXT repeat('-', W);
        RETURN NEXT format('  %14s %12s %10s %-14s %s', 'Blk Reads','Elapsed(ms)','Calls','User','SQL');
        n := 0;
        FOR r IN SELECT * FROM awr_lite.report_top_sql_by(p_begin, p_end, 'reads', p_limit) LOOP
            n := n + 1;
            RETURN NEXT format('  %14s %12s %10s %-14s %s',
                r.shared_blk_reads, r.total_exec_time_ms, r.calls,
                left(coalesce(r.username,'?'),14), left(r.query,60));
        END LOOP;
        IF n = 0 THEN RETURN NEXT '  (No statements performed physical block reads in this interval.)'; END IF;
        RETURN NEXT '';

        RETURN NEXT repeat('-', W);
        RETURN NEXT '  SQL ORDERED BY EXECUTIONS';
        RETURN NEXT repeat('-', W);
        RETURN NEXT format('  %12s %14s %12s %-14s %s', 'Calls','Elapsed(ms)','Rows','User','SQL');
        n := 0;
        FOR r IN SELECT * FROM awr_lite.report_top_sql_by(p_begin, p_end, 'calls', p_limit) LOOP
            n := n + 1;
            RETURN NEXT format('  %12s %14s %12s %-14s %s',
                r.calls, r.total_exec_time_ms, r.rows,
                left(coalesce(r.username,'?'),14), left(r.query,60));
        END LOOP;
        IF n = 0 THEN RETURN NEXT '  (No statement executions recorded in this interval.)'; END IF;
        RETURN NEXT '';

        RETURN NEXT repeat('-', W);
        RETURN NEXT '  SQL ORDERED BY TEMP BLOCK USAGE';
        RETURN NEXT repeat('-', W);
        RETURN NEXT format('  %12s %14s %12s %-14s %s', 'Temp Blks','Elapsed(ms)','Calls','User','SQL');
        n := 0;
        FOR r IN SELECT * FROM awr_lite.report_top_sql_by(p_begin, p_end, 'temp', p_limit) LOOP
            n := n + 1;
            RETURN NEXT format('  %12s %14s %12s %-14s %s',
                r.temp_blks, r.total_exec_time_ms, r.calls,
                left(coalesce(r.username,'?'),14), left(r.query,60));
        END LOOP;
        IF n = 0 THEN RETURN NEXT '  (No statements spilled to temporary blocks in this interval.)'; END IF;
        RETURN NEXT '';
    END IF;

    ---------------------------------------------------------------- SEGMENTS
    IF v_all OR sec = 'SEGMENTS' THEN
        RETURN NEXT repeat('-', W);
        RETURN NEXT '  SEGMENTS BY PHYSICAL READS';
        RETURN NEXT repeat('-', W);
        RETURN NEXT format('  %-18s %-26s %12s %12s %7s %10s %10s %10s',
                           'Schema','Table','Blk Reads','Blk Hits','Hit%','Seq Scans','Idx Scans','Dead Tup');
        n := 0;
        FOR r IN SELECT * FROM awr_lite.report_top_tables(p_begin, p_end, p_limit) LOOP
            n := n + 1;
            RETURN NEXT format('  %-18s %-26s %12s %12s %7s %10s %10s %10s',
                left(r.schemaname,18), left(r.relname,26), r.phys_blk_reads, r.blk_hits,
                coalesce(r.cache_hit_pct::text,'-'), r.seq_scans, r.idx_scans, r.dead_tup);
        END LOOP;
        IF n = 0 THEN RETURN NEXT '  (No user table activity recorded in this interval.)'; END IF;
        RETURN NEXT '';

        RETURN NEXT repeat('-', W);
        RETURN NEXT '  SEGMENTS BY DML ACTIVITY';
        RETURN NEXT repeat('-', W);
        RETURN NEXT format('  %-18s %-26s %14s %14s %14s',
                           'Schema','Table','Inserts','Updates','Deletes');
        n := 0;
        FOR r IN SELECT * FROM awr_lite.report_top_tables(p_begin, p_end, p_limit) LOOP
            CONTINUE WHEN (r.ins + r.upd + r.del) = 0;
            n := n + 1;
            RETURN NEXT format('  %-18s %-26s %14s %14s %14s',
                left(r.schemaname,18), left(r.relname,26), r.ins, r.upd, r.del);
        END LOOP;
        IF n = 0 THEN RETURN NEXT '  (No DML recorded against user tables in this interval.)'; END IF;
        RETURN NEXT '';
    END IF;

    ---------------------------------------------------------------- INDEXES
    IF v_all OR sec = 'INDEXES' THEN
        RETURN NEXT repeat('-', W);
        RETURN NEXT '  INDEXES WITH NO SCANS IN THIS INTERVAL';
        RETURN NEXT repeat('-', W);
        IF EXISTS (SELECT 1 FROM awr_lite.report_unused_indexes(p_begin, p_end)) THEN
            FOR r IN SELECT * FROM awr_lite.report_unused_indexes(p_begin, p_end) LOOP
                RETURN NEXT format('  %-18s %-30s %s', left(r.schemaname,18), left(r.relname,30), r.indexrelname);
            END LOOP;
        ELSE
            RETURN NEXT '  (Every index was scanned at least once in this interval.)';
        END IF;
        RETURN NEXT '  (Evaluate over a long window before dropping any index.)';
        RETURN NEXT '';
    END IF;

    ---------------------------------------------------------------- BGWRITER
    IF v_all OR sec = 'BGWRITER' THEN
        RETURN NEXT repeat('-', W);
        RETURN NEXT '  BACKGROUND WRITER / CHECKPOINT ACTIVITY';
        RETURN NEXT repeat('-', W);
        n := 0;
        FOR r IN SELECT * FROM awr_lite.report_background(p_begin, p_end) LOOP
            n := n + 1;
            RETURN NEXT format('  Checkpoints  timed: %s   requested: %s',
                               r.timed_checkpoints, r.requested_checkpoints);
            RETURN NEXT format('  Buffers written  by checkpoint: %s   by bgwriter: %s   by backend: %s',
                               r.buffers_checkpoint, r.buffers_clean,
                               coalesce(r.buffers_backend::text,'n/a (PG17+)'));
            RETURN NEXT format('  Buffers allocated: %s', r.buffers_alloc);
        END LOOP;
        IF n = 0 THEN
            RETURN NEXT '  (Background writer statistics were not captured for one or both snapshots.';
            RETURN NEXT '   Some managed platforms restrict pg_stat_bgwriter and pg_stat_checkpointer.)';
        END IF;
        RETURN NEXT '';
    END IF;

    ---------------------------------------------------------------- WAL
    IF v_all OR sec = 'WAL' THEN
        RETURN NEXT repeat('-', W);
        RETURN NEXT '  WAL / REDO ACTIVITY';
        RETURN NEXT repeat('-', W);
        n := 0;
        FOR r IN SELECT * FROM awr_lite.report_wal(p_begin, p_end) LOOP
            n := n + 1;
            RETURN NEXT format('  WAL records: %s   Full page images: %s   WAL bytes (redo size): %s',
                               r.wal_records, r.wal_fpi, r.wal_bytes);
        END LOOP;
        IF n = 0 THEN
            RETURN NEXT '  (Not available on this platform. WAL statistics require PostgreSQL 14 or';
            RETURN NEXT '   higher, and Amazon Aurora PostgreSQL does not support pg_stat_get_wal().';
            RETURN NEXT '   On Aurora, use Amazon CloudWatch metrics for write/redo throughput.)';
        END IF;
        RETURN NEXT '';
    END IF;

    ---------------------------------------------------------------- ASH
    IF v_all OR sec = 'ASH' THEN
        RETURN NEXT repeat('-', W);
        RETURN NEXT '  TOP WAIT EVENTS (sampled - Active Session History)';
        RETURN NEXT repeat('-', W);
        RETURN NEXT format('  %-22s %-34s %12s %8s', 'Wait Type','Wait Event','Samples','Pct');
        n := 0;
        FOR r IN SELECT * FROM awr_lite.report_ash(p_begin, p_end, p_limit) LOOP
            n := n + 1;
            RETURN NEXT format('  %-22s %-34s %12s %8s',
                left(r.wait_event_type,22), left(r.wait_event,34), r.samples, r.pct);
        END LOOP;
        IF n = 0 THEN
            RETURN NEXT '  (No samples in this interval. Schedule awr_lite.sample_activity() to populate.)';
        END IF;
        RETURN NEXT '  Note: a NULL wait event is reported as CPU. Sampling approximates time.';
        RETURN NEXT '';
    END IF;

    ---------------------------------------------------------------- SOURCES
    IF v_all OR sec = 'SOURCES' THEN
        RETURN NEXT repeat('-', W);
        RETURN NEXT '  SQL BY USER AND CLIENT ADDRESS (sampled)';
        RETURN NEXT repeat('-', W);
        RETURN NEXT format('  %-22s %-18s %-18s %10s %s', 'Query ID','User','Client Address','Samples','SQL');
        n := 0;
        FOR r IN SELECT * FROM awr_lite.report_sql_sources(p_begin, p_end, p_limit) LOOP
            n := n + 1;
            RETURN NEXT format('  %-22s %-18s %-18s %10s %s',
                r.query_id, left(coalesce(r.usename,'?'),18),
                left(coalesce(r.client_addr::text,'local'),18), r.samples, left(r.sample_query,40));
        END LOOP;
        IF n = 0 THEN
            RETURN NEXT '  (No sampled sessions carried a query ID in this interval. Schedule';
            RETURN NEXT '   awr_lite.sample_activity() and confirm the server is PostgreSQL 14 or higher.)';
        END IF;
        RETURN NEXT '  Note: requires PostgreSQL 14+. Shows the address the server sees, which is';
        RETURN NEXT '        an RDS Proxy / NAT / bastion address if one is in the connection path.';
        RETURN NEXT '';
    END IF;

    ---------------------------------------------------------------- PARAMS
    IF v_all OR sec = 'PARAMS' THEN
        RETURN NEXT repeat('-', W);
        RETURN NEXT '  PARAMETERS CHANGED BETWEEN SNAPSHOTS';
        RETURN NEXT repeat('-', W);
        IF EXISTS (SELECT 1 FROM awr_lite.report_parameters_changed(p_begin, p_end)) THEN
            RETURN NEXT format('  %-42s %-32s %-32s', 'Parameter','Begin Value','End Value');
            FOR r IN SELECT * FROM awr_lite.report_parameters_changed(p_begin, p_end) LOOP
                RETURN NEXT format('  %-42s %-32s %-32s',
                    left(r.name,42), left(coalesce(r.begin_value,'-'),32), left(coalesce(r.end_value,'-'),32));
            END LOOP;
        ELSE
            RETURN NEXT '  (No parameter changes detected between these snapshots.)';
        END IF;
        RETURN NEXT '';
    END IF;

    IF v_all THEN
        RETURN NEXT repeat('=', W);
        RETURN NEXT '  End of report';
        RETURN NEXT repeat('=', W);
    END IF;
END;
$fn$ LANGUAGE plpgsql;

-- ============================================================================
--  INSTALLATION COMPLETE
--
--  ---------------------------------------------------------------------------
--  SCHEDULING THE COLLECTORS
--  ---------------------------------------------------------------------------
--  pg_cron runs every job in the single database named by the cron.database_name
--  parameter, which defaults to "postgres". Since this repository must live in
--  the database being monitored, the job has to run in that same database.
--  There are three ways to arrange that. Pick by engine and by whether you can
--  take a reboot.
--
--  OPTION A (works identically on RDS PostgreSQL and Aurora PostgreSQL, and is
--  the only in-database option on Aurora). Point cron.database_name at the
--  database holding this repository, then schedule with plain cron.schedule().
--  Requires a reboot, because cron.database_name is a static parameter.
--
--    1. In your custom DB parameter group (RDS) or custom DB CLUSTER parameter
--       group (Aurora), set:
--            cron.database_name = <this_database>
--       This is a static parameter, so reboot the instance, or the Aurora
--       writer, afterwards.
--
--    2. Connect to <this_database> and create the extension there:
--            CREATE EXTENSION IF NOT EXISTS pg_cron;
--       (pg_cron refuses to be created in any other database, and the error
--       message tells you which database it expects.)
--
--    3. Schedule, while connected to <this_database>:
--            SELECT cron.schedule('awr_lite_snapshot','*/15 * * * *',
--                   $$SELECT awr_lite.take_snapshot();$$);
--            SELECT cron.schedule('awr_lite_ash','10 seconds',
--                   $$SELECT awr_lite.sample_activity();$$);
--            SELECT cron.schedule('awr_lite_purge','0 1 * * *',
--                   $$DELETE FROM awr_lite.snapshots
--                      WHERE snap_time < now() - interval '8 days';
--                     DELETE FROM awr_lite.active_session_samples
--                      WHERE sample_time < now() - interval '8 days';$$);
--
--  OPTION B (Amazon RDS for PostgreSQL only; no parameter change, no reboot).
--  Leave cron.database_name at "postgres", install this repository in another
--  database, and schedule from the postgres database using
--  cron.schedule_in_database():
--
--            SELECT cron.schedule_in_database('awr_lite_snapshot','*/15 * * * *',
--                   $$SELECT awr_lite.take_snapshot();$$, '<this_database>');
--            SELECT cron.schedule_in_database('awr_lite_ash','10 seconds',
--                   $$SELECT awr_lite.sample_activity();$$, '<this_database>');
--
--  Do NOT rely on Option B for Aurora PostgreSQL. There, EXECUTE on
--  cron.schedule_in_database is granted only to rdsadmin, so the call fails
--  with: ERROR: permission denied for function schedule_in_database
--  You can confirm what your own session is allowed to do with:
--    SELECT p.oid::regprocedure,
--           has_function_privilege(current_user, p.oid, 'EXECUTE')
--      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--     WHERE n.nspname = 'cron' AND p.proname LIKE 'schedule%';
--
--  OPTION C (no pg_cron at all; no parameter change, no reboot). take_snapshot()
--  is an ordinary SQL call, so anything that can run psql on a timer will do:
--  an Amazon EventBridge schedule invoking an AWS Lambda function, an Amazon ECS
--  scheduled task, or an existing job server. Use this when you are on Aurora
--  and cannot take a reboot. The trade-off is compute running outside the
--  database, which is the cost the in-database scheduler avoids.
--
--  ---------------------------------------------------------------------------
--  Confirm the jobs actually run (look for status = succeeded):
--    SELECT jobid, database, status, return_message, start_time
--      FROM cron.job_run_details ORDER BY start_time DESC LIMIT 10;
--
--  A snapshot job that reports
--      ERROR: schema "awr_lite" does not exist
--  is running in a different database from the one you installed into.
--
--  sample_activity() returning 0 is normal on an idle database: it records only
--  client backends that are not idle.
--
--  Then use it:
--    SELECT * FROM awr_lite.list_snapshots();
--    SELECT awr_lite.report(<begin>, <end>);
-- ============================================================================
