-- ============================================================================
--  awr_lite : An Oracle AWR-style workload repository for
--             Amazon RDS for PostgreSQL and Amazon Aurora PostgreSQL
--
--  INSTALLATION: Run this entire script ONCE, connected to the database that
--                will host the repository (referred to as appdb).
--
--  IMPORTANT: The database you install this into MUST be the same database
--             your pg_cron jobs target. See the scheduling section at the end.
--
--  Requires: pg_stat_statements in shared_preload_libraries
--            PostgreSQL 14+ recommended (13 supported, see NOTE markers)
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS awr_lite;
REVOKE ALL ON SCHEMA awr_lite FROM PUBLIC;

-- ----------------------------------------------------------------------------
-- 1. REPOSITORY TABLES
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

-- NOTE (PostgreSQL 13): omit sessions/session_time/active_time/idle_in_transaction_time
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
    sessions                 bigint,
    session_time             double precision,
    active_time              double precision,
    idle_in_transaction_time double precision
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
    buffers_backend    bigint,
    buffers_alloc      bigint
);

-- NOTE (PostgreSQL 13): pg_stat_wal does not exist; this table stays empty
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
    query_id        bigint,
    query           text
);
CREATE INDEX IF NOT EXISTS ash_time_idx  ON awr_lite.active_session_samples (sample_time);
CREATE INDEX IF NOT EXISTS ash_query_idx ON awr_lite.active_session_samples (query_id);

-- ----------------------------------------------------------------------------
-- 2. SNAPSHOT COLLECTOR
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION awr_lite.take_snapshot()
RETURNS bigint AS $fn$
DECLARE
    v_snap_id bigint;
    v_dbid    oid := (SELECT oid FROM pg_database WHERE datname = current_database());
BEGIN
    INSERT INTO awr_lite.snapshots DEFAULT VALUES RETURNING snap_id INTO v_snap_id;

    INSERT INTO awr_lite.stat_statements
        (snap_id, userid, queryid, query, calls, total_exec_time, rows,
         shared_blks_hit, shared_blks_read, temp_blks_read, temp_blks_written)
    SELECT v_snap_id, userid, queryid, left(query, 1000), calls,
           total_exec_time, rows, shared_blks_hit, shared_blks_read,
           temp_blks_read, temp_blks_written
      FROM pg_stat_statements WHERE dbid = v_dbid;

    -- NOTE (PostgreSQL 13): remove the last four columns from both lists
    INSERT INTO awr_lite.stat_database
        (snap_id, datname, xact_commit, xact_rollback, blks_read, blks_hit,
         tup_returned, tup_fetched, tup_inserted, tup_updated, tup_deleted,
         temp_files, temp_bytes, deadlocks, blk_read_time, blk_write_time,
         sessions, session_time, active_time, idle_in_transaction_time)
    SELECT v_snap_id, datname, xact_commit, xact_rollback, blks_read, blks_hit,
           tup_returned, tup_fetched, tup_inserted, tup_updated, tup_deleted,
           temp_files, temp_bytes, deadlocks, blk_read_time, blk_write_time,
           sessions, session_time, active_time, idle_in_transaction_time
      FROM pg_stat_database WHERE datname = current_database();

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

    INSERT INTO awr_lite.stat_indexes
        (snap_id, indexrelid, schemaname, relname, indexrelname,
         idx_scan, idx_tup_read, idx_tup_fetch, idx_blks_read, idx_blks_hit)
    SELECT v_snap_id, i.indexrelid, i.schemaname, i.relname, i.indexrelname,
           i.idx_scan, i.idx_tup_read, i.idx_tup_fetch, io.idx_blks_read, io.idx_blks_hit
      FROM pg_stat_user_indexes i
      JOIN pg_statio_user_indexes io ON io.indexrelid = i.indexrelid;

    -- NOTE (PostgreSQL 17+): checkpoint counters moved to pg_stat_checkpointer.
    -- Replace this INSERT with:
    --   SELECT v_snap_id, c.num_timed, c.num_requested, c.buffers_written,
    --          b.buffers_clean, NULL, b.buffers_alloc
    --     FROM pg_stat_checkpointer c CROSS JOIN pg_stat_bgwriter b;
    INSERT INTO awr_lite.stat_bgwriter
        (snap_id, checkpoints_timed, checkpoints_req, buffers_checkpoint,
         buffers_clean, buffers_backend, buffers_alloc)
    SELECT v_snap_id, checkpoints_timed, checkpoints_req, buffers_checkpoint,
           buffers_clean, buffers_backend, buffers_alloc
      FROM pg_stat_bgwriter;

    -- NOTE (PostgreSQL 13): remove this INSERT (pg_stat_wal does not exist)
    INSERT INTO awr_lite.stat_wal (snap_id, wal_records, wal_fpi, wal_bytes)
    SELECT v_snap_id, wal_records, wal_fpi, wal_bytes FROM pg_stat_wal;

    INSERT INTO awr_lite.stat_settings (snap_id, name, setting, unit)
    SELECT v_snap_id, name, setting, unit FROM pg_settings;

    RETURN v_snap_id;
