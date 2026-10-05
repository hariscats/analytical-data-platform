\set ON_ERROR_STOP on
SET client_min_messages = warning;

-- Proves the database-layer floor by impersonating api_reader.
-- Lets the seeding admin switch to api_reader; Azure admins are not superusers.
GRANT api_reader TO CURRENT_USER WITH INHERIT FALSE, SET TRUE;

\echo 'Rows visible through the published views:'
SELECT
    current_user AS principal,
    (SELECT count(*) FROM api.scenes_v1) AS scenes,
    (SELECT count(*) FROM api.spectra_v1) AS spectral_samples;

SET ROLE api_reader;

SELECT
    current_user AS principal,
    (SELECT count(*) FROM api.scenes_v1) AS scenes,
    (SELECT count(*) FROM api.spectra_v1) AS spectral_samples;

DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM api.scenes_v1 WHERE scene_id = 'A-0001') THEN
        RAISE EXCEPTION 'api_reader cannot see released scene A-0001';
    END IF;
    IF EXISTS (SELECT FROM api.scenes_v1 WHERE scene_id IN ('A-0004', 'B-0004')) THEN
        RAISE EXCEPTION 'api_reader can see an embargoed scene';
    END IF;
    IF EXISTS (SELECT FROM imagery.scene WHERE scene_id = 'A-0004') THEN
        RAISE EXCEPTION 'api_reader can see an embargoed scene in the base table';
    END IF;
    IF EXISTS (SELECT FROM api.spectra_v1 WHERE scene_id = 'A-0004') THEN
        RAISE EXCEPTION 'api_reader can see spectra of an embargoed scene';
    END IF;
    IF NOT EXISTS (SELECT FROM api.spectra_v1 WHERE scene_id = 'A-0001') THEN
        RAISE EXCEPTION 'api_reader cannot see spectra of released scene A-0001';
    END IF;

    BEGIN
        PERFORM raw_uri FROM imagery.scene LIMIT 1;
        RAISE EXCEPTION 'api_reader can read internal column raw_uri';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;

    BEGIN
        UPDATE api.scenes_v1 SET cloud_cover_pct = 0 WHERE scene_id = 'A-0001';
        RAISE EXCEPTION 'api_reader can update a published view';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;

    BEGIN
        DELETE FROM imagery.spectrum WHERE scene_id = 'A-0001';
        RAISE EXCEPTION 'api_reader can delete base-table rows';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
END
$$;

RESET ROLE;

\echo 'Database floor holds: embargoed rows hidden, internal columns and writes denied.'
