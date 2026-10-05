\set ON_ERROR_STOP on
SET client_min_messages = warning;

-- Disposable synthetic fixture. Re-running replaces every object below.
DROP SCHEMA IF EXISTS api CASCADE;
DROP SCHEMA IF EXISTS imagery CASCADE;

CREATE SCHEMA imagery;
CREATE SCHEMA api;

-- Grain: one row per scene acquisition.
CREATE TABLE imagery.scene (
    scene_id text PRIMARY KEY CHECK (scene_id ~ '^[A-Z]-[0-9]{4}$'),
    mission_id text NOT NULL CHECK (mission_id IN ('A', 'B')),
    sensor text NOT NULL,
    acquired_at timestamptz NOT NULL,
    center_lat numeric(8, 5) NOT NULL CHECK (center_lat BETWEEN -90 AND 90),
    center_lon numeric(8, 5) NOT NULL CHECK (center_lon BETWEEN -180 AND 180),
    cloud_cover_pct numeric(5, 2) NOT NULL CHECK (cloud_cover_pct BETWEEN 0 AND 100),
    gsd_m numeric(6, 2) NOT NULL CHECK (gsd_m > 0),
    width_px smallint NOT NULL CHECK (width_px > 0),
    height_px smallint NOT NULL CHECK (height_px > 0),
    band_count smallint NOT NULL CHECK (band_count > 1),
    -- Internal columns: never published, never granted to api_reader.
    release_status text NOT NULL CHECK (release_status IN ('released', 'embargoed')),
    raw_uri text NOT NULL,
    processing_note text NOT NULL,
    UNIQUE (scene_id, mission_id)
);

-- Grain: one reflectance sample per scene, pixel, and band.
-- The primary key is the canonical pixel-major order and the keyset DAB pages on.
CREATE TABLE imagery.spectrum (
    scene_id text NOT NULL,
    mission_id text NOT NULL,
    pixel_row smallint NOT NULL CHECK (pixel_row >= 0),
    pixel_col smallint NOT NULL CHECK (pixel_col >= 0),
    band_id smallint NOT NULL CHECK (band_id >= 1),
    wavelength_nm numeric(7, 2) NOT NULL CHECK (wavelength_nm > 0),
    reflectance real NOT NULL CHECK (reflectance BETWEEN 0 AND 1),
    quality_flag smallint NOT NULL CHECK (quality_flag IN (0, 1)),
    PRIMARY KEY (scene_id, pixel_row, pixel_col, band_id),
    FOREIGN KEY (scene_id, mission_id) REFERENCES imagery.scene (scene_id, mission_id)
);

-- Band-major order: one wavelength across a scene's pixel grid.
CREATE INDEX spectrum_band_major
    ON imagery.spectrum (scene_id, wavelength_nm, pixel_row, pixel_col);

-- Versioned publication contracts. security_invoker makes PostgreSQL evaluate
-- grants and row-level security as the API identity, not the view owner.
CREATE VIEW api.scenes_v1
WITH (security_invoker = true)
AS
SELECT
    scene_id, mission_id, sensor, acquired_at, center_lat, center_lon,
    cloud_cover_pct, gsd_m, width_px, height_px, band_count
FROM imagery.scene;

CREATE VIEW api.spectra_v1
WITH (security_invoker = true)
AS
SELECT
    scene_id, mission_id, pixel_row, pixel_col, band_id,
    wavelength_nm, reflectance, quality_flag
FROM imagery.spectrum;