END;
$fn$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION awr_lite.sample_activity()
RETURNS integer AS $fn$
DECLARE v_rows integer;
BEGIN
    INSERT INTO awr_lite.active_session_samples
        (datname, usename, client_addr, state, wait_event_type, wait_event,
         backend_type, query_id, query)
    SELECT datname, usename, client_addr, state, wait_event_type, wait_event,
           backend_type, query_id, left(query, 500)
      FROM pg_stat_activity
     WHERE pid <> pg_backend_pid()
       AND state IS DISTINCT FROM 'idle'
       AND backend_type = 'client backend';
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RETURN v_rows;
END;
$fn$ LANGUAGE plpgsql;

-- ----------------------------------------------------------------------------
-- 3. SECTION FUNCTIONS (called by awr_lite.report(); also usable directly
--    when you want native tabular output for one section)
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
     ORDER BY CASE lower(p_order)
                WHEN 'calls' THEN (e.calls - COALESCE(b.calls,0))
                WHEN 'rows'  THEN (e.rows - COALESCE(b.rows,0))
                WHEN 'reads' THEN (e.shared_blks_read - COALESCE(b.shared_blks_read,0))
                WHEN 'temp'  THEN ((e.temp_blks_read - COALESCE(b.temp_blks_read,0)) +
                                   (e.temp_blks_written - COALESCE(b.temp_blks_written,0)))
                ELSE (e.total_exec_time - COALESCE(b.total_exec_time,0))
              END DESC NULLS LAST
     LIMIT p_limit;
$fn$ LANGUAGE sql;

CREATE OR REPLACE FUNCTION awr_lite.report_top_tables(
    p_begin bigint, p_end bigint, p_limit int DEFAULT 15)
RETURNS TABLE (schemaname text, relname text, phys_blk_reads bigint, blk_hits bigint,
    cache_hit_pct numeric, seq_scans bigint, idx_scans bigint,
    ins bigint, upd bigint, del bigint, dead_tup bigint) AS $fn$
    SELECT e.schemaname, e.relname,
           ((e.heap_blks_read - b.heap_blks_read) +
            (COALESCE(e.idx_blks_read,0) - COALESCE(b.idx_blks_read,0))),
           ((e.heap_blks_hit - b.heap_blks_hit) +
            (COALESCE(e.idx_blks_hit,0) - COALESCE(b.idx_blks_hit,0))),
           round(100.0 * ((e.heap_blks_hit - b.heap_blks_hit) +
                          (COALESCE(e.idx_blks_hit,0) - COALESCE(b.idx_blks_hit,0)))
                 / NULLIF(((e.heap_blks_hit - b.heap_blks_hit) +
                           (COALESCE(e.idx_blks_hit,0) - COALESCE(b.idx_blks_hit,0)) +
                           (e.heap_blks_read - b.heap_blks_read) +
                           (COALESCE(e.idx_blks_read,0) - COALESCE(b.idx_blks_read,0))), 0), 2),
           (COALESCE(e.seq_scan,0) - COALESCE(b.seq_scan,0)),
           (COALESCE(e.idx_scan,0) - COALESCE(b.idx_scan,0)),
           (e.n_tup_ins - b.n_tup_ins), (e.n_tup_upd - b.n_tup_upd),
           (e.n_tup_del - b.n_tup_del), e.n_dead_tup
      FROM awr_lite.stat_tables b
      JOIN awr_lite.stat_tables e ON e.relid = b.relid
     WHERE b.snap_id = p_begin AND e.snap_id = p_end
     ORDER BY 3 DESC LIMIT p_limit;
