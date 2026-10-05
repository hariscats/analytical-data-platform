\set ON_ERROR_STOP on

-- api_reader is the API identity's only path into this database.
SELECT NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'api_reader') AS create_api_reader \gset
\if :create_api_reader
    CREATE ROLE api_reader NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS;
\endif

REVOKE ALL ON SCHEMA imagery, api FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA imagery, api FROM PUBLIC;
GRANT USAGE ON SCHEMA imagery, api TO api_reader;

-- Column-level grants: internal columns stay unreadable even through direct SQL.
-- The base-table grants exist because the security_invoker views check them.
GRANT SELECT (
    scene_id, mission_id, sensor, acquired_at, center_lat, center_lon,
    cloud_cover_pct, gsd_m, width_px, height_px, band_count
) ON imagery.scene TO api_reader;

GRANT SELECT (
    scene_id, mission_id, pixel_row, pixel_col, band_id,
    wavelength_nm, reflectance, quality_flag
) ON imagery.spectrum TO api_reader;

GRANT SELECT ON api.scenes_v1, api.spectra_v1 TO api_reader;

-- Row-level security: embargoed scenes and their spectra never leave the database,
-- whatever the API configuration says.
ALTER TABLE imagery.scene ENABLE ROW LEVEL SECURITY;
ALTER TABLE imagery.spectrum ENABLE ROW LEVEL SECURITY;

CREATE POLICY released_scenes ON imagery.scene
    FOR SELECT TO api_reader
    USING (release_status = 'released');

-- The subquery is itself filtered by released_scenes.
CREATE POLICY released_spectra ON imagery.spectrum
    FOR SELECT TO api_reader
    USING (EXISTS (
        SELECT FROM imagery.scene AS s
        WHERE s.scene_id = spectrum.scene_id
    ));