$fn$ LANGUAGE sql;

CREATE OR REPLACE FUNCTION awr_lite.report_unused_indexes(p_begin bigint, p_end bigint)
RETURNS TABLE (schemaname text, relname text, indexrelname text, scans_in_interval bigint) AS $fn$
    SELECT e.schemaname, e.relname, e.indexrelname,
           (COALESCE(e.idx_scan,0) - COALESCE(b.idx_scan,0))
      FROM awr_lite.stat_indexes b
      JOIN awr_lite.stat_indexes e ON e.indexrelid = b.indexrelid
     WHERE b.snap_id = p_begin AND e.snap_id = p_end
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
--    SELECT awr_lite.report(<begin_snap>, <end_snap>);
--    SELECT awr_lite.report(<begin_snap>, <end_snap>, 'TOPSQL');
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
    W     int     := 118;   -- report width
BEGIN
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
        RETURN NEXT format('  %14s %10s %12s %12s %7s %-14s %s',
                           repeat('-',14),repeat('-',10),repeat('-',12),repeat('-',12),
                           repeat('-',7),repeat('-',14),repeat('-',40));
        FOR r IN SELECT * FROM awr_lite.report_top_sql(p_begin, p_end, p_limit) LOOP
            RETURN NEXT format('  %14s %10s %12s %12s %7s %-14s %s',
                r.total_exec_time_ms, r.calls, coalesce(r.mean_exec_time_ms::text,'-'),
                r.rows, coalesce(r.hit_pct::text,'-'),
                left(coalesce(r.username,'?'),14), left(r.query,60));
        END LOOP;
        RETURN NEXT '';

        RETURN NEXT repeat('-', W);
        RETURN NEXT '  SQL ORDERED BY BLOCK READS (logical/physical reads)';
        RETURN NEXT repeat('-', W);
        RETURN NEXT format('  %14s %12s %10s %-14s %s', 'Blk Reads','Elapsed(ms)','Calls','User','SQL');
        FOR r IN SELECT * FROM awr_lite.report_top_sql_by(p_begin, p_end, 'reads', p_limit) LOOP
            RETURN NEXT format('  %14s %12s %10s %-14s %s',
                r.shared_blk_reads, r.total_exec_time_ms, r.calls,
                left(coalesce(r.username,'?'),14), left(r.query,60));
        END LOOP;
        RETURN NEXT '';

        RETURN NEXT repeat('-', W);
        RETURN NEXT '  SQL ORDERED BY EXECUTIONS';
        RETURN NEXT repeat('-', W);
        RETURN NEXT format('  %12s %14s %12s %-14s %s', 'Calls','Elapsed(ms)','Rows','User','SQL');
        FOR r IN SELECT * FROM awr_lite.report_top_sql_by(p_begin, p_end, 'calls', p_limit) LOOP
            RETURN NEXT format('  %12s %14s %12s %-14s %s',
                r.calls, r.total_exec_time_ms, r.rows,
                left(coalesce(r.username,'?'),14), left(r.query,60));
        END LOOP;
        RETURN NEXT '';

        RETURN NEXT repeat('-', W);
        RETURN NEXT '  SQL ORDERED BY TEMP BLOCK USAGE (sort/hash spills)';
        RETURN NEXT repeat('-', W);
        RETURN NEXT format('  %12s %14s %12s %-14s %s', 'Temp Blks','Elapsed(ms)','Calls','User','SQL');
        FOR r IN SELECT * FROM awr_lite.report_top_sql_by(p_begin, p_end, 'temp', p_limit) LOOP
            EXIT WHEN r.temp_blks = 0;
            RETURN NEXT format('  %12s %14s %12s %-14s %s',
                r.temp_blks, r.total_exec_time_ms, r.calls,
                left(coalesce(r.username,'?'),14), left(r.query,60));
        END LOOP;
        RETURN NEXT '';
    END IF;

    ---------------------------------------------------------------- SEGMENTS
    IF v_all OR sec = 'SEGMENTS' THEN
        RETURN NEXT repeat('-', W);
        RETURN NEXT '  SEGMENTS BY PHYSICAL READS';
        RETURN NEXT repeat('-', W);
        RETURN NEXT format('  %-20s %-28s %12s %12s %7s %10s %10s %10s',
                           'Schema','Table','Blk Reads','Blk Hits','Hit%','Seq Scans','Idx Scans','Dead Tup');
        FOR r IN SELECT * FROM awr_lite.report_top_tables(p_begin, p_end, p_limit) LOOP
            RETURN NEXT format('  %-20s %-28s %12s %12s %7s %10s %10s %10s',
                left(r.schemaname,20), left(r.relname,28), r.phys_blk_reads, r.blk_hits,
                coalesce(r.cache_hit_pct::text,'-'), r.seq_scans, r.idx_scans, r.dead_tup);
        END LOOP;
        RETURN NEXT '';

        RETURN NEXT repeat('-', W);
        RETURN NEXT '  SEGMENTS BY DML ACTIVITY';
        RETURN NEXT repeat('-', W);
        RETURN NEXT format('  %-20s %-28s %14s %14s %14s',
                           'Schema','Table','Inserts','Updates','Deletes');
        FOR r IN SELECT * FROM awr_lite.report_top_tables(p_begin, p_end, p_limit) LOOP
            CONTINUE WHEN (r.ins + r.upd + r.del) = 0;
            RETURN NEXT format('  %-20s %-28s %14s %14s %14s',
                left(r.schemaname,20), left(r.relname,28), r.ins, r.upd, r.del);
        END LOOP;
        RETURN NEXT '';
    END IF;

    ---------------------------------------------------------------- UNUSED INDEXES
    IF v_all OR sec = 'INDEXES' THEN
        RETURN NEXT repeat('-', W);
        RETURN NEXT '  INDEXES WITH NO SCANS IN THIS INTERVAL';
        RETURN NEXT repeat('-', W);
        FOR r IN SELECT * FROM awr_lite.report_unused_indexes(p_begin, p_end) LOOP
            RETURN NEXT format('  %-20s %-30s %s', left(r.schemaname,20), left(r.relname,30), r.indexrelname);
        END LOOP;
        RETURN NEXT '  (Evaluate over a long window before dropping any index.)';
        RETURN NEXT '';
    END IF;

    ---------------------------------------------------------------- BGWRITER
    IF v_all OR sec = 'BGWRITER' THEN
        RETURN NEXT repeat('-', W);
        RETURN NEXT '  BACKGROUND WRITER / CHECKPOINT ACTIVITY';
        RETURN NEXT repeat('-', W);
        FOR r IN SELECT * FROM awr_lite.report_background(p_begin, p_end) LOOP
            RETURN NEXT format('  Checkpoints  timed: %s   requested: %s',
                               r.timed_checkpoints, r.requested_checkpoints);
            RETURN NEXT format('  Buffers written  by checkpoint: %s   by bgwriter: %s   by backend: %s',
                               r.buffers_checkpoint, r.buffers_clean,
                               coalesce(r.buffers_backend::text,'n/a (PG17+)'));
            RETURN NEXT format('  Buffers allocated: %s', r.buffers_alloc);
        END LOOP;
        RETURN NEXT '';
    END IF;

    ---------------------------------------------------------------- WAL
    IF v_all OR sec = 'WAL' THEN
        RETURN NEXT repeat('-', W);
        RETURN NEXT '  WAL / REDO ACTIVITY';
        RETURN NEXT repeat('-', W);
        FOR r IN SELECT * FROM awr_lite.report_wal(p_begin, p_end) LOOP
            RETURN NEXT format('  WAL records: %s   Full page images: %s   WAL bytes (redo size): %s',
                               r.wal_records, r.wal_fpi, r.wal_bytes);
        END LOOP;
        IF NOT EXISTS (SELECT 1 FROM awr_lite.stat_wal WHERE snap_id = p_end) THEN
            RETURN NEXT '  (No WAL statistics captured - requires PostgreSQL 14 or higher.)';
        END IF;
        RETURN NEXT '';
    END IF;

    ---------------------------------------------------------------- ASH
    IF v_all OR sec = 'ASH' THEN
        RETURN NEXT repeat('-', W);
        RETURN NEXT '  TOP WAIT EVENTS (sampled - Active Session History)';
        RETURN NEXT repeat('-', W);
        RETURN NEXT format('  %-22s %-34s %12s %8s', 'Wait Type','Wait Event','Samples','Pct');
        FOR r IN SELECT * FROM awr_lite.report_ash(p_begin, p_end, p_limit) LOOP
            RETURN NEXT format('  %-22s %-34s %12s %8s',
                left(r.wait_event_type,22), left(r.wait_event,34), r.samples, r.pct);
        END LOOP;
        IF NOT EXISTS (SELECT 1 FROM awr_lite.active_session_samples
                        WHERE sample_time >= (SELECT snap_time FROM awr_lite.snapshots WHERE snap_id = p_begin)
                          AND sample_time <  (SELECT snap_time FROM awr_lite.snapshots WHERE snap_id = p_end)) THEN
            RETURN NEXT '  (No samples in this interval. Schedule awr_lite.sample_activity() to populate.)';
        END IF;
        RETURN NEXT '  Note: NULL wait event is reported as CPU. Sampling approximates time.';
        RETURN NEXT '';
    END IF;

    ---------------------------------------------------------------- SQL SOURCES
    IF v_all OR sec = 'SOURCES' THEN
        RETURN NEXT repeat('-', W);
        RETURN NEXT '  SQL BY USER AND CLIENT ADDRESS (sampled)';
        RETURN NEXT repeat('-', W);
        RETURN NEXT format('  %-22s %-18s %-18s %10s %s', 'Query ID','User','Client Address','Samples','SQL');
        FOR r IN SELECT * FROM awr_lite.report_sql_sources(p_begin, p_end, p_limit) LOOP
            RETURN NEXT format('  %-22s %-18s %-18s %10s %s',
                r.query_id, left(coalesce(r.usename,'?'),18),
                left(coalesce(r.client_addr::text,'local'),18), r.samples, left(r.sample_query,40));
        END LOOP;
        RETURN NEXT '  Note: requires PostgreSQL 14+. Shows the address the server sees';
        RETURN NEXT '        (an RDS Proxy / NAT / bastion address if one is in the path).';
        RETURN NEXT '';
    END IF;

    ---------------------------------------------------------------- PARAMETERS
    IF v_all OR sec = 'PARAMS' THEN
        RETURN NEXT repeat('-', W);
        RETURN NEXT '  PARAMETERS CHANGED BETWEEN SNAPSHOTS';
        RETURN NEXT repeat('-', W);
        RETURN NEXT format('  %-42s %-32s %-32s', 'Parameter','Begin Value','End Value');
        FOR r IN SELECT * FROM awr_lite.report_parameters_changed(p_begin, p_end) LOOP
            RETURN NEXT format('  %-42s %-32s %-32s',
                left(r.name,42), left(coalesce(r.begin_value,'-'),32), left(coalesce(r.end_value,'-'),32));
        END LOOP;
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
--  Next steps (run from the postgres database, targeting THIS database):
--
--    SELECT cron.schedule_in_database('awr_lite_snapshot','*/15 * * * *',
--           $$SELECT awr_lite.take_snapshot();$$, '<this_database>');
--    SELECT cron.schedule_in_database('awr_lite_ash','10 seconds',
--           $$SELECT awr_lite.sample_activity();$$, '<this_database>');
--    SELECT cron.schedule_in_database('awr_lite_purge','0 1 * * *',
--           $$DELETE FROM awr_lite.snapshots WHERE snap_time < now() - interval '8 days';
--             DELETE FROM awr_lite.active_session_samples WHERE sample_time < now() - interval '8 days';$$,
--           '<this_database>');
--
--  Then, to use it:
--    SELECT * FROM awr_lite.list_snapshots();       -- find your window
--    SELECT awr_lite.report(<begin>, <end>);        -- generate the report
-- ============================================================================


